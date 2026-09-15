# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Unified LLM Client supporting OpenCode and CPA providers with retry and response gating."""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

ChatMessage = dict[str, Any]

DEFAULT_TIMEOUT_SECONDS = 300
DEFAULT_MIN_RESPONSE_CHARS = 100
DEFAULT_REJECT_FINISH_REASONS = {"length", "max_tokens", "content_filter"}

# opencode2api proxy migration:
# - "opencode" is the canonical provider key (kept for backward compat).
#   "opencode2api" is accepted as an alias and routed to the same logic.
# - OPENCODE2API_BASE_URL1 is primary (even though slower), then
#   OPENCODE2API_BASE_URL, then OPENCODE2API_BASE_URL2 (currently NXDOMAIN,
#   kept last with fast-fail).
OPENCODE_PROVIDER_NAMES = {"opencode", "opencode2api"}
OPENCODE_BASE_URL_ENV_PRIORITY = (
    "OPENCODE2API_BASE_URL1",
    "OPENCODE2API_BASE_URL",
    "OPENCODE2API_BASE_URL2",
)


class LLMClientError(RuntimeError):
    """Raised when an LLM call fails or returns an unusable completion."""


def load_dotenv(dotenv_path: str | Path | None = None) -> dict[str, str]:
    """Simple .env parser using standard library."""
    loaded = {}
    paths_to_check = []
    if dotenv_path:
        paths_to_check.append(Path(dotenv_path))
    else:
        paths_to_check.extend([
            Path.cwd() / ".env",
            Path(__file__).resolve().parents[2] / ".env",
            Path(__file__).resolve().parents[1] / ".env",
        ])

    for path in paths_to_check:
        if path.is_file():
            try:
                for line in path.read_text(encoding="utf-8").splitlines():
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip("'\"")
                        if k and k not in os.environ:
                            os.environ[k] = v
                            loaded[k] = v
                break
            except Exception:
                pass
    return loaded


def interpolate_env_vars(text: str) -> str:
    """Interpolate ${VAR_NAME} or $VAR_NAME placeholders from environment variables."""
    load_dotenv()
    def replacer(match: re.Match) -> str:
        var_name = match.group(1) or match.group(2)
        return os.environ.get(var_name, "")
    return re.sub(r"\$\{([A-Za-z0-9_]+)\}|\$([A-Za-z0-9_]+)", replacer, text)


def fetch_models_dev_free_ids(timeout_seconds: int = 8) -> set[str]:
    """Fetch https://models.dev/api.json and extract all free opencode model IDs (cost.input == 0)."""
    free_ids: set[str] = set()
    url = "https://models.dev/api.json"
    headers = {"User-Agent": "hp-pro-c640-linux-ai-bot/1.0"}
    try:
        req = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            opencode_models = (data.get("opencode") or {}).get("models", {})
            for mid, info in opencode_models.items():
                cost = info.get("cost", {})
                if cost.get("input") == 0 or "free" in mid.lower():
                    free_ids.add(mid)
    except Exception:
        # Fallback to standard known free suffixes if models.dev is unreachable
        pass
    return free_ids


def sanitize_model_name_for_display(model_id: str) -> str:
    """Remove provider namespace and internal tier suffixes for clean display."""
    if not model_id:
        return ""
    # Strip provider namespace like "opencode/" first so UI never leaks it.
    without_ns = model_id.split("/", 1)[1] if "/" in model_id else model_id
    cleaned = re.sub(r"-(high|free|extra-low|low)$", "", without_ns, flags=re.IGNORECASE)
    return cleaned


def _redact_secret_detail(text: str) -> str:
    """Redact key-like material from provider error bodies before surfacing."""
    if not text:
        return text
    redacted = re.sub(r"sk-[A-Za-z0-9_\-]{4,}", "sk-***", text)
    redacted = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9_\-\.~+/=]{4,}", r"\1***", redacted)
    redacted = re.sub(r"(?i)(api[_-]?key['\"\s:=]+)[^,\s}\"]{4,}", r"\1***", redacted)
    return redacted


def _is_validation_rejection(exc: BaseException) -> bool:
    """True when the error is content validation, not transport.

    Validation means the base responded but the completion was unusable
    (empty / too short / truncated / missing marker). Those must not trigger
    cross-base failover; they belong to call_model's length-retry / fallback.
    """
    msg = str(exc).lower()
    return (
        "unusable completion" in msg
        or "missing required marker" in msg
        or "llm returned empty content" in msg
    )


def _redact_url(url: str) -> str:
    """Strip credentials, path and query from a URL for safe error messages.

    Handles both scheme'd URLs (https://user:pass@host:port/v1?key=...) and
    scheme-less endpoints (host.example/v1/chat/completions).
    """
    try:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme:
            return f"{parsed.scheme}://{parsed.hostname or '<host>'}"
        host = (parsed.path or "").split("/", 1)[0] or "<host>"
        return f"{host}"
    except ValueError:
        return "<redacted-url>"


class LLMClient:
    """Multi-provider LLM client for OpenCode Zen and CPA endpoints."""

    def __init__(
        self,
        config_path: str | Path | None = None,
        *,
        default_provider: str = "opencode",
        reject_finish_reasons: list[str] | set[str] | None = None,
        same_model_retry_on_length: int = 1,
        enable_streaming: bool = True,
    ) -> None:
        load_dotenv()
        self.default_provider = default_provider
        self.reject_finish_reasons = set(reject_finish_reasons or DEFAULT_REJECT_FINISH_REASONS)
        self.same_model_retry_on_length = max(0, int(same_model_retry_on_length))
        self.enable_streaming = enable_streaming
        self.providers: dict[str, dict[str, Any]] = {}
        self.models: dict[str, dict[str, Any]] = {}
        self._discovery_cache: dict[str, list[str]] | None = None
        self._discovery_cache_time: float = 0.0
        self._discovery_ttl_seconds: float = 600.0

        if config_path:
            self.load_config(config_path)

    def load_config(self, config_path: str | Path) -> None:
        """Load and parse the LLM providers and model catalog."""
        raw_text = Path(config_path).read_text(encoding="utf-8")
        interpolated = interpolate_env_vars(raw_text)
        data = json.loads(interpolated)

        self.providers = {}
        self.models = {}
        # Config changed -> stale discovery must not survive.
        self._discovery_cache = None
        self._discovery_cache_time = 0.0

        for provider_name, pdata in data.items():
            if not isinstance(pdata, dict):
                continue
            base_url = pdata.get("baseUrl") or ""
            base_urls: list[str] = []
            # Explicit multi-base list takes precedence when present.
            raw_base_urls = pdata.get("baseUrls")
            if isinstance(raw_base_urls, list):
                for u in raw_base_urls:
                    if isinstance(u, str):
                        u = interpolate_env_vars(u).strip()
                        if u:
                            if not u.endswith("/"):
                                u += "/"
                            if u not in base_urls:
                                base_urls.append(u)
            # CPA has no built-in fallback: CPA_BASE_URL must be explicitly configured
            if not base_url and provider_name == "cpa":
                base_url = os.environ.get("CPA_BASE_URL", "")
            # opencode2api proxy: BASE_URL1 (primary, slower) > BASE_URL > BASE_URL2.
            # JSON baseUrl is kept as a fallback entry so old configs still work.
            if provider_name in OPENCODE_PROVIDER_NAMES:
                for env_key in OPENCODE_BASE_URL_ENV_PRIORITY:
                    env_url = (os.environ.get(env_key, "") or "").strip()
                    if env_url:
                        if not env_url.endswith("/"):
                            env_url += "/"
                        if env_url not in base_urls:
                            base_urls.append(env_url)
            if base_url and not base_url.endswith("/"):
                base_url += "/"
            if base_url and base_url not in base_urls:
                # JSON single baseUrl goes last so env priority wins for opencode;
                # for other providers it is the only entry.
                if provider_name in OPENCODE_PROVIDER_NAMES:
                    base_urls.append(base_url)
                else:
                    base_urls.insert(0, base_url)
            # Enforce HTTPS for remote LLM endpoints (localhost exempt for tests).
            for u in base_urls:
                host = (urllib.parse.urlparse(u).hostname or "").lower()
                if u and not u.lower().startswith("https://") and host not in {"localhost", "127.0.0.1", "::1"}:
                    raise LLMClientError(
                        f"Insecure base URL for provider '{provider_name}': {_redact_url(u)} (must be https://)"
                    )
            canonical_base_url = base_urls[0] if base_urls else base_url

            api_key = pdata.get("apikey") or ""
            if not api_key:
                if provider_name == "cpa":
                    api_key = os.environ.get("CPA_API_KEY", "")
                elif provider_name in OPENCODE_PROVIDER_NAMES:
                    # New proxy key first, legacy Zen key kept as deprecated fallback.
                    api_key = os.environ.get("OPENCODE2API_API_KEY", "") or os.environ.get("OPENCODE_API_KEY", "")

            api_type = pdata.get("api", "openai-completions")
            timeout_seconds = int(pdata.get("timeoutSeconds", DEFAULT_TIMEOUT_SECONDS))
            # opencode2api proxy: SSE streaming is unverified (non-streaming is
            # proven). Default to non-streaming unless JSON opts in explicitly.
            if "enableStreaming" in pdata:
                raw_stream = pdata.get("enableStreaming")
                if isinstance(raw_stream, str):
                    provider_streaming = raw_stream.strip().lower() in {"1", "true", "yes", "on"}
                else:
                    provider_streaming = bool(raw_stream)
            else:
                provider_streaming = False if provider_name in OPENCODE_PROVIDER_NAMES else True

            self.providers[provider_name] = {
                "name": provider_name,
                "baseUrl": canonical_base_url,
                "baseUrls": base_urls or ([canonical_base_url] if canonical_base_url else []),
                "apikey": api_key,
                "api": api_type,
                "timeoutSeconds": timeout_seconds,
                "models": pdata.get("models", []),
                "enableStreaming": provider_streaming,
            }

            for m in pdata.get("models", []):
                mid = m.get("id")
                if mid:
                    self.models[mid] = {**m, "_provider": provider_name}

    def discover_models(self, timeout_seconds: int = 8, *, force_refresh: bool = False) -> dict[str, list[str]]:
        """Dynamically query providers' /models endpoints and register active models.

        opencode2api proxy returns a curated list (currently 7 ``opencode/`` IDs)
        so it is trusted as-is; models.dev is only a best-effort hint for legacy
        Zen IDs and never filters proxy results.
        """
        import sys
        import time

        now = time.monotonic()
        if not force_refresh and self._discovery_cache is not None and now - self._discovery_cache_time < self._discovery_ttl_seconds:
            return {k: list(v) for k, v in self._discovery_cache.items()}

        discovered: dict[str, list[str]] = {}
        models_dev_free = fetch_models_dev_free_ids(timeout_seconds=timeout_seconds)
        if not models_dev_free:
            print("[LLM] models.dev free list empty/unreachable; proxy results trusted as-is", file=sys.stderr)

        for pname, pdata in self.providers.items():
            api_key = pdata.get("apikey") or ""
            base_urls = list(pdata.get("baseUrls") or [])
            if pdata.get("baseUrl") and pdata.get("baseUrl") not in base_urls:
                base_urls.insert(0, pdata.get("baseUrl"))
            if not base_urls or not api_key:
                continue

            model_list: list[str] = []
            seen: set[str] = set()
            for base_url in base_urls:
                models_url = f"{base_url.rstrip('/')}/models"
                headers = {
                    "Authorization": f"Bearer {api_key}",
                    "User-Agent": "hp-pro-c640-linux-ai-bot/1.0",
                }
                try:
                    req = urllib.request.Request(models_url, headers=headers, method="GET")
                    with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
                        data = json.loads(resp.read().decode("utf-8"))
                        items = data.get("data", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
                        for item in items:
                            if not isinstance(item, dict):
                                continue
                            mid = item.get("id")
                            if not mid or mid in seen:
                                continue

                            # Proxy namespace is curated: accept everything.
                            # Legacy Zen provider (no prefix) keeps the old free filter.
                            if pname in OPENCODE_PROVIDER_NAMES and "/" in str(mid):
                                pass
                            elif pname in OPENCODE_PROVIDER_NAMES:
                                is_free = (mid in models_dev_free) or ("free" in mid.lower())
                                if not is_free:
                                    continue

                            seen.add(mid)
                            model_list.append(mid)
                            if mid not in self.models:
                                self.models[mid] = {
                                    "id": mid,
                                    "name": item.get("name", mid),
                                    "description": f"Dynamically discovered model from {pname}",
                                    "_provider": pname,
                                    "input": ["text"],
                                    "output": ["text"],
                                }
                    # First healthy base wins for discovery; chat path still
                    # failovers across all bases per request.
                    if model_list:
                        break
                except Exception as exc:
                    print(f"[LLM] discover {pname} via {_redact_url(base_url)} failed: {type(exc).__name__}", file=sys.stderr)
                    continue
            if model_list:
                discovered[pname] = model_list
        # Don't cache total failure (empty dict): a transient outage would
        # otherwise black-hole discovery for the full TTL.
        if discovered:
            self._discovery_cache = discovered
            self._discovery_cache_time = time.monotonic()
        return {k: list(v) for k, v in discovered.items()}

    def get_dynamic_fallback_chain(self, configured_fallbacks: list[str] | None = None) -> list[str]:
        """Build prioritized fallback chain: Configured -> Dynamic opencode2api -> Dynamic CPA."""
        chain: list[str] = []

        # 1. Configured fallbacks in prioritized order (muse-spark first per policy)
        for m in (configured_fallbacks or []):
            if m and m not in chain:
                chain.append(m)

        # 2. Discover live active models from providers
        try:
            discovered = self.discover_models()
        except Exception as exc:
            import sys

            print(f"[LLM] dynamic fallback discovery failed: {type(exc).__name__}", file=sys.stderr)
            discovered = {}

        # 3. Append verified active opencode2api proxy models (muse-spark priority)
        def _muse_spark_rank(mid: str) -> tuple[int, str]:
            low = mid.lower()
            if "muse-spark-1.3" in low:
                return (0, mid)
            if "muse-spark-1.2" in low:
                return (1, mid)
            if "muse-spark" in low:
                return (2, mid)
            return (3, mid)

        opencode_free: list[str] = []
        for key in ("opencode", "opencode2api"):
            opencode_free.extend(discovered.get(key, []))
        for m in sorted(dict.fromkeys(opencode_free), key=_muse_spark_rank):
            if m not in chain:
                chain.append(m)

        # 4. Append remaining live CPA models (excluding image generation)
        for m in discovered.get("cpa", []):
            if m not in chain and not m.startswith("vertex/imagen") and not m.startswith("imagen-"):
                chain.append(m)

        return chain

    def get_provider_for_model(self, model_id: str) -> dict[str, Any]:
        """Resolve the provider definition for a specific model ID."""
        if model_id in self.models:
            pname = self.models[model_id].get("_provider", self.default_provider)
            return self.providers.get(pname, {})
        # opencode*/ namespaced IDs always route to the proxy provider even
        # before discovery has registered them.
        if isinstance(model_id, str) and model_id.startswith(("opencode/", "opencode2api/")):
            for pname in ("opencode", "opencode2api"):
                if pname in self.providers:
                    return self.providers[pname]
        # Fallback to default provider
        return self.providers.get(self.default_provider, {})

    def call_model(
        self,
        model_id: str,
        messages: list[ChatMessage],
        *,
        temperature: float = 0.2,
        max_tokens: int = 4096,
        timeout_seconds: int | None = None,
        min_chars: int = DEFAULT_MIN_RESPONSE_CHARS,
        required_markers: list[str] | None = None,
        fallback_models: list[str] | None = None,
    ) -> str:
        """Call an LLM model with automatic retry on truncation and fallback model support."""
        models_to_try = [model_id]
        if fallback_models:
            for f in fallback_models:
                if f and f not in models_to_try:
                    models_to_try.append(f)

        last_error: LLMClientError | None = None
        for current_model in models_to_try:
            attempts = 1 + self.same_model_retry_on_length
            current_max = max_tokens

            for attempt in range(attempts):
                try:
                    return self._single_call(
                        current_model,
                        messages,
                        temperature=temperature,
                        max_tokens=current_max,
                        timeout_seconds=timeout_seconds,
                        min_chars=min_chars,
                        required_markers=required_markers,
                    )
                except LLMClientError as exc:
                    last_error = exc
                    reason = str(exc).lower()
                    if attempt + 1 < attempts and ("finish_reason=length" in reason or "truncated" in reason or "too short" in reason):
                        current_max = min(max(current_max * 2, current_max + 2048), 65536)
                        continue
                    # Try next fallback model if server/model error
                    break

        assert last_error is not None
        raise last_error

    def _single_call(
        self,
        model_id: str,
        messages: list[ChatMessage],
        *,
        temperature: float,
        max_tokens: int,
        timeout_seconds: int | None,
        min_chars: int,
        required_markers: list[str] | None,
    ) -> str:
        provider = self.get_provider_for_model(model_id)
        pname = provider.get("name", self.default_provider)
        base_urls = list(provider.get("baseUrls") or [])
        if provider.get("baseUrl") and provider.get("baseUrl") not in base_urls:
            base_urls.insert(0, provider.get("baseUrl"))
        api_key = provider.get("apikey") or ""
        api_type = provider.get("api", "openai-completions")
        timeout = timeout_seconds or provider.get("timeoutSeconds", DEFAULT_TIMEOUT_SECONDS)

        if not base_urls:
            raise LLMClientError(f"Base URL is not configured for provider '{pname}' (set OPENCODE2API_BASE_URL1 or CPA_BASE_URL)")
        if not api_key:
            if pname in OPENCODE_PROVIDER_NAMES:
                hint = "set OPENCODE2API_API_KEY (legacy OPENCODE_API_KEY as fallback)"
            elif pname == "cpa":
                hint = "set CPA_API_KEY"
            else:
                hint = "set OPENCODE2API_API_KEY or CPA_API_KEY"
            raise LLMClientError(f"API key is missing for provider '{pname}' ({hint})")

        last_error: LLMClientError | None = None
        for base_url in base_urls:
            try:
                return self._do_single_base_call(
                    pname,
                    base_url,
                    api_key,
                    api_type,
                    model_id,
                    messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    timeout=timeout,
                    min_chars=min_chars,
                    required_markers=required_markers,
                )
            except LLMClientError as exc:
                last_error = exc
                # Validation rejections (empty/too short/missing marker) mean the
                # base responded but content was unusable: don't burn the other
                # bases, let call_model handle length-retry / fallback models.
                if _is_validation_rejection(exc):
                    raise
                # Transport / HTTP errors fail over to the next base (DNS,
                # timeout, 4xx model_not_found during migration, 5xx, CF 403).
                continue
        assert last_error is not None
        raise last_error

    def _do_single_base_call(
        self,
        pname: str,
        base_url: str,
        api_key: str,
        api_type: str,
        model_id: str,
        messages: list[ChatMessage],
        *,
        temperature: float,
        max_tokens: int,
        timeout: int,
        min_chars: int,
        required_markers: list[str] | None,
    ) -> str:
        provider = self.providers.get(pname, {})
        use_streaming = bool(self.enable_streaming and provider.get("enableStreaming", True))
        model_info = self.models.get(model_id, {})
        prepared_messages = _prepare_messages_for_model(messages, model_info)
        reasoning_effort = model_info.get("reasoningEffort")
        thinking_cfg = model_info.get("thinking")

        # Check API endpoints (CPA responses vs OpenAI chat/completions)
        if api_type == "responses" or base_url.rstrip("/").endswith("/responses"):
            endpoint = f"{base_url}responses" if not base_url.rstrip("/").endswith("/responses") else base_url
            body: dict[str, Any] = {
                "model": model_id,
                "input": prepared_messages,
                "temperature": temperature,
                "max_output_tokens": max_tokens,
            }
            if reasoning_effort:
                body["reasoning_effort"] = reasoning_effort
        else:
            endpoint = f"{base_url}chat/completions" if not base_url.rstrip("/").endswith("/chat/completions") else base_url
            body = {
                "model": model_id,
                "messages": prepared_messages,
                "temperature": temperature,
                "max_tokens": max_tokens,
            }
            if reasoning_effort:
                body["reasoning_effort"] = reasoning_effort
            if thinking_cfg:
                body["thinking"] = thinking_cfg

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "hp-pro-c640-linux-ai-bot/1.0",
        }
        if use_streaming:
            body["stream"] = True
            headers["Accept"] = "text/event-stream"

        req_data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(endpoint, data=req_data, headers=headers, method="POST")

        content = ""
        finish_reason = None
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                content_type = resp.headers.get("Content-Type", "")
                if "text/event-stream" in content_type:
                    content, finish_reason = _parse_sse_stream(resp, api_type, print_progress=False)
                else:
                    resp_bytes = resp.read()
                    payload = json.loads(resp_bytes.decode("utf-8"))
                    content, finish_reason = _extract_response_content_and_reason(payload, api_type)
        except urllib.error.HTTPError as exc:
            detail = _redact_secret_detail(exc.read().decode("utf-8", errors="replace"))
            # If responses endpoint failed with 404, attempt fallback to chat/completions
            if exc.code == 404 and "responses" in endpoint:
                return self._fallback_openai_call(
                    base_url, api_key, model_id, prepared_messages, temperature, max_tokens, timeout, min_chars, required_markers
                )
            raise LLMClientError(f"HTTP {exc.code} from {_redact_url(endpoint)}: {detail[:500]}") from exc
        except Exception as exc:
            safe_exc = _redact_secret_detail(str(exc))
            raise LLMClientError(f"LLM request to {_redact_url(endpoint)} failed: {type(exc).__name__}: {safe_exc}") from exc

        rejection = unusable_completion_reason(
            content,
            finish_reason,
            min_chars=min_chars,
            required_markers=required_markers,
            reject_finish_reasons=self.reject_finish_reasons,
        )
        if rejection:
            raise LLMClientError(rejection)
        return content

    def _fallback_openai_call(
        self,
        base_url: str,
        api_key: str,
        model_id: str,
        messages: list[ChatMessage],
        temperature: float,
        max_tokens: int,
        timeout: int,
        min_chars: int,
        required_markers: list[str] | None,
    ) -> str:
        endpoint = f"{base_url.rstrip('/')}/chat/completions"
        body = {
            "model": model_id,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": False,
        }
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "hp-pro-c640-linux-ai-bot/1.0",
            "Accept": "application/json",
        }

        try:
            req = urllib.request.Request(endpoint, data=json.dumps(body).encode("utf-8"), headers=headers, method="POST")
            content = ""
            finish_reason = None
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                content_type = resp.headers.get("Content-Type", "")
                if "text/event-stream" in content_type:
                    content, finish_reason = _parse_sse_stream(resp, "openai-completions", print_progress=False)
                else:
                    payload = json.loads(resp.read().decode("utf-8"))
                    content, finish_reason = _extract_response_content_and_reason(payload, "openai-completions")
        except urllib.error.HTTPError as exc:
            detail = _redact_secret_detail(exc.read().decode("utf-8", errors="replace"))
            raise LLMClientError(f"HTTP {exc.code} from {_redact_url(endpoint)}: {detail[:500]}") from exc
        except Exception as exc:
            safe_exc = _redact_secret_detail(str(exc))
            raise LLMClientError(f"LLM fallback request to {_redact_url(endpoint)} failed: {type(exc).__name__}: {safe_exc}") from exc

        rejection = unusable_completion_reason(
            content, finish_reason, min_chars=min_chars, required_markers=required_markers, reject_finish_reasons=self.reject_finish_reasons
        )
        if rejection:
            raise LLMClientError(rejection)
        return content


def _parse_sse_stream(
    resp: Any,
    api_type: str,
    on_chunk: Callable[[str], None] | None = None,
    print_progress: bool = False,
) -> tuple[str, str | None]:
    """Parse Server-Sent Events (SSE) stream chunks with real-time progress display."""
    import sys

    chunks: list[str] = []
    finish_reason: str | None = None

    for raw_line in resp:
        line_str = raw_line.decode("utf-8", errors="replace").strip()
        if not line_str or line_str.startswith(":"):
            continue
        if line_str.startswith("data:"):
            data_body = line_str[5:].strip()
            if data_body == "[DONE]":
                break
            try:
                chunk = json.loads(data_body)
                piece = ""
                # 1. CPA responses format
                if "delta" in chunk and isinstance(chunk["delta"], str):
                    piece = chunk["delta"]
                elif chunk.get("type") == "response.output_text.delta" and "delta" in chunk:
                    piece = str(chunk["delta"])
                # 2. OpenAI chat/completions format
                elif "choices" in chunk and isinstance(chunk["choices"], list) and chunk["choices"]:
                    c = chunk["choices"][0]
                    delta = c.get("delta") or {}
                    if "content" in delta and isinstance(delta["content"], str):
                        piece = delta["content"]
                    if c.get("finish_reason"):
                        finish_reason = str(c["finish_reason"]).lower()
                elif "response" in chunk and isinstance(chunk["response"], dict):
                    if chunk["response"].get("status"):
                        finish_reason = str(chunk["response"]["status"]).lower()

                if piece:
                    chunks.append(piece)
                    if on_chunk:
                        on_chunk(piece)
                    elif print_progress:
                        sys.stdout.write(piece)
                        sys.stdout.flush()
            except Exception:
                pass

    if print_progress and chunks:
        sys.stdout.write("\n")
        sys.stdout.flush()

    return "".join(chunks).strip(), finish_reason


def _extract_response_content_and_reason(payload: dict[str, Any], api_type: str) -> tuple[str, str | None]:
    """Extract output text and finish_reason from varied JSON payload formats."""
    # 1. Standard OpenAI format
    if "choices" in payload and isinstance(payload["choices"], list) and payload["choices"]:
        choice = payload["choices"][0]
        finish_reason = choice.get("finish_reason") or choice.get("native_finish_reason")
        content = (choice.get("message") or {}).get("content", "")
        return _normalize_content(content), str(finish_reason).lower() if finish_reason else None

    # 2. CPA responses API format
    if "output" in payload:
        texts: list[str] = []
        finish_reason = payload.get("finish_reason") or payload.get("status")
        for item in payload.get("output", []):
            if isinstance(item, dict):
                if item.get("type") == "message" and isinstance(item.get("content"), list):
                    for part in item["content"]:
                        if isinstance(part, dict) and part.get("type") == "output_text":
                            texts.append(str(part.get("text", "")))
                        elif isinstance(part, str):
                            texts.append(part)
                elif item.get("type") == "output_text" and "text" in item:
                    texts.append(str(item["text"]))
                elif "text" in item:
                    texts.append(str(item["text"]))
        full_text = "\n".join(texts).strip()
        return full_text, str(finish_reason).lower() if finish_reason else None

    # 3. Direct content or text
    if "content" in payload and isinstance(payload["content"], str):
        return payload["content"].strip(), None

    return "", "empty_payload"


def _normalize_content(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts: list[str] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                parts.append(str(part.get("text", "")))
            else:
                parts.append(str(part))
        return "\n".join(parts).strip()
    return str(content).strip()


def _prepare_messages_for_model(messages: list[ChatMessage], model_info: dict[str, Any]) -> list[ChatMessage]:
    supports_multimodal = any(t in (model_info.get("input") or ["text"]) for t in ["image", "video", "audio"])
    requires_string = bool((model_info.get("compat") or {}).get("requiresStringContent"))

    prepared: list[ChatMessage] = []
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if isinstance(content, list):
            if supports_multimodal and not requires_string:
                prepared.append({"role": role, "content": content})
            else:
                # Flatten multimodal content to text
                text_parts = []
                for item in content:
                    if isinstance(item, dict):
                        if item.get("type") == "text":
                            text_parts.append(str(item.get("text", "")))
                        elif item.get("type") in {"image_url", "input_image"}:
                            url = ((item.get("image_url") or {}).get("url")) or item.get("url") or ""
                            text_parts.append(f"[Image attached: {url[:100]}]")
                    else:
                        text_parts.append(str(item))
                prepared.append({"role": role, "content": "\n".join(text_parts).strip()})
        else:
            prepared.append({"role": role, "content": str(content)})
    return prepared


def unusable_completion_reason(
    text: str,
    finish_reason: str | None,
    *,
    min_chars: int = DEFAULT_MIN_RESPONSE_CHARS,
    required_markers: list[str] | None = None,
    reject_finish_reasons: set[str] | None = None,
) -> str | None:
    """Validate that the completion is complete, not truncated, and meets markers."""
    reject_reasons = reject_finish_reasons or set(DEFAULT_REJECT_FINISH_REASONS)
    reason = (finish_reason or "").lower()
    if reason in reject_reasons:
        return f"unusable completion (finish_reason={reason})"

    content = (text or "").strip()
    if not content:
        return "LLM returned empty content"
    if len(content) < int(min_chars):
        return f"unusable completion (too short: {len(content)} < {min_chars} chars)"
    if content.endswith(("...", "…")) and len(content) < max(min_chars * 2, 600):
        return "unusable completion (appears truncated)"

    for marker in required_markers or []:
        if marker and marker.lower() not in content.lower():
            return f"unusable completion (missing required marker: {marker})"
    return None

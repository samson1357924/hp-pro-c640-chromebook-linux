# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Media and screenshot artifact processor for issue reports and PR attachments."""

from __future__ import annotations

import base64
import http.client
import ipaddress
import re
import socket
import ssl
import urllib.parse
from typing import Any

from llm_client import LLMClient, LLMClientError

MAX_MEDIA_BYTES = 8 * 1024 * 1024  # 8 MB
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
BLOCKED_HOSTS = {"127.0.0.1", "localhost", "169.254.169.254", "0.0.0.0", "metadata.google.internal", "metadata", "instance-data"}
MAX_REDIRECT_HOPS = 5
MAX_IP_ATTEMPTS = 4


def _ip_is_blocked(ip_str: str) -> bool:
    """Return True when the address must not be fetched (SSRF guard for IPv4/IPv6)."""
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        # Unparseable addresses (e.g. zone-scoped IPv6 like fe80::1%lo) are treated as blocked
        return True
    return ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified or ip.is_reserved


def _blocked_url_reason(url: str) -> str | None:
    """Return a reason string if the URL must not be fetched (scheme/hostname checks), else None."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        return f"Insecure scheme: {parsed.scheme}"
    host = (parsed.hostname or "").lower().rstrip(".")
    if not host:
        return "URL has no hostname"
    if host in BLOCKED_HOSTS:
        return f"Blocked hostname: {host}"
    return None


def _resolve_pinned_targets(url: str) -> tuple[str, int, list[str]]:
    """Resolve once, validate every address, and return (host, port, pinned_ips).

    The returned IPs are the only addresses the connection may use, closing the
    DNS-rebinding window between validation and connect.
    """
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower().rstrip(".")
    port = parsed.port or 443
    try:
        addrinfos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise ValueError(f"Unable to resolve hostname: {host}") from exc
    valid_ips: list[str] = []
    for addrinfo in addrinfos:
        ip = addrinfo[4][0]
        if _ip_is_blocked(ip):
            raise ValueError(f"Blocked address: {ip}")
        if ip not in valid_ips:
            valid_ips.append(ip)
    if not valid_ips:
        raise ValueError(f"No usable addresses for hostname: {host}")
    return host, port, valid_ips


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS connection that connects to a validated IP while preserving the real
    hostname for the Host header and TLS SNI/certificate verification."""

    def __init__(self, host: str, ip: str, port: int, timeout: float = 15.0) -> None:
        super().__init__(host, port, timeout=timeout)
        self._pinned_ip = ip

    def connect(self) -> None:
        sock = socket.create_connection((self._pinned_ip, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


class MediaOcrProcessor:
    """Extracts and analyzes image attachments in issue threads."""

    def __init__(self, llm_client: LLMClient, config: dict[str, Any]) -> None:
        self.llm_client = llm_client
        self.config = config.get("mediaOcr", {})
        self.enabled = bool(self.config.get("enabled", True))
        self.model_id = self.config.get("model", "mimo-v2.5-free")
        self.max_items = int(self.config.get("maxItems", 4))
        self.max_bytes = int(self.config.get("maxBytesPerItem", MAX_MEDIA_BYTES))

    def extract_image_urls(self, markdown_text: str) -> list[str]:
        """Extract markdown image links and GitHub attachment URLs."""
        if not markdown_text:
            return []

        urls: list[str] = []
        # Match ![alt](url)
        for match in re.finditer(r"!\[.*?\]\((https?://[^\s\)]+)\)", markdown_text):
            urls.append(match.group(1))

        # Match direct GitHub user-attachments URLs
        for match in re.finditer(r"(https?://github\.com/[^\s\)]+/assets/[^\s\)]+)", markdown_text):
            if match.group(1) not in urls:
                urls.append(match.group(1))

        # Filter to allowed extensions or github user-attachments
        valid_urls = []
        for u in urls:
            parsed = urllib.parse.urlparse(u)
            if parsed.hostname in BLOCKED_HOSTS:
                continue
            path_lower = parsed.path.lower()
            if any(path_lower.endswith(ext) for ext in IMAGE_EXTENSIONS) or "user-attachments" in u or "assets" in u:
                valid_urls.append(u)

        return valid_urls[: self.max_items]

    def process_attachments(self, text: str) -> str:
        """Download and analyze image attachments using a multimodal model."""
        if not self.enabled:
            return ""

        urls = self.extract_image_urls(text)
        if not urls:
            return ""

        extracted_summaries: list[str] = []
        fallbacks = self.config.get("fallbackModels", ["mimo-v2.5-free", "grok-4.6"])
        for idx, url in enumerate(urls, 1):
            try:
                data_uri = self._fetch_as_data_uri(url)
                messages = [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": "Extract all visible terminal logs, error codes, kernel panics, ALSA/PipeWire outputs, "
                                "sound card details, or hardware diagnostic information visible in this image verbatim.",
                            },
                            {"type": "image_url", "image_url": {"url": data_uri}},
                        ],
                    }
                ]
                summary = self.llm_client.call_model(
                    self.model_id,
                    messages,
                    max_tokens=1024,
                    min_chars=10,
                    fallback_models=fallbacks,
                )
                extracted_summaries.append(f"#### 📷 Attachment #{idx} Analysis ({url})\n{summary.strip()}")
            except (LLMClientError, Exception) as exc:
                extracted_summaries.append(f"#### 📷 Attachment #{idx} ({url})\n*[Image analysis failed: {exc}]*")

        return "\n\n".join(extracted_summaries)

    def _fetch_bytes(self, url: str) -> tuple[str, bytes]:
        """Fetch a media URL with per-hop SSRF validation and DNS-pinned connections."""
        current_url = url
        seen_urls: set[str] = set()

        for _ in range(MAX_REDIRECT_HOPS + 1):
            if current_url in seen_urls:
                raise ValueError("Redirect loop detected")
            seen_urls.add(current_url)

            reason = _blocked_url_reason(current_url)
            if reason:
                raise ValueError(f"Blocked media URL: {reason}")
            try:
                host, port, pinned_ips = _resolve_pinned_targets(current_url)
            except ValueError as exc:
                raise ValueError(f"Fetch failed for {current_url}: {exc}") from exc
            parsed = urllib.parse.urlparse(current_url)
            path = parsed.path or "/"
            if parsed.query:
                path += f"?{parsed.query}"

            last_exc: Exception | None = None
            redirected_to: str | None = None
            for ip in pinned_ips[:MAX_IP_ATTEMPTS]:
                conn = _PinnedHTTPSConnection(host, ip, port, timeout=15)
                try:
                    conn.request("GET", path, headers={"User-Agent": "hp-pro-c640-linux-ai-bot/1.0", "Accept": "image/*"})
                    resp = conn.getresponse()
                    if resp.status in {301, 302, 303, 307, 308}:
                        location = resp.getheader("Location") or ""
                        if not location:
                            raise ValueError("Redirect response without Location header")
                        redirected_to = urllib.parse.urljoin(current_url, location)
                        break
                    if resp.status != 200:
                        raise ValueError(f"HTTP {resp.status} while fetching {current_url}")
                    content_type = resp.getheader("Content-Type", "image/png").split(";")[0].strip()
                    data = resp.read(self.max_bytes + 1)
                    if len(data) > self.max_bytes:
                        raise ValueError(f"Image exceeds maximum size limit ({self.max_bytes // (1024 * 1024)}MB)")
                    return content_type, data
                except (ValueError, http.client.HTTPException) as exc:
                    raise ValueError(f"Fetch failed for {current_url}: {exc}") from exc
                except (OSError, ssl.SSLError) as exc:
                    last_exc = exc
                finally:
                    conn.close()

            if redirected_to is not None:
                current_url = redirected_to
                continue
            raise ValueError(f"Fetch failed for {current_url}: {last_exc or 'no usable address'}")

        raise ValueError(f"Too many redirects (max {MAX_REDIRECT_HOPS})")

    def _fetch_as_data_uri(self, url: str) -> str:
        content_type, data = self._fetch_bytes(url)
        b64_data = base64.b64encode(data).decode("ascii")
        return f"data:{content_type};base64,{b64_data}"

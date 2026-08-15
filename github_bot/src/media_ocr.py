# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Media and screenshot artifact processor for issue reports and PR attachments."""

from __future__ import annotations

import base64
import re
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from llm_client import LLMClient, LLMClientError

MAX_MEDIA_BYTES = 8 * 1024 * 1024  # 8 MB
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
BLOCKED_HOSTS = {"127.0.0.1", "localhost", "169.254.169.254", "0.0.0.0"}


class MediaOcrProcessor:
    """Extracts and analyzes image attachments in issue threads."""

    def __init__(self, llm_client: LLMClient, config: dict[str, Any]) -> None:
        self.llm_client = llm_client
        self.config = config.get("mediaOcr", {})
        self.enabled = bool(self.config.get("enabled", True))
        self.model_id = self.config.get("model", "mimo-v2.5-free")
        self.max_items = int(self.config.get("maxItems", 4))

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

    def _fetch_as_data_uri(self, url: str) -> str:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "https":
            raise ValueError(f"Insecure scheme: {parsed.scheme}")
        if parsed.hostname in BLOCKED_HOSTS:
            raise ValueError(f"Blocked hostname: {parsed.hostname}")

        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "hp-pro-c640-linux-ai-bot/1.0",
                "Accept": "image/*",
            },
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            content_type = resp.headers.get("Content-Type", "image/png").split(";")[0].strip()
            data = resp.read(MAX_MEDIA_BYTES + 1)
            if len(data) > MAX_MEDIA_BYTES:
                raise ValueError("Image exceeds maximum size limit (8MB)")
            b64_data = base64.b64encode(data).decode("ascii")
            return f"data:{content_type};base64,{b64_data}"

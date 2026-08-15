# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Unit tests for HP Pro c640 Linux GitHub AI Bot."""

import os
import sys
import unittest
from pathlib import Path

# Add src to sys.path
SRC_DIR = Path(__file__).resolve().parents[1] / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from agent_orchestrator import (  # noqa: E402
    extract_suggested_labels,
    validate_triage_report,
)
from deterministic_scanner import DeterministicScanner  # noqa: E402
from llm_client import (  # noqa: E402
    interpolate_env_vars,
    unusable_completion_reason,
)


class TestLLMClientConfig(unittest.TestCase):
    def test_env_interpolation(self) -> None:
        os.environ["TEST_CPA_URL"] = "https://custom-cpa.example.com/v1/"
        os.environ["TEST_API_KEY"] = "secret123"

        template = '{"url": "${TEST_CPA_URL}", "key": "$TEST_API_KEY"}'
        result = interpolate_env_vars(template)

        self.assertIn("https://custom-cpa.example.com/v1/", result)
        self.assertIn("secret123", result)
        self.assertNotIn("${TEST_CPA_URL}", result)

    def test_dynamic_fallback_chain_deduplication(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        # Mock providers and models
        client.providers = {"opencode": {"name": "opencode", "baseUrl": "https://test.example.com", "apikey": "key"}}
        client.models = {
            "model-a": {"id": "model-a", "_provider": "opencode"},
            "model-b": {"id": "model-b", "_provider": "opencode"},
        }
        chain = client.get_dynamic_fallback_chain(["model-a", "model-b", "model-a"])
        self.assertEqual(chain[:2], ["model-a", "model-b"])

    def test_sanitize_model_name_for_display(self) -> None:
        from llm_client import sanitize_model_name_for_display
        self.assertEqual(sanitize_model_name_for_display("gemini-3.7-flash-high"), "gemini-3.7-flash")
        self.assertEqual(sanitize_model_name_for_display("deepseek-v4-flash-free"), "deepseek-v4-flash")
        self.assertEqual(sanitize_model_name_for_display("nemotron-3-ultra-free"), "nemotron-3-ultra")
        self.assertEqual(sanitize_model_name_for_display("gemini-3.5-flash-extra-low"), "gemini-3.5-flash")
        self.assertEqual(sanitize_model_name_for_display("mimo-v2.5-free"), "mimo-v2.5")
        self.assertEqual(sanitize_model_name_for_display("grok-4.6"), "grok-4.6")
        self.assertEqual(sanitize_model_name_for_display("claude-opus-4-6-thinking"), "claude-opus-4-6-thinking")


class TestDeterministicScanner(unittest.TestCase):
    def setUp(self) -> None:
        self.scanner = DeterministicScanner()

    def test_hwdb_single_space_rule(self) -> None:
        bad_hwdb = "+KEYBOARD_KEY_ea=back\n"
        findings = self.scanner.scan_diff_file("keyboard/90-chromebook-keyboard.hwdb", bad_hwdb)
        self.assertTrue(any(f.rule_id == "C640-HWDB-001" for f in findings))

        good_hwdb = "+ KEYBOARD_KEY_ea=back\n"
        findings_good = self.scanner.scan_diff_file("keyboard/90-chromebook-keyboard.hwdb", good_hwdb)
        self.assertFalse(any(f.rule_id == "C640-HWDB-001" for f in findings_good))

    def test_udev_equals_rule(self) -> None:
        bad_rules = '+KERNEL="cros_fp", GROUP="plugdev"\n'
        findings = self.scanner.scan_diff_file("fingerprint/60-cros-fp.rules", bad_rules)
        self.assertTrue(any(f.rule_id == "C640-UDEV-001" for f in findings))

        good_rules = '+KERNEL=="cros_fp", GROUP="plugdev", MODE="0660"\n'
        findings_good = self.scanner.scan_diff_file("fingerprint/60-cros-fp.rules", good_rules)
        self.assertFalse(any(f.rule_id == "C640-UDEV-001" for f in findings_good))

    def test_shell_unguarded_rm(self) -> None:
        bad_sh = "+rm -rf $TARGET/\n"
        findings = self.scanner.scan_diff_file("scripts/setup.sh", bad_sh)
        self.assertTrue(any(f.rule_id == "C640-SH-001" for f in findings))


class TestTriageValidation(unittest.TestCase):
    def test_triage_section_validation(self) -> None:
        required = ["CLASSIFICATION", "ACTIONABILITY", "SUMMARY", "ISSUE_QUALITY_SCORE"]
        complete_report = (
            "CLASSIFICATION\n- bug\n\n"
            "ACTIONABILITY\n- actionable\n\n"
            "SUMMARY\n- Sound is missing.\n\n"
            "ISSUE_QUALITY_SCORE: 85 (actionable)\n"
        )
        valid, missing = validate_triage_report(complete_report, required)
        self.assertTrue(valid)
        self.assertEqual(missing, [])

        incomplete_report = "SUMMARY\n- Sound is missing."
        valid, missing = validate_triage_report(incomplete_report, required)
        self.assertFalse(valid)
        self.assertIn("CLASSIFICATION", missing)
        self.assertIn("ISSUE_QUALITY_SCORE", missing)

    def test_suggested_label_extraction(self) -> None:
        report = (
            "SUGGESTED_LABELS\n"
            "`bug`, `audio`, `ubuntu-debian`, `unallowed-custom-label`\n"
        )
        allowlist = ["bug", "audio", "ubuntu-debian", "hardware"]
        extracted = extract_suggested_labels(report, allowlist)
        self.assertEqual(extracted, ["bug", "audio", "ubuntu-debian"])
        self.assertNotIn("unallowed-custom-label", extracted)


class TestLLMResponseGating(unittest.TestCase):
    def test_rejection_conditions(self) -> None:
        # Finish reason length
        self.assertIsNotNone(unusable_completion_reason("Some text", "length"))
        # Too short
        self.assertIsNotNone(unusable_completion_reason("Short", None, min_chars=100))
        # Missing required marker
        self.assertIsNotNone(unusable_completion_reason("Sufficient length response here " * 5, None, required_markers=["VERDICT"]))
        # Valid completion
        self.assertIsNone(unusable_completion_reason("Sufficient length response here with VERDICT " * 5, "stop", min_chars=20, required_markers=["VERDICT"]))


class TestMediaOcr(unittest.TestCase):
    def test_extract_image_urls(self) -> None:
        from llm_client import LLMClient
        from media_ocr import MediaOcrProcessor
        client = LLMClient()
        ocr = MediaOcrProcessor(client, {"mediaOcr": {"enabled": True, "maxItems": 2}})
        text = "Here is an issue screenshot: ![log](https://example.com/log.png) and another ![dmesg](https://example.com/dmesg.jpg)"
        urls = ocr.extract_image_urls(text)
        self.assertEqual(urls, ["https://example.com/log.png", "https://example.com/dmesg.jpg"])

    def test_process_attachments_disabled_or_empty(self) -> None:
        from llm_client import LLMClient
        from media_ocr import MediaOcrProcessor
        client = LLMClient()
        ocr = MediaOcrProcessor(client, {"mediaOcr": {"enabled": False}})
        self.assertEqual(ocr.process_attachments("![log](https://example.com/log.png)"), "")
        ocr_enabled = MediaOcrProcessor(client, {"mediaOcr": {"enabled": True}})
        self.assertEqual(ocr_enabled.process_attachments("No images here"), "")


class TestStreamAndMessagePrep(unittest.TestCase):
    def test_parse_sse_stream_openai(self) -> None:
        import io
        from llm_client import _parse_sse_stream
        sse_data = (
            b": ping\n\n"
            b'data: {"choices":[{"delta":{"content":"Hello "}}]}\n\n'
            b'data: {"choices":[{"delta":{"content":"World!"},"finish_reason":"stop"}]}\n\n'
            b"data: [DONE]\n\n"
        )
        content, finish_reason = _parse_sse_stream(io.BytesIO(sse_data), "openai-completions", print_progress=False)
        self.assertEqual(content, "Hello World!")
        self.assertEqual(finish_reason, "stop")

    def test_parse_sse_stream_cpa(self) -> None:
        import io
        from llm_client import _parse_sse_stream
        sse_data = (
            b'data: {"type":"response.output_text.delta","delta":"Line 1\\n"}\n\n'
            b'data: {"type":"response.output_text.delta","delta":"Line 2"}\n\n'
            b'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
            b"data: [DONE]\n\n"
        )
        content, finish_reason = _parse_sse_stream(io.BytesIO(sse_data), "responses", print_progress=False)
        self.assertEqual(content, "Line 1\nLine 2")
        self.assertEqual(finish_reason, "completed")

    def test_prepare_messages_multimodal_vs_text(self) -> None:
        from llm_client import _prepare_messages_for_model
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Check this screenshot:"},
                    {"type": "image_url", "image_url": {"url": "https://example.com/pic.png"}},
                ],
            }
        ]
        # Text-only model
        text_model_info = {"id": "deepseek-v4-flash-free", "input": ["text"]}
        prepared_text = _prepare_messages_for_model(messages, text_model_info)
        self.assertIsInstance(prepared_text[0]["content"], str)
        self.assertIn("[Image attached:", prepared_text[0]["content"])

        # Multimodal model
        multi_model_info = {"id": "gemini-3.7-flash-high", "input": ["text", "image"]}
        prepared_multi = _prepare_messages_for_model(messages, multi_model_info)
        self.assertIsInstance(prepared_multi[0]["content"], list)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Unit tests for HP Pro c640 Linux GitHub AI Bot."""

import json
import os
import sys
import tempfile
import unittest
import unittest.mock as mock
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
        saved_env = dict(os.environ)
        try:
            os.environ["TEST_CPA_URL"] = "https://custom-cpa.example.com/v1/"
            os.environ["TEST_API_KEY"] = "secret123"

            template = '{"url": "${TEST_CPA_URL}", "key": "$TEST_API_KEY"}'
            result = interpolate_env_vars(template)

            self.assertIn("https://custom-cpa.example.com/v1/", result)
            self.assertIn("secret123", result)
            self.assertNotIn("${TEST_CPA_URL}", result)
        finally:
            os.environ.clear()
            os.environ.update(saved_env)

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

    def test_version_parsing_and_sorting(self) -> None:
        from llm_client import parse_version_tuple
        self.assertEqual(parse_version_tuple("3.8"), (3, 8))
        self.assertEqual(parse_version_tuple("3.10"), (3, 10))
        self.assertGreater(parse_version_tuple("3.10"), parse_version_tuple("3.9"))
        self.assertGreater(parse_version_tuple("3.8"), parse_version_tuple("3.7"))
        self.assertGreater(parse_version_tuple("1.3"), parse_version_tuple("1.2"))
        self.assertEqual(parse_version_tuple("invalid"), (0,))
        # Type safety: non-string arguments must return (0,)
        self.assertEqual(parse_version_tuple(None), (0,))
        self.assertEqual(parse_version_tuple(123), (0,))
        self.assertEqual(parse_version_tuple([]), (0,))

    def test_resolve_model_alias_with_discovery_cache(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        client._discovery_cache = {
            "cpa": ["gemini-3.6-flash-high", "gemini-3.8-flash-high", "gemini-3.7-flash-high"],
            "opencode": [
                "opencode/muse-spark-1.2-contributor-free",
                "opencode/muse-spark-1.3-contributor-free",
            ],
        }
        import time
        client._discovery_cache_time = time.monotonic()

        self.assertEqual(client.resolve_model_id("gemini-latest-flash-high"), "gemini-3.8-flash-high")
        self.assertEqual(client.resolve_model_id("cpa/gemini-latest-flash-high"), "gemini-3.8-flash-high")
        self.assertEqual(
            client.resolve_model_id("opencode/muse-spark-latest"),
            "opencode/muse-spark-1.3-contributor-free",
        )
        self.assertEqual(
            client.resolve_model_id("muse-spark-latest"),
            "opencode/muse-spark-1.3-contributor-free",
        )
        self.assertEqual(client.resolve_model_id("grok-4.6"), "grok-4.6")

    def test_resolve_model_alias_dynamic_upgrade(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        client._discovery_cache = {
            "cpa": ["gemini-3.6-flash-high", "gemini-3.9-flash-high", "gemini-3.8-flash-high"],
            "opencode": [
                "opencode/muse-spark-1.4-contributor-free",
                "opencode/muse-spark-1.3-contributor-free",
            ],
        }
        import time
        client._discovery_cache_time = time.monotonic()

        self.assertEqual(client.resolve_model_id("gemini-latest-flash-high"), "gemini-3.9-flash-high")
        self.assertEqual(
            client.resolve_model_id("opencode/muse-spark-latest"),
            "opencode/muse-spark-1.4-contributor-free",
        )

    def test_resolve_model_alias_offline_default(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        client._discovery_cache = {}
        import time
        client._discovery_cache_time = time.monotonic()

        self.assertEqual(client.resolve_model_id("gemini-latest-flash-high"), "gemini-3.8-flash-high")
        self.assertEqual(
            client.resolve_model_id("opencode/muse-spark-latest"),
            "opencode/muse-spark-1.3-contributor-free",
        )

    def test_cold_start_discovery_and_fallback_chain_ordering(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        # Mock discover_models to simulate discovering 3.9 on cold start
        def fake_discover(*args, **kwargs):
            client._discovery_cache = {
                "cpa": ["gemini-3.6-flash-high", "gemini-3.9-flash-high", "gemini-3.8-flash-high"],
                "opencode": ["opencode/muse-spark-1.4-contributor-free"],
            }
            import time
            client._discovery_cache_time = time.monotonic()
            return client._discovery_cache

        client.discover_models = fake_discover
        # On cold start (_discovery_cache is None), get_dynamic_fallback_chain must discover first
        # and expand gemini-latest-flash-high with 3.9 ahead of 3.8
        chain = client.get_dynamic_fallback_chain(["gemini-latest-flash-high"])
        self.assertEqual(chain[0], "gemini-3.9-flash-high")
        self.assertEqual(chain[1], "gemini-3.8-flash-high")

    def test_provider_isolation_in_family_versions(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        # Inject an opencode model with gemini in name
        client._discovery_cache = {
            "opencode": ["opencode/gemini-9.9-flash-high", "opencode/muse-spark-1.3-contributor-free"],
            "cpa": ["gemini-3.8-flash-high"],
        }
        import time
        client._discovery_cache_time = time.monotonic()
        # gemini-latest-flash-high is CPA only and must NOT be hijacked by opencode
        versions = client.get_family_versions("gemini-latest-flash-high")
        self.assertEqual(versions[0], "gemini-3.8-flash-high")
        self.assertNotIn("opencode/gemini-9.9-flash-high", versions)

    def test_get_provider_for_model_routing(self) -> None:
        from llm_client import LLMClient
        client = LLMClient()
        client.providers = {
            "opencode": {"name": "opencode"},
            "cpa": {"name": "cpa"},
        }
        # Direct virtual aliases
        self.assertEqual(client.get_provider_for_model("gemini-latest-flash-high")["name"], "cpa")
        self.assertEqual(client.get_provider_for_model("opencode/muse-spark-latest")["name"], "opencode")
        # Prefix routing
        self.assertEqual(client.get_provider_for_model("cpa/custom-model")["name"], "cpa")
        self.assertEqual(client.get_provider_for_model("opencode/custom-model")["name"], "opencode")

    def test_sanitize_model_name_for_display(self) -> None:
        from llm_client import sanitize_model_name_for_display
        self.assertEqual(sanitize_model_name_for_display("gemini-3.8-flash-high"), "gemini-3.8-flash")
        self.assertEqual(sanitize_model_name_for_display("gemini-3.7-flash-high"), "gemini-3.7-flash")
        self.assertEqual(sanitize_model_name_for_display("gemini-latest-flash-high"), "gemini-latest-flash")
        self.assertEqual(sanitize_model_name_for_display("opencode/muse-spark-latest"), "muse-spark-latest")
        self.assertEqual(sanitize_model_name_for_display("opencode/muse-spark-1.3-contributor-free"), "muse-spark-1.3-contributor")
        self.assertEqual(sanitize_model_name_for_display("opencode/muse-spark-1.2-contributor-free"), "muse-spark-1.2-contributor")
        self.assertEqual(sanitize_model_name_for_display("opencode/nemotron-3-ultra-free"), "nemotron-3-ultra")
        self.assertEqual(sanitize_model_name_for_display("opencode/ling-3.0-flash-fin-free"), "ling-3.0-flash-fin")
        self.assertEqual(sanitize_model_name_for_display("opencode/mimo-v2.5-free"), "mimo-v2.5")
        self.assertEqual(sanitize_model_name_for_display("opencode/big-pickle"), "big-pickle")
        self.assertEqual(sanitize_model_name_for_display("grok-4.6"), "grok-4.6")
        self.assertEqual(sanitize_model_name_for_display("claude-opus-4-6-thinking"), "claude-opus-4-6-thinking")


class TestDeterministicScanner(unittest.TestCase):
    def setUp(self) -> None:
        self.scanner = DeterministicScanner()

    def test_hwdb_single_space_rule(self) -> None:
        patch = "a/x b/x\n@@ -1 +1 @@\n"
        bad_hwdb = patch + "+KEYBOARD_KEY_ea=back\n"
        findings = self.scanner.scan_diff_file("keyboard/90-chromebook-keyboard.hwdb", bad_hwdb)
        self.assertTrue(any(f.rule_id == "C640-HWDB-001" for f in findings))

        good_hwdb = patch + "+ KEYBOARD_KEY_ea=back\n"
        findings_good = self.scanner.scan_diff_file("keyboard/90-chromebook-keyboard.hwdb", good_hwdb)
        self.assertFalse(any(f.rule_id == "C640-HWDB-001" for f in findings_good))

    def test_udev_equals_rule(self) -> None:
        patch = "a/x b/x\n@@ -1 +1 @@\n"
        bad_rules = patch + '+KERNEL="cros_fp", GROUP="plugdev"\n'
        findings = self.scanner.scan_diff_file("fingerprint/60-cros-fp.rules", bad_rules)
        self.assertTrue(any(f.rule_id == "C640-UDEV-001" for f in findings))

        good_rules = patch + '+KERNEL=="cros_fp", GROUP="plugdev", MODE="0660"\n'
        findings_good = self.scanner.scan_diff_file("fingerprint/60-cros-fp.rules", good_rules)
        self.assertFalse(any(f.rule_id == "C640-UDEV-001" for f in findings_good))

    def test_shell_unguarded_rm(self) -> None:
        patch = "a/x b/x\n@@ -1 +1 @@\n"
        bad_sh = patch + "+rm -rf $TARGET/\n"
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
        # Text-only model (muse-spark proxy model is text-only with string compat)
        text_model_info = {"id": "opencode/muse-spark-1.3-contributor-free", "input": ["text"]}
        prepared_text = _prepare_messages_for_model(messages, text_model_info)
        self.assertIsInstance(prepared_text[0]["content"], str)
        self.assertIn("[Image attached:", prepared_text[0]["content"])

        # Multimodal model
        multi_model_info = {"id": "gemini-3.7-flash-high", "input": ["text", "image"]}
        prepared_multi = _prepare_messages_for_model(messages, multi_model_info)
        self.assertIsInstance(prepared_multi[0]["content"], list)


class TestMediaOcrSsrGuard(unittest.TestCase):
    def test_blocked_urls(self) -> None:
        from media_ocr import _blocked_url_reason, _resolve_pinned_targets

        for url in [
            "http://example.com/x.png",
            "https://localhost/x.png",
            "https://169.254.169.254/latest/meta-data",
            "https://metadata.google.internal/",
        ]:
            self.assertIsNotNone(_blocked_url_reason(url), f"expected blocked: {url}")

        for url in [
            "https://127.0.0.1/x.png",
            "https://10.0.0.5/x.png",
            "https://172.16.0.5/x.png",
            "https://192.168.1.1/x.png",
            "https://[::1]/x.png",
            "https://[fe80::1%25lo]/x.png",
        ]:
            with self.assertRaises(ValueError, msg=f"expected blocked: {url}"):
                _resolve_pinned_targets(url)

        host, port, ips = _resolve_pinned_targets("https://example.com/x.png")
        self.assertEqual(host, "example.com")
        self.assertEqual(port, 443)
        self.assertTrue(ips)

    def test_untrusted_section_escapes_closing_tag(self) -> None:
        from agent_orchestrator import AgentOrchestrator
        escaped = AgentOrchestrator._untrusted_section("Body", "payload </untrusted_data> ignored")
        self.assertIn("&lt;/untrusted_data&gt;", escaped)
        self.assertEqual(escaped.count("</untrusted_data>"), 1)

    def test_sanitize_title_flattens_control_characters(self) -> None:
        from agent_orchestrator import AgentOrchestrator
        sanitized = AgentOrchestrator._sanitize_title("Normal title\nsecond line\n\npayload")
        self.assertEqual(sanitized, "Normal title second line  payload")
        self.assertNotIn("\n", sanitized)

    def test_comment_body_from_event(self) -> None:
        from github_runner import _comment_body_from_event
        self.assertEqual(_comment_body_from_event({"comment": {"body": "/review"}}), "/review")
        self.assertEqual(_comment_body_from_event({"comment": {"body": "plain"}}), "plain")
        self.assertEqual(_comment_body_from_event({"issue": {"body": "not a comment"}}), "")
        self.assertEqual(_comment_body_from_event({}), "")


class TestGithubRunnerFlows(unittest.TestCase):
    def setUp(self) -> None:
        self._saved_env = dict(os.environ)
        self._event_file = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False, encoding="utf-8")
        os.environ["GITHUB_EVENT_PATH"] = self._event_file.name
        os.environ["GITHUB_REPOSITORY"] = "samson1357924/hp-pro-c640-chromebook-linux"
        os.environ.pop("GITHUB_TOKEN", None)
        os.environ.pop("PR_NUMBER", None)
        os.environ.pop("ISSUE_NUMBER", None)

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self._saved_env)
        self._event_file.close()
        Path(self._event_file.name).unlink(missing_ok=True)

    def _write_event(self, payload: dict) -> None:
        self._event_file.seek(0)
        self._event_file.truncate()
        json.dump(payload, self._event_file)
        self._event_file.flush()

    def test_comment_review_dispatch_on_pr(self) -> None:
        import github_runner
        self._write_event({
            "comment": {"body": "/review"},
            "issue": {"number": 42, "pull_request": {"url": "https://api.github.com/repos/x/y/pulls/42"}},
        })
        real_main = github_runner.main
        dispatched: list[list[str]] = []

        def fake_main(argv: list[str] | None = None) -> int:
            dispatched.append(list(argv or []))
            return 0

        with mock.patch.object(github_runner, "main", fake_main):
            rc = real_main(["--mode=comment", "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(dispatched), 1)
        self.assertIn("--mode=review", dispatched[0])
        self.assertEqual(os.environ.get("PR_NUMBER"), "42")

    def test_comment_triage_dispatch_on_issue(self) -> None:
        import github_runner
        self._write_event({"comment": {"body": "/review"}, "issue": {"number": 7, "title": "t", "body": "b"}})
        real_main = github_runner.main
        dispatched: list[list[str]] = []

        def fake_main(argv: list[str] | None = None) -> int:
            dispatched.append(list(argv or []))
            return 0

        with mock.patch.object(github_runner, "main", fake_main):
            rc = real_main(["--mode=comment", "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertEqual(len(dispatched), 1)
        self.assertIn("--mode=triage", dispatched[0])

    def test_comment_body_read_from_event_not_env(self) -> None:
        import github_runner
        os.environ["COMMENT_BODY"] = "/explain"
        self._write_event({"comment": {"body": "/review"}, "issue": {"number": 9, "pull_request": {"url": "x"}}})
        real_main = github_runner.main
        dispatched: list[list[str]] = []

        def fake_main(argv: list[str] | None = None) -> int:
            dispatched.append(list(argv or []))
            return 0

        with mock.patch.object(github_runner, "main", fake_main):
            rc = real_main(["--mode=comment", "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("--mode=review", dispatched[0])

    def test_triage_reads_title_and_body_from_event(self) -> None:
        import github_runner
        os.environ["ISSUE_TITLE"] = "ENV-SPECIFIED TITLE"
        os.environ["ISSUE_BODY"] = "env body"
        self._write_event({"issue": {"number": 5, "title": "Real title", "body": "Real body", "user": {"login": "sam"}}})
        with mock.patch("github_runner.AgentOrchestrator") as mock_orch:
            instance = mock_orch.return_value
            instance.run_issue_triage.return_value = ("REPORT", ["bug"])
            rc = github_runner.main(["--mode=triage", "--dry-run"])
        self.assertEqual(rc, 0)
        ctx = instance.run_issue_triage.call_args.args[0]
        self.assertEqual(ctx.title, "Real title")
        self.assertEqual(ctx.body, "Real body")
        self.assertEqual(ctx.author, "sam")

    def test_review_mode_resolves_pr_number_from_issue_comment_event(self) -> None:
        import github_runner
        self._write_event({"issue": {"number": 7, "pull_request": {"url": "https://api.github.com/repos/x/y/pulls/7"}}})
        with mock.patch("github_runner.AgentOrchestrator") as mock_orch, mock.patch(
            "github_runner.subprocess.check_output", return_value="fake diff content"
        ):
            instance = mock_orch.return_value
            instance.run_pr_review.return_value = "REPORT"
            rc = github_runner.main(["--mode=review", "--dry-run"])
        self.assertEqual(rc, 0)
        ctx = instance.run_pr_review.call_args.args[0]
        self.assertEqual(ctx.pr_number, 7)

    def test_review_mode_raises_without_diff(self) -> None:
        import github_runner
        self._write_event({"issue": {"number": 7, "pull_request": {"url": "x"}}})
        with mock.patch("github_runner.AgentOrchestrator"), mock.patch("github_runner.subprocess.check_output", side_effect=FileNotFoundError("git")):
            with self.assertRaises(RuntimeError):
                github_runner.main(["--mode=review", "--dry-run"])

    def test_deterministic_scanner_reports_real_line_numbers(self) -> None:
        scanner = DeterministicScanner()
        patch = (
            "a/scripts/test.sh b/scripts/test.sh\n"
            "@@ -1,2 +10,3 @@\n"
            " context\n"
            "-\n"
            "+\n"
            "+rm -rf $TARGET/\n"
        )
        findings = scanner.scan_diff_file("scripts/test.sh", patch)
        self.assertTrue(any(f.rule_id == "C640-SH-001" and f.line_number == 12 for f in findings))

    def test_orchestrator_resolves_role_fallbacks(self) -> None:
        from agent_orchestrator import AgentOrchestrator
        from llm_client import LLMClient
        client = LLMClient()
        client._discovery_cache = {}
        import time
        client._discovery_cache_time = time.monotonic()

        orch = AgentOrchestrator(Path(__file__).resolve().parents[1], client)
        # Role with custom fallbackModels
        role_custom = {"model": "opencode/muse-spark-latest", "fallbackModels": ["gemini-latest-flash-high"]}
        chain = orch._resolve_role_fallbacks(role_custom)
        self.assertIn("gemini-3.8-flash-high", chain)

        # Role defaulting to global fallbackModels
        role_default = {"model": "custom"}
        chain_default = orch._resolve_role_fallbacks(role_default)
        self.assertTrue(len(chain_default) > 0)


if __name__ == "__main__":
    unittest.main()

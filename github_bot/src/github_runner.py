# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""GitHub Actions entry point and REST API dispatcher for HP Pro c640 Linux AI Bot."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from agent_orchestrator import (
    AgentOrchestrator,
    IssueContext,
    ReviewContext,
)
from llm_client import LLMClient


BOT_DIR = Path(__file__).resolve().parents[1]


class GitHubAPIClient:
    """Lightweight GitHub REST API client using standard library."""

    def __init__(self, repo: str, token: str) -> None:
        self.repo = repo
        self.token = token
        self.base_url = f"https://api.github.com/repos/{repo}"

    def _request(
        self,
        endpoint: str,
        *,
        method: str = "GET",
        data: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        raw_response: bool = False,
    ) -> Any:
        url = f"{self.base_url}/{endpoint.lstrip('/')}"
        req_headers = {
            "Authorization": f"token {self.token}",
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "hp-pro-c640-linux-ai-bot/1.0",
        }
        if headers:
            req_headers.update(headers)

        req_data = json.dumps(data).encode("utf-8") if data is not None else None
        req = urllib.request.Request(url, data=req_data, headers=req_headers, method=method)

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_bytes = resp.read()
                if raw_response:
                    return resp_bytes.decode("utf-8", errors="replace")
                if not resp_bytes:
                    return None
                return json.loads(resp_bytes.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            print(f"[GitHubAPI Error] {method} {url} -> HTTP {exc.code}: {detail}", file=sys.stderr)
            raise

    def get_pr(self, pr_number: int) -> dict[str, Any]:
        return self._request(f"pulls/{pr_number}")

    def get_pr_diff(self, pr_number: int) -> str:
        return self._request(f"pulls/{pr_number}", headers={"Accept": "application/vnd.github.v3.diff"}, raw_response=True)

    def get_pr_files(self, pr_number: int) -> list[str]:
        data = self._request(f"pulls/{pr_number}/files") or []
        return [f.get("filename", "") for f in data if isinstance(f, dict) and f.get("filename")]

    def get_issue_comments(self, issue_number: int) -> list[dict[str, Any]]:
        return self._request(f"issues/{issue_number}/comments") or []

    def publish_sticky_comment(self, issue_number: int, body: str, marker: str) -> None:
        """Find an existing bot comment with the matching marker and update it in-place."""
        comments = self.get_issue_comments(issue_number)
        for c in comments:
            c_body = c.get("body", "")
            if marker in c_body:
                cid = c.get("id")
                if cid:
                    print(f"Updating existing bot comment #{cid} with marker {marker}")
                    self._request(f"issues/comments/{cid}", method="PATCH", data={"body": body})
                    return

        print(f"Publishing new comment on issue/PR #{issue_number}")
        self._request(f"issues/{issue_number}/comments", method="POST", data={"body": body})

    def add_issue_labels(self, issue_number: int, labels: list[str]) -> None:
        if not labels:
            return
        print(f"Applying suggested labels to issue #{issue_number}: {labels}")
        self._request(f"issues/{issue_number}/labels", method="POST", data={"labels": labels})


def parse_event_payload() -> dict[str, Any]:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if event_path and Path(event_path).is_file():
        try:
            return json.loads(Path(event_path).read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="HP Pro c640 Linux GitHub AI Bot Runner")
    parser.add_argument("--mode", choices=["review", "triage", "comment", "explain"], default="review", help="Execution mode")
    parser.add_argument("--dry-run", action="store_true", help="Print review/triage output to stdout without modifying GitHub")
    args = parser.parse_args(argv)

    event_payload = parse_event_payload()
    repo_slug = os.environ.get("GITHUB_REPOSITORY", event_payload.get("repository", {}).get("full_name", "samson1357924/hp-pro-c640-chromebook-linux"))
    gh_token = os.environ.get("GITHUB_TOKEN", "")

    # Initialize components
    llm_config_path = BOT_DIR / "config" / "LLM_config.example.json"
    llm_client = LLMClient(llm_config_path)
    orchestrator = AgentOrchestrator(BOT_DIR, llm_client)

    api_client = GitHubAPIClient(repo_slug, gh_token) if gh_token and not args.dry_run else None

    # Handle execution modes
    if args.mode == "review":
        pr_data = event_payload.get("pull_request") or {}
        pr_number = pr_data.get("number") or int(os.environ.get("PR_NUMBER", "0")) or None

        diff_text = ""
        changed_files: list[str] = []
        title = pr_data.get("title", "")
        body = pr_data.get("body", "")
        base_ref = pr_data.get("base", {}).get("ref", "main")
        head_ref = pr_data.get("head", {}).get("ref", "head")

        if api_client and pr_number:
            diff_text = api_client.get_pr_diff(pr_number)
            changed_files = api_client.get_pr_files(pr_number)
        else:
            # Fallback to local git diff
            base_sha = os.environ.get("REVIEW_BASE_REF", "origin/main")
            head_sha = os.environ.get("REVIEW_HEAD_REF", "HEAD")
            try:
                diff_text = subprocess.check_output(["git", "diff", f"{base_sha}...{head_sha}"], text=True, errors="replace")
                changed_files = subprocess.check_output(["git", "diff", "--name-only", f"{base_sha}...{head_sha}"], text=True, errors="replace").splitlines()
            except Exception:
                diff_text = "diff --git a/setup.sh b/setup.sh\n--- a/setup.sh\n+++ b/setup.sh\n@@ -1,3 +1,3 @@\n+# Local test diff\n"
                changed_files = ["setup.sh"]

        ctx = ReviewContext(
            pr_number=pr_number,
            base_ref=base_ref,
            head_ref=head_ref,
            diff_text=diff_text,
            changed_files=changed_files,
            title=title,
            body=body,
        )

        print(f"Running Multi-Agent PR Review on PR #{pr_number}...")
        report = orchestrator.run_pr_review(ctx)

        if args.dry_run or not api_client or not pr_number:
            print("\n=== DRY RUN / LOCAL OUTPUT ===\n")
            print(report)
        else:
            marker = orchestrator.config.get("commentMarker", "<!-- C640_LINUX_AI_REVIEW_REPORT -->")
            api_client.publish_sticky_comment(pr_number, report, marker)

    elif args.mode == "triage":
        issue_data = event_payload.get("issue") or {}
        issue_number = issue_data.get("number") or int(os.environ.get("ISSUE_NUMBER", "0")) or None
        title = os.environ.get("ISSUE_TITLE") or issue_data.get("title", "")
        body = os.environ.get("ISSUE_BODY") or issue_data.get("body", "")
        author = issue_data.get("user", {}).get("login", "")

        comments: list[dict[str, Any]] = []
        if api_client and issue_number:
            comments = api_client.get_issue_comments(issue_number)

        ctx = IssueContext(
            issue_number=issue_number,
            title=title,
            body=body,
            comments=comments,
            author=author,
        )

        print(f"Running Issue Triage Agent on Issue #{issue_number}...")
        report, suggested_labels = orchestrator.run_issue_triage(ctx)

        if args.dry_run or not api_client or not issue_number:
            print("\n=== DRY RUN / LOCAL OUTPUT ===\n")
            print(report)
            print(f"\nSuggested Labels: {suggested_labels}")
        else:
            marker = orchestrator.config.get("triageMarker", "<!-- C640_LINUX_AI_TRIAGE_REPORT -->")
            api_client.publish_sticky_comment(issue_number, report, marker)
            if orchestrator.config.get("triage", {}).get("applySuggestedLabels", True) and suggested_labels:
                api_client.add_issue_labels(issue_number, suggested_labels)

    elif args.mode in {"comment", "explain"}:
        comment_body = os.environ.get("COMMENT_BODY", "")
        issue_data = event_payload.get("issue") or {}
        issue_number = issue_data.get("number") or int(os.environ.get("ISSUE_NUMBER", "0")) or None
        is_pr = bool(issue_data.get("pull_request"))

        if "/triage" in comment_body or (not is_pr and "/review" in comment_body):
            # Dispatch to triage
            return main(["--mode=triage"] + (["--dry-run"] if args.dry_run else []))
        elif is_pr and "/review" in comment_body:
            # Dispatch to review
            return main(["--mode=review"] + (["--dry-run"] if args.dry_run else []))
        elif "/explain" in comment_body or args.mode == "explain":
            title = issue_data.get("title", "")
            body = issue_data.get("body", "")
            diff_or_context = ""
            if api_client and issue_number and is_pr:
                diff_or_context = api_client.get_pr_diff(issue_number)
            summary = orchestrator.run_explanation(title, body, diff_or_context)
            if args.dry_run or not api_client or not issue_number:
                print(summary)
            else:
                marker = orchestrator.config.get("commandMarker", "<!-- C640_LINUX_AI_COMMAND_REPORT -->")
                api_client.publish_sticky_comment(issue_number, summary, marker)

    return 0


if __name__ == "__main__":
    sys.exit(main())

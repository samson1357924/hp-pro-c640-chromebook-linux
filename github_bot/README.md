# HP Pro c640 Chromebook Linux GitHub AI Bot

Production multi-agent GitHub review and issue triage bot for
**HP Pro c640 Chromebook (Google Dratini / Hatch platform) Linux Enablement**.

---

## 🌟 Key Features

1. **🔒 Secure Execution Boundary (`pull_request_target`)**:
   - Executes trusted bot code from the default branch (`main` / `master`).
   - Fetches immutable PR commits into isolated refs
     (`refs/c640-bot/review-base`, `refs/c640-bot/review-head`) with SHA validation.
   - Untrusted fork code is never checked out or executed; fork PR diffs are fetched through the
     GitHub API and only reviewed when opened by a trusted author (OWNER / MEMBER / COLLABORATOR).

2. **⚡ Multi-Provider LLM Engine**:
   - Native integration with **OpenCode Zen** (`https://opencode.ai/zen/v1/`) and **CPA** (`responses` API).
   - Reads `CPA_BASE_URL`, `CPA_API_KEY`, and `OPENCODE_API_KEY` from repository secrets.
   - Automatic retry on token truncation with doubled token budgets.

3. **🔍 Deterministic Rule Pre-Scanner**:
   - AST/regex detection of dangerous `rm -rf` without variable checks in shell scripts.
   - Strict `90-chromebook-keyboard.hwdb` single-space indentation verification.
   - udev `==` comparison rule verification.
   - ChromeOS EC `GUINT32_TO_LE()` little-endian wrapper checks in `crfpmoc` C driver code.

4. **📋 Multi-Agent PR Review Pipeline**:
   - `hardware_driver`: C driver, ALSA UCM2, udev, hwdb, EC fan/battery limits.
   - `script_safety`: ShellCheck, root/user separation (`get_real_user`), backup manifest tracking.
   - `docs_public`: Bilingual sync between `README.md` and `README.zh-TW.md`, REUSE/SPDX licensing, MarkdownLint.
   - `explainer_agent`: Plain-language maintainer summary.

5. **🎯 Decision-First Issue Triage (0–100 Quality Scoring)**:
   - Structured checklist with required sections (`CLASSIFICATION`, `ACTIONABILITY`, `ROOT_CAUSE_HYPOTHESES`,
     `QUALITY_BREAKDOWN`, `MISSING_INFO`).
   - Audio Dummy Output, `/dev/cros_fp` permissions, HWDB DMI mismatch, and S0ix Modern Standby playbooks.
   - Automated label application from allowlisted tags.
   - Sticky comments: updates existing bot comments in-place without timeline spam.

---

## 🚀 Slash Commands

In issue and PR comment threads:

- `/review`: Triggers a fresh multi-agent PR review or issue investigation.
- `/triage`: Runs the issue triage agent to compute quality score and missing-info checklist.
- `/explain`: Generates a non-jargon plain-language summary for maintainers.

---

## 🧪 Local Testing

Run all unit tests locally:

```bash
python3 -m unittest discover -s github_bot/tests -v
```

Dry-run review on local git diff:

```bash
python3 github_bot/src/github_runner.py --mode=review --dry-run
```

Dry-run issue triage on local issue text:

```bash
ISSUE_TITLE="[Bug]: No sound after installing Ubuntu 24.04" \
ISSUE_BODY="Sound card shows Dummy Output in settings. aplay -l shows card 0 sofrt5682." \
python3 github_bot/src/github_runner.py --mode=triage --dry-run
```

---

## Environment Interface

The runner reads everything from the environment (no CLI overrides for
secrets or target selectors):

| Variable | Used for | Required |
|---|---|---|
| `GITHUB_TOKEN` | GitHub REST API auth (comments, labels, PR metadata) | in CI |
| `GITHUB_REPOSITORY` | Repo slug (`owner/repo`) for API calls | in CI |
| `GITHUB_EVENT_PATH` | JSON event payload from the Actions trigger | in CI |
| `PR_NUMBER` / `ISSUE_NUMBER` | Target selector for slash-command dispatches | in CI |
| `REVIEW_BASE_REF` / `REVIEW_HEAD_REF` | Local git diff range when no API token is available | local only |
| `CPA_BASE_URL`, `CPA_API_KEY` | CPA LLM provider (secrets) | for CPA |
| `OPENCODE_API_KEY` | OpenCode Zen LLM provider (secret) | for OpenCode |
| `.env` | Any of the above; auto-loaded from the repo root or `github_bot/` | optional |

Provider/model definitions live in `github_bot/config/LLM_config.example.json`
(copy it to `LLM_config.json`; `${VAR}` placeholders are interpolated from the
environment). The bot resolves its own identity via `GET /user` with
`GITHUB_TOKEN` to decide which comments are its own sticky comments — the
`GITHUB_ACTOR` of the triggering workflow is never trusted for that purpose.

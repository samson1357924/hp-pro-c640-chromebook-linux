# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Deterministic Static Pre-Scanner for HP Pro c640 Linux Enablement code & configs."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Sequence


@dataclass
class ScanFinding:
    rule_id: str
    severity: str  # 'BLOCKER', 'WARNING', 'INFO'
    file_path: str
    line_number: int | None
    message: str
    remediation: str


class DeterministicScanner:
    """Pre-scans PR diffs and repository files for hardware safety, shell hazards, and syntax bugs."""

    def scan_diff_file(self, filename: str, patch_content: str) -> list[ScanFinding]:
        findings: list[ScanFinding] = []
        lines = patch_content.splitlines()

        for idx, line in enumerate(lines, 1):
            if not line.startswith("+") or line.startswith("+++"):
                continue
            added = line[1:]

            # 1. Shell Script Checks
            if filename.endswith(".sh"):
                # Dangerous recursive remove without root guard
                if re.search(r"\brm\s+-(?:r[fF]|[fF]r)\s+(?:/|\$TARGET|\$DIR|\$SANDBOX_DIR)\b", added) and not re.search(r'\[\s+-n\s+"', added):
                    findings.append(ScanFinding(
                        rule_id="C640-SH-001",
                        severity="BLOCKER",
                        file_path=filename,
                        line_number=idx,
                        message="Potential unguarded destructive rm -rf command on critical path.",
                        remediation="Ensure target variable is non-empty before rm -rf (e.g. [ -n \"$DIR\" ] && rm -rf \"$DIR\").",
                    ))

                # Unquoted variable expansion in system path
                if re.search(r"\b(?:cp|mv|install|rm)\s+[^\"\'\s]+\s+/etc/", added) and "$" in added:
                    findings.append(ScanFinding(
                        rule_id="C640-SH-002",
                        severity="WARNING",
                        file_path=filename,
                        line_number=idx,
                        message="Unquoted variable in filesystem modification targeting /etc.",
                        remediation="Always double-quote variables in paths: e.g. cp \"$src\" \"$dst\".",
                    ))

            # 2. HWDB Formatting
            if filename.endswith(".hwdb"):
                # Line defines KEYBOARD_KEY without leading single space
                if re.match(r"^(?:KEYBOARD_KEY|\s{2,}KEYBOARD_KEY|\tKEYBOARD_KEY)", added):
                    findings.append(ScanFinding(
                        rule_id="C640-HWDB-001",
                        severity="BLOCKER",
                        file_path=filename,
                        line_number=idx,
                        message="udev HWDB properties must start with exactly one single space.",
                        remediation="Prefix property line with a single space: ' KEYBOARD_KEY_ea=back'.",
                    ))

            # 3. udev Rules Syntax
            if filename.endswith(".rules"):
                # Single equal sign for match
                if re.search(r"\b(KERNEL|SUBSYSTEM|ATTRS?|ENV)\s*=\s*\"[^\"]+\"", added):
                    findings.append(ScanFinding(
                        rule_id="C640-UDEV-001",
                        severity="BLOCKER",
                        file_path=filename,
                        line_number=idx,
                        message="udev match key uses assignment '=' instead of comparison '=='.",
                        remediation="Change '=' to '==' for match keys (e.g. KERNEL==\"cros_fp\").",
                    ))

            # 4. Fingerprint C Driver ChromeOS EC Little Endian
            if filename.startswith("fingerprint/driver/") and (filename.endswith(".c") or filename.endswith(".h")):
                # Direct assignment of multi-byte struct members without GUINT32_TO_LE
                if re.search(r"->(cmd|version|params|flags)\s*=\s*(?:[0-9]{2,}|[A-Z_]{3,})\s*;", added) and "TO_LE" not in added and "FROM_LE" not in added:
                    findings.append(ScanFinding(
                        rule_id="C640-EC-001",
                        severity="WARNING",
                        file_path=filename,
                        line_number=idx,
                        message="ChromeOS EC host command struct field assigned without explicit endian conversion.",
                        remediation="Wrap multi-byte fields in GUINT32_TO_LE() or GUINT16_TO_LE() per cros-ec spec.",
                    ))

        # Check SPDX License Header
        if any(filename.endswith(ext) for ext in [".sh", ".c", ".h", ".py"]):
            if patch_content and not re.search(r"SPDX-License-Identifier:", patch_content) and len(lines) > 5:
                # Only check if file seems to be new
                if patch_content.startswith("@@ -0,0"):
                    findings.append(ScanFinding(
                        rule_id="C640-LIC-001",
                        severity="WARNING",
                        file_path=filename,
                        line_number=1,
                        message="New file missing SPDX-License-Identifier header.",
                        remediation="Add '# SPDX-License-Identifier: MIT' or appropriate license header.",
                    ))

        return findings

    def format_findings_markdown(self, findings: Sequence[ScanFinding]) -> str:
        if not findings:
            return "✅ **Deterministic Pre-Scan**: Passed with 0 violations."

        rows = []
        for f in findings:
            emoji = "🚫" if f.severity == "BLOCKER" else ("⚠️" if f.severity == "WARNING" else "ℹ️")
            loc = f"`{f.file_path}`" + (f":{f.line_number}" if f.line_number else "")
            rows.append(f"- {emoji} **[{f.rule_id}]** ({f.severity}) {loc}: {f.message}\n  *Fix*: {f.remediation}")

        return "### 🔍 Deterministic Pre-Scan Findings\n" + "\n".join(rows)

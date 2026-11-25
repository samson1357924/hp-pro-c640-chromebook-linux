#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Independent PAM rule oracle for the re-review #17 / Phase A regressions.

This file never sources lib/pam.sh and never calls its helpers: it re-derives
the rule structure straight from Linux-PAM's syntax so a mutation of the
product parser cannot make the assertions self-proving.

Linux-PAM has no quoting syntax. The first ``#`` on a PHYSICAL line starts a
comment that runs to end of line; the module path is a separate field. A rule
may continue on the next physical line with a trailing backslash, and a
bracketed control may contain whitespace. Only a MODULE PATH BASENAME equal to
``pam_fprintd.so`` counts as an active fingerprint module (the ``sudo`` scope
also counts the stale rust_fp/fp_pam variants).

Phase A P1: a numeric jump whose landing identity changes when fp rules are
removed is UNSAFE even when the new landing is END. Phase A P2: a
pam-auth-update marker does not exempt the check -- a managed stack records a
deferred J record instead of U, and the product's postcondition must prove the
live jump endpoints still match the baseline.

Modes (argv: MODE FILE):

* ``active-fp``   - exit 0 if an active fp module exists, 1 if none, 2 if the
                    file is unreadable or its syntax is uncertain.
* ``nonfp``       - print the ordered ``type<TAB>basename`` list of non-fp rules.
* ``rule-keys``   - print ``filetag|type|control|path|landing`` per non-fp rule.
* ``fp-lines``    - print physical line numbers of fp rules (1-based).
* ``strip``       - print the file bytes with only fp rule lines removed.
* ``records``     - print V/R/D/U/J records in the product parser's shape.
* ``landings``    - print ``<line><TAB><source-id><TAB><landing>`` for jumps.
* ``jump-changed``- exit 0 if any landing change was recorded (J or U), 1 if not.
* ``uncertain``   - exit 0 if the parser would emit U, 1 otherwise.

All print modes exit 2 on unreadable input; ``records`` still prints its U/R/D
records before exiting 3, matching the product parser's contract.
"""

import os
import re
import sys

TYPES = {"auth", "account", "password", "session", "session-noninteractive"}
CONTROLS = {
    "required",
    "requisite",
    "sufficient",
    "optional",
    "binding",
    "substack",
    "include",
    "omit",
}
BRACKET_ACTION = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*=(ignore|bad|die|ok|done|reset|end|[0-9]+)$"
)
NUMERIC_ACTION = re.compile(r"=[0-9]+$")
MANAGED_MARKER = "end of pam-auth-update config"


class Uncertain(Exception):
    """Raised for syntax the oracle refuses to guess about."""

    def __init__(self, records=None, message="uncertain"):
        super().__init__(message)
        self.records = records if records is not None else []


def _strip_comment(text):
    pos = text.find("#")
    return text[:pos] if pos >= 0 else text


def _is_fp(basename):
    return basename == "pam_fprintd.so"


def _parse(path):
    """Return (physical_lines, records, modules, jumps, managed)."""
    with open(path, "rb") as handle:
        raw = handle.read().decode("utf-8", "surrogateescape")
    physical = raw.splitlines(keepends=True)
    filetag = os.path.basename(path)

    records = []
    modules = []  # dicts: type, control, path, base, start, count, jumps, landing
    jumps = []
    managed = False
    idx = 0
    while idx < len(physical):
        start = idx + 1  # 1-based physical line
        line_text = physical[idx].rstrip("\r\n")
        if MANAGED_MARKER in line_text:
            managed = True
        logical = _strip_comment(line_text).strip()
        if not logical:
            records.append(("D", start))
            idx += 1
            continue

        # Join continuation lines; every consumed line belongs to this rule.
        while logical.endswith("\\"):
            logical = logical[:-1].rstrip()
            idx += 1
            if idx >= len(physical):
                records.append(("U", start, "unterminated continuation"))
                raise Uncertain(records)
            logical += " " + _strip_comment(physical[idx].rstrip("\r\n")).strip()
        count = idx + 1 - start + 1
        idx += 1

        if logical.startswith("@"):
            # @include/@substack is one stack entry for jump arithmetic (P3).
            modules.append(
                {
                    "type": "@",
                    "control": "-",
                    "path": logical,
                    "base": logical,
                    "start": start,
                    "count": count,
                    "jumps": [],
                    "landing": "-",
                }
            )
            records.append(("D", start))
            continue

        parts = logical.split()
        rule_type = parts[0]
        bare_type = rule_type[1:] if rule_type.startswith("-") else rule_type
        if bare_type not in TYPES:
            records.append(("U", start, "unknown or missing PAM type"))
            raise Uncertain(records)
        rest = logical[len(rule_type) :].strip()
        if not rest:
            records.append(("U", start, "missing PAM control"))
            raise Uncertain(records)

        jump_values = []
        if rest.startswith("["):
            close = rest.find("]")
            if close < 0:
                records.append(("U", start, "unbalanced bracket control"))
                raise Uncertain(records)
            control = rest[: close + 1]
            bracket = rest[1:close]
            rest = rest[close + 1 :].strip()
            for action in bracket.split():
                if not BRACKET_ACTION.match(action):
                    records.append(("U", start, "uncertain bracket control action"))
                    raise Uncertain(records)
                if NUMERIC_ACTION.search(action):
                    jump_values.append(int(action.split("=", 1)[1]))
        else:
            control = rest.split()[0]
            if control not in CONTROLS:
                records.append(("U", start, "unknown PAM control"))
                raise Uncertain(records)
            rest = rest[len(control) :].strip()

        module_path = rest.split()[0] if rest else ""
        if not module_path or any(ch in module_path for ch in "[]="):
            records.append(("U", start, "missing or malformed module path"))
            raise Uncertain(records)
        basename = module_path.rsplit("/", 1)[-1]
        module = {
            "type": rule_type,
            "control": control,
            "path": module_path,
            "base": basename,
            "start": start,
            "count": count,
            "jumps": jump_values,
            "landing": "-",
        }
        modules.append(module)
        if jump_values:
            jumps.append((len(modules) - 1, start, jump_values))
        if _is_fp(basename):
            records.append(("R", start, count, rule_type, basename))
        else:
            records.append(
                (
                    "V",
                    rule_type,
                    control,
                    module_path,
                    start,
                    filetag,
                    "-",
                )
            )

    _check_jumps(records, modules, jumps, managed)
    # Refresh V records now that each module's landing is known.
    for index, record in enumerate(records):
        if record[0] == "V":
            # A V record's start line identifies its module uniquely.
            for candidate in modules:
                if candidate["start"] == record[4] and not _is_fp(candidate["base"]):
                    records[index] = record[:6] + (candidate["landing"],)
                    break
    return physical, records, modules, jumps, managed


def _check_jumps(records, modules, jumps, managed):
    """Phase A: ANY jump landing change after fp removal is reported.

    An unmanaged stack emits U (fail closed before any write). A
    pam-auth-update-managed stack emits a deferred J record: the product may
    continue only if its postcondition re-proves the live jump endpoints.
    """
    if not jumps:
        return
    kept = []
    original_to_kept = {}
    for pos, module in enumerate(modules):
        if _is_fp(module["base"]):
            continue
        original_to_kept[pos] = len(kept)
        kept.append(module)
    for source, line, values in jumps:
        if _is_fp(modules[source]["base"]):
            continue
        source_kept = original_to_kept.get(source)
        if source_kept is None:
            continue
        source_id = "{}:{}".format(modules[source]["type"], modules[source]["path"])
        landings = []
        for number in values:
            before = source + number + 1
            after = source_kept + number + 1
            identity_before = (
                "END"
                if before >= len(modules)
                else "{}:{}".format(modules[before]["type"], modules[before]["path"])
            )
            identity_after = (
                "END"
                if after >= len(kept)
                else "{}:{}".format(kept[after]["type"], kept[after]["path"])
            )
            landings.append(identity_before)
            # Landing on END is NOT a safe exception (Phase A P1).
            if identity_before != identity_after:
                if managed:
                    records.append(
                        ("J", line, source_id, identity_before, identity_after)
                    )
                else:
                    records.append(
                        (
                            "U",
                            line,
                            "numeric jump target identity changes after removing pam_fprintd.so",
                        )
                    )
                    raise Uncertain(records)
        modules[source]["landing"] = "|".join(landings)


def _render(physical, fp_lines):
    drop = set()
    for line, count in fp_lines:
        drop.update(range(line, line + count))
    return "".join(
        text for number, text in enumerate(physical, 1) if number not in drop
    )


def _print_records(records):
    for record in records:
        print("\t".join(str(field) for field in record))


def main(argv):
    if len(argv) != 3:
        print("usage: pam_rule_oracle.py MODE FILE", file=sys.stderr)
        return 2
    mode, path = argv[1], argv[2]
    records = []
    try:
        physical, records, modules, _jumps, _managed = _parse(path)
    except OSError as exc:
        print("oracle: {}: {}".format(path, exc), file=sys.stderr)
        return 2
    except Uncertain as exc:
        records = list(exc.records)
        if mode == "records":
            _print_records(records)
            return 3
        if mode == "uncertain":
            return 0
        if mode == "jump-changed":
            return 0
        if mode == "active-fp":
            return 2
        print("oracle: uncertain PAM syntax in {}".format(path), file=sys.stderr)
        return 2

    if mode == "active-fp":
        return 0 if any(_is_fp(item["base"]) for item in modules) else 1
    if mode == "uncertain":
        # A deferred J record is a control-flow change too: the product emits
        # U for both managed and unmanaged stacks (Phase A P1/P2).
        return 0 if any(record[0] in ("J", "U") for record in records) else 1
    if mode == "jump-changed":
        return 0 if any(record[0] in ("J", "U") for record in records) else 1
    if mode == "nonfp":
        for item in modules:
            if not _is_fp(item["base"]):
                print("{}\t{}".format(item["type"], item["base"]))
        return 0
    if mode == "rule-keys":
        tag = os.path.basename(path)
        for item in modules:
            if not _is_fp(item["base"]):
                print(
                    "{}|{}|{}|{}|{}".format(
                        tag, item["type"], item["control"], item["path"], item["landing"]
                    )
                )
        return 0
    if mode == "landings":
        for item in modules:
            if item["jumps"] and not _is_fp(item["base"]):
                print(
                    "{}\t{}:{}\t{}".format(
                        item["start"], item["type"], item["path"], item["landing"]
                    )
                )
        return 0
    fp_lines = [
        (int(record[1]), int(record[2]))
        for record in records
        if record[0] == "R"
    ]
    if mode == "fp-lines":
        for line, _count in fp_lines:
            print(line)
        return 0
    if mode == "strip":
        sys.stdout.write(_render(physical, fp_lines))
        return 0
    if mode == "records":
        _print_records(records)
        return 0
    print("oracle: unknown mode {}".format(mode), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

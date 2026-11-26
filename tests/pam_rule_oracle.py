#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Independent PAM rule oracle for the re-review #17 / #19 Phase A regressions.

This file never sources lib/pam.sh, never imports lib/pam_stack_model.py and
never calls either helper: it re-derives rule structure straight from Linux-PAM
syntax.  Finding #1 of re-review #19 showed that a file-global module index is
wrong -- Linux-PAM builds a SEPARATE handler stack per management group.  This
oracle therefore indexes jumps inside the rule's own (auth/account/password/
session) group, ignores ``N=0`` (libpam treats it as ``ignore``), keys a jump
target by a unique rule instance (control + all arguments + duplicate index)
and refuses to guess about @substack or unresolved include targets. It also
separates group-agnostic `@include` from type-prefixed `auth include X`:
only the former contributes all groups, the latter only its own.

Linux-PAM has no quoting syntax.  The first ``#`` on a PHYSICAL line starts a
comment that runs to end of line; the module path is a separate field.  A rule
may continue on the next physical line with a trailing backslash, and a
bracketed control may contain whitespace.  Only a MODULE PATH BASENAME equal to
``pam_fprintd.so`` counts as an active fingerprint module.

Modes (argv):

* ``active-fp FILE``      - exit 0 if an active fp module exists, 1 if none,
                            2 if the file is unreadable or syntax is uncertain.
* ``nonfp FILE``          - ordered ``type<TAB>basename`` list of non-fp rules.
* ``rule-keys FILE``      - ``filetag|group|instance_id|control|path|argsfp``.
* ``fp-lines FILE``       - physical line numbers of fp rules (1-based).
* ``strip FILE``          - file bytes with only fp rule lines removed.
* ``records FILE``        - V/R/D/U/I records (product awk parser shape).
* ``landings FILE``       - ``<line><TAB><source-id><TAB><target>`` per jump.
* ``stack FILE``          - product-compatible per-group descriptors (P lines)
                            for every non-fp rule, including expanded includes.
* ``parity OLD NEW``      - exit 0 iff the transformation only removes fp rules
                            (and optionally adds one canonical sudo rule), all
                            other descriptors are token-equal and ordered;
                            1 = unsafe, 2 = unsupported topology/input.
* ``uncertain FILE``      - exit 0 iff this parser would emit U (unsafe jump).
* ``jump-changed FILE``   - exit 0 iff any landing change was recorded.

Print modes exit 2 on unreadable input; ``records`` still prints its U/R/D/I
records before exiting 3, matching the product parser's contract.
"""

import hashlib
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
NUMERIC_ACTION = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=([0-9]+)$")
CANONICAL_LINE = "auth sufficient pam_fprintd.so max-tries=1 timeout=10"


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


def _group(raw_type):
    bare = raw_type[1:] if raw_type.startswith("-") else raw_type
    return "session" if bare == "session-noninteractive" else bare


def _argsfp(args):
    return hashlib.sha256("\x1f".join(args).encode("utf-8", "surrogateescape")).hexdigest()[:16]


def _parse(path):
    """Return (physical_lines, records, rules, filetag)."""
    with open(path, "rb") as handle:
        raw = handle.read().decode("utf-8", "surrogateescape")
    physical = raw.splitlines(keepends=True)
    filetag = os.path.basename(path)
    records = []
    rules = []
    idx = 0
    while idx < len(physical):
        start = idx + 1
        line_text = physical[idx].rstrip("\r\n")
        logical = _strip_comment(line_text).strip()
        if not logical:
            records.append(("D", start))
            idx += 1
            continue
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
            directive = logical[1:].strip()
            kind = directive.split()[0] if directive else ""
            target = directive[len(kind):].strip() if kind else ""
            if kind not in ("include", "substack") or not target:
                records.append(("U", start, "unknown @ directive"))
                raise Uncertain(records)
            # `@` is group-agnostic (all groups); a type-prefixed directive
            # only introduces its own group's lines (man7 pam.conf(5)).
            records.append(("I", start, kind, target, filetag, "@"))
            rules.append(
                {
                    "kind": kind,
                    "raw_type": "",
                    "group": "",
                    "control": kind,
                    "path": target,
                    "args": (),
                    "start": start,
                    "count": count,
                    "base": target,
                    "fp": False,
                }
            )
            continue

        parts = logical.split()
        rule_type = parts[0]
        bare_type = rule_type[1:] if rule_type.startswith("-") else rule_type
        if bare_type not in TYPES:
            records.append(("U", start, "unknown or missing PAM type"))
            raise Uncertain(records)
        rest = logical[len(rule_type):].strip()
        if not rest:
            records.append(("U", start, "missing PAM control"))
            raise Uncertain(records)

        jump_values = []
        if rest.startswith("["):
            close = rest.find("]")
            if close < 0:
                records.append(("U", start, "unbalanced bracket control"))
                raise Uncertain(records)
            # Bracket whitespace is not significant to libpam; normalise it so
            # a reformat cannot change a rule identity (P3).
            control = "[" + " ".join(rest[1:close].split()) + "]"
            bracket = rest[1:close]
            rest = rest[close + 1:].strip()
            for action in bracket.split():
                if not BRACKET_ACTION.match(action):
                    records.append(("U", start, "uncertain bracket control action"))
                    raise Uncertain(records)
                match = NUMERIC_ACTION.match(action)
                if match:
                    jump_values.append(int(match.group(1)))
        else:
            control = rest.split()[0]
            if control not in CONTROLS:
                records.append(("U", start, "unknown PAM control"))
                raise Uncertain(records)
            rest = rest[len(control):].strip()

        fields = rest.split()
        module_path = fields[0] if fields else ""
        if not module_path or any(ch in module_path for ch in "[]="):
            records.append(("U", start, "missing or malformed module path"))
            raise Uncertain(records)
        basename = module_path.rsplit("/", 1)[-1]
        args = tuple(fields[1:])
        if control in ("include", "substack"):
            # Keep the prefix type: `auth include X` contributes only auth
            # lines; `@include X` (above) contributes every group's lines.
            records.append(("I", start, control, module_path, filetag, rule_type))
            rules.append(
                {
                    "kind": control,
                    "raw_type": rule_type,
                    "group": _group(rule_type),
                    "control": control,
                    "path": module_path,
                    "args": (),
                    "start": start,
                    "count": count,
                    "base": module_path,
                    "fp": False,
                }
            )
            continue
        rule = {
            "kind": "module",
            "raw_type": rule_type,
            "group": _group(rule_type),
            "control": control,
            "path": module_path,
            "args": args,
            "start": start,
            "count": count,
            "base": basename,
            "fp": _is_fp(basename),
            "jumps": jump_values,
        }
        rules.append(rule)
        if rule["fp"]:
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
                    " ".join(args),
                    1 if rule["fp"] else 0,
                    1 if logical == CANONICAL_LINE else 0,
                )
            )
    return physical, records, rules, filetag


def _numeric_actions(control):
    if not control.startswith("["):
        return []
    actions = []
    for token in control[1:-1].split():
        match = NUMERIC_ACTION.match(token)
        if match:
            actions.append((token, int(match.group(1))))
    return actions


def _instance_id(rule, tag, include_path, dup_index):
    return "{}|{}|{}|{}|{}|{}|{}".format(
        tag,
        rule["group"],
        "/".join(include_path),
        rule["path"],
        rule["control"],
        _argsfp(rule["args"]),
        dup_index,
    )


def _expand(rules, tag, group, include_path, resolver, depth=0):
    """Expand includes for one group; opaque boundaries block strict jumps."""
    if depth > 12 or tag in include_path:
        raise Uncertain([], "PAM include cycle or excessive depth")
    markers = []
    for rule in rules:
        if rule["kind"] == "module":
            if rule["group"] == group:
                markers.append((rule["start"], "module", rule))
        elif rule["kind"] in ("include", "substack"):
            # `@`-form has group == "" and applies to every group; a
            # type-prefixed directive applies only to its own group.
            if rule["group"] and rule["group"] != group:
                continue
            markers.append((rule["start"], rule["kind"], rule["path"]))
    if not markers:
        return []
    markers.sort(key=lambda item: item[0])
    expanded = []
    for _line, kind, payload in markers:
        if kind == "module":
            expanded.append(("rule", payload, include_path, tag))
        elif kind == "include":
            nested = resolver(payload)
            if nested is None:
                expanded.append(("boundary", payload, include_path, payload))
            else:
                for entry in _expand(nested, payload, group, include_path + (tag,), resolver, depth + 1):
                    expanded.append(entry)
        else:
            # A substack boundary belongs to the frame that declares it,
            # matching the product model's `filetag=service` (not the target).
            expanded.append(("substack", payload, include_path, tag))
    return expanded


def _resolver_for(path):
    """Resolve include targets beside one fixture, with the same fail-closed
    rules for unsafe path components and unparseable targets."""
    directory = os.path.dirname(os.path.abspath(path))

    def resolver(name):
        if not name or "/" in name or ".." in name:
            return None
        candidate = os.path.join(directory, name)
        if not os.path.isfile(candidate):
            return None
        try:
            return _parse(candidate)[2]
        except (OSError, Uncertain):
            return None

    return resolver


def _descriptors(rules, tag, resolver):
    """Return (descriptors, unsafe) for all groups of one service."""
    descriptors = []
    unsafe = False
    # Match the product model: groups with actual module rules, always auth.
    # Include/substack directives are markers inside a group, not a group of
    # their own (otherwise a session substack would create a phantom session
    # descriptor that the product does not emit).
    groups = sorted({"auth"} | {r["group"] for r in rules if r["kind"] == "module" and r["group"]})
    for group in groups:
        expanded = _expand(rules, tag, group, (), resolver)
        counters = {}
        entries = []  # (module-position or None, rule, instance-id, owner-tag)
        position = 0
        for kind, payload, include_path, owner_tag in expanded:
            if kind == "rule":
                key = (owner_tag, group, payload["path"], payload["args"])
                index = counters.get(key, 0)
                counters[key] = index + 1
                entries.append(
                    (
                        position,
                        payload,
                        _instance_id(payload, owner_tag, include_path, index),
                        owner_tag,
                    )
                )
                position += 1
            else:
                # An opaque include/substack frame is still ONE handler in the
                # parent stack. Emit its descriptor in stack order so the
                # independent oracle matches the product model exactly.
                boundary_path = (
                    "substack:" if kind == "substack" else "include:"
                ) + payload
                boundary = {
                    "group": group,
                    "path": boundary_path,
                    "control": "substack" if kind == "substack" else "-",
                    "args": (),
                }
                key = (owner_tag, group, boundary_path, ())
                index = counters.get(key, 0)
                counters[key] = index + 1
                entries.append(
                    (
                        None,
                        boundary,
                        _instance_id(boundary, owner_tag, include_path, index),
                        owner_tag,
                    )
                )
        modules = [entry for entry in entries if entry[0] is not None]
        for pos, rule, instance_id, _owner_tag in entries:
            if pos is None:
                descriptors.append(
                    (
                        tag,
                        group,
                        instance_id,
                        group,
                        "0",
                        rule["control"],
                        rule["path"],
                        _argsfp(()),
                        "0",
                        "",
                        "",
                    )
                )
                continue
            targets = []
            actions = []
            for action, number in _numeric_actions(rule["control"]):
                actions.append(action)
                if number == 0:
                    targets.append("ignore")
                    continue
                target = pos + number + 1
                if target >= len(modules):
                    targets.append("END")
                    continue
                target_id = modules[target][2]
                targets.append(target_id)
                if target_id != instance_id and _would_change_decision(rule, modules[target][1]):
                    unsafe = True
            descriptors.append(
                (
                    tag,
                    group,
                    instance_id,
                    rule["raw_type"],
                    "1" if rule["raw_type"].startswith("-") else "0",
                    rule["control"],
                    rule["path"],
                    _argsfp(rule["args"]),
                    "1" if rule["fp"] else "0",
                    "|".join(targets),
                    "|".join(actions),
                )
            )
    return descriptors, unsafe


def _would_change_decision(source, target):
    """Best-effort static check: jumping to an fp rule is a decision change
    when that rule disappears.  The product oracle proves this with the real
    transformation; here we only need to flag the landing identity."""
    return target["fp"]


def _render(descriptor):
    tag, group, iid, raw, dash, control, path, argsfp, fp, targets, actions = descriptor
    return "\t".join(
        ("P", tag, group, iid, raw, dash, control, path, argsfp, fp, targets, actions)
    )


def _stack_instance_ids(stack, tag):
    """Unique instance ids for one group's flat handler stack."""
    counters = {}
    ids = []
    for rule in stack:
        key = (tag, rule["group"], rule["path"], rule["args"])
        index = counters.get(key, 0)
        counters[key] = index + 1
        ids.append(_instance_id(rule, tag, (), index))
    return ids


def check_jumps(records, rules, tag):
    """Compute per-group landings and append U records for unsafe jumps.

    Landing identity is the UNIQUE rule instance (control + all arguments +
    duplicate index), never just ``type:path``: two instances of the same
    module with different arguments are different jump destinations.
    """
    for group in sorted({r["group"] for r in rules if r["kind"] == "module" and r["group"]}):
        stack = [r for r in rules if r["kind"] == "module" and r["group"] == group]
        kept = [r for r in stack if not r["fp"]]
        stack_ids = _stack_instance_ids(stack, tag)
        kept_ids = _stack_instance_ids(kept, tag)
        for position, rule in enumerate(stack):
            if rule["fp"]:
                continue
            actions = _numeric_actions(rule["control"])
            if not actions:
                continue
            kept_position = sum(1 for r in stack[:position] if not r["fp"])
            targets = []
            for _action, number in actions:
                if number == 0:
                    targets.append("ignore")
                    continue
                before = position + number + 1
                after = kept_position + number + 1
                before_id = "END" if before >= len(stack) else stack_ids[before]
                after_id = "END" if after >= len(kept) else kept_ids[after]
                # Human-readable landing keeps the historical `type:path`
                # shape for diagnostics, but the SAFETY comparison uses the
                # unique instance identity above.
                targets.append(
                    "END"
                    if before >= len(stack)
                    else "{}:{}".format(stack[before]["raw_type"], stack[before]["base"])
                )
                if before_id != after_id:
                    records.append(
                        (
                            "U",
                            rule["start"],
                            "numeric jump target identity changes after removing fingerprint module",
                        )
                    )
                    raise Uncertain(records)
            rule["landing"] = "|".join(targets)
    return records


def main(argv):
    if len(argv) < 2:
        print("usage: pam_rule_oracle.py MODE FILE [NEW]", file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "parity":
        if len(argv) != 4:
            print("usage: pam_rule_oracle.py parity OLD NEW", file=sys.stderr)
            return 2
        return _parity(argv[2], argv[3])
    if len(argv) != 3:
        print("usage: pam_rule_oracle.py MODE FILE", file=sys.stderr)
        return 2
    path = argv[2]
    records = []
    try:
        physical, records, rules, tag = _parse(path)
        check_jumps(records, rules, tag)
    except OSError as exc:
        print("oracle: {}: {}".format(path, exc), file=sys.stderr)
        return 2
    except Uncertain as exc:
        records = list(exc.records)
        if mode == "records":
            _print_records(records)
            return 3
        if mode in ("uncertain", "jump-changed"):
            return 0
        if mode == "active-fp":
            return 2
        print("oracle: uncertain PAM syntax in {}".format(path), file=sys.stderr)
        return 2

    if mode == "active-fp":
        return 0 if any(r.get("fp") for r in rules if r["kind"] == "module") else 1
    if mode in ("uncertain", "jump-changed"):
        return 0 if any(record[0] == "U" for record in records) else 1
    if mode == "nonfp":
        for rule in rules:
            if rule["kind"] == "module" and not rule["fp"]:
                print("{}\t{}".format(rule["raw_type"], rule["base"]))
        return 0
    if mode == "rule-keys":
        for rule in rules:
            if rule["kind"] == "module" and not rule["fp"]:
                print(
                    "{}|{}|{}|{}|{}".format(
                        tag, rule["group"], rule["control"], rule["path"], _argsfp(rule["args"])
                    )
                )
        return 0
    if mode == "landings":
        for rule in rules:
            if rule["kind"] == "module" and rule.get("landing"):
                print(
                    "{}\t{}:{}\t{}".format(rule["start"], rule["group"], rule["path"], rule["landing"])
                )
        return 0
    if mode == "stack":
        try:
            descriptors, _unsafe = _descriptors(rules, tag, _resolver_for(path))
        except Uncertain as exc:
            print("oracle: {}".format(exc), file=sys.stderr)
            return 2
        for descriptor in descriptors:
            if descriptor[8] != "1":
                print(_render(descriptor))
        return 0
    fp_lines = [(int(record[1]), int(record[2])) for record in records if record[0] == "R"]
    if mode == "fp-lines":
        for line, _count in fp_lines:
            print(line)
        return 0
    if mode == "strip":
        sys.stdout.write(_render_bytes(physical, fp_lines))
        return 0
    if mode == "records":
        _print_records(records)
        return 0
    print("oracle: unknown mode {}".format(mode), file=sys.stderr)
    return 2


def _render_bytes(physical, fp_lines):
    drop = set()
    for line, count in fp_lines:
        drop.update(range(line, line + count))
    return "".join(text for number, text in enumerate(physical, 1) if number not in drop)


def _print_records(records):
    for record in records:
        print("\t".join(str(field) for field in record))


def _parity(old_path, new_path):
    """Independently verify: only fp removal + optional canonical insertion,
    all other per-group descriptors (including expansion of both `@`-form and
    type-prefixed includes, landing targets and actions) token-equal and
    ordered."""
    try:
        _p, old_records, old_rules, old_tag = _parse(old_path)
        _q, new_records, new_rules, new_tag = _parse(new_path)
        try:
            check_jumps(old_records, old_rules, old_tag)
            check_jumps(new_records, new_rules, new_tag)
        except Uncertain:
            # An unsafe jump landing is an UNSAFE transformation, not merely
            # an unsupported input.
            return 1
        old, _ = _descriptors(old_rules, old_tag, _resolver_for(old_path))
        new, _ = _descriptors(new_rules, new_tag, _resolver_for(new_path))
    except (OSError, Uncertain) as exc:
        print("oracle: unsupported parity input: {}".format(exc), file=sys.stderr)
        return 2
    old_by_id = {descriptor[2]: descriptor for descriptor in old}
    new_by_id = {descriptor[2]: descriptor for descriptor in new}
    for iid, descriptor in old_by_id.items():
        if iid not in new_by_id:
            if descriptor[8] != "1":
                print("oracle: unsafe removal of {}".format(iid), file=sys.stderr)
                return 1
            continue
        if descriptor != new_by_id[iid]:
            print("oracle: unsafe descriptor change at {}".format(iid), file=sys.stderr)
            return 1
    added = [descriptor for iid, descriptor in new_by_id.items() if iid not in old_by_id]
    canonical_tokens = CANONICAL_LINE.split()
    for descriptor in added:
        raw, control, path, argsfp = descriptor[3], descriptor[5], descriptor[6], descriptor[7]
        if not (
            raw == canonical_tokens[0]
            and control == canonical_tokens[1]
            and path == canonical_tokens[2]
            and argsfp == _argsfp(canonical_tokens[3:])
        ):
            print("oracle: unexpected added rule {}".format(descriptor[2]), file=sys.stderr)
            return 1
    # Relative order of surviving descriptors must be preserved.
    old_order = [d[2] for d in old if d[2] in new_by_id]
    new_order = [d[2] for d in new if d[2] in old_by_id]
    cursor = 0
    for iid in old_order:
        while cursor < len(new_order) and new_order[cursor] != iid:
            cursor += 1
        if cursor == len(new_order):
            print("oracle: rule order changed at {}".format(iid), file=sys.stderr)
            return 1
        cursor += 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

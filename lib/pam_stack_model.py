#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Per-management-group PAM handler stack model and transformation proof.

Finding #1 (PR #39 re-review #19): a PAM file is NOT one global handler
sequence.  Linux-PAM builds a separate stack for each management group
(auth/account/password/session) and a numeric jump ``success=N`` counts handlers
inside that group's expanded stack.  The old awk ``nmod``/``kept`` arithmetic
mixed the groups and keyed a landing by ``type:path``, so a mixed auth/account
file could change the *real* authentication decision while the postcondition
claimed the landing was unchanged.

This helper consumes the *raw rule facts* emitted by lib/pam.sh's awk parser
(V/I records; no global landing arithmetic). A group-agnostic `@include` is
expanded for every group; a type-prefixed `auth include X` / `session substack
X` is expanded only for its own group (man7 pam.conf(5)). It treats
unresolvable include/substack topologies as unsupported, and proves that
a planned edit only removes fingerprint rules (and optionally inserts exactly
one canonical sudo rule).  It never touches live PAM files and never sources
lib/pam.sh.

Manifest lines (tab separated): ``<filetag>\\t<records-file>``.  Every listed
file is a service; records files contain V/I/R/U/D rows.  Exit codes:
0 = safe/match, 1 = unsafe transformation, 2 = unsupported topology/input,
3 = usage error.
"""

import sys
from dataclasses import dataclass, field, replace
from typing import Dict, List, Optional, Sequence, Tuple

TYPES = {
    "auth",
    "account",
    "password",
    "session",
    "session-noninteractive",
    "-auth",
    "-account",
    "-password",
    "-session",
    "-session-noninteractive",
}
NUMERIC_ACTION = __import__("re").compile(r"^[A-Za-z_][A-Za-z0-9_]*=([0-9]+)$")
# MUST match _PAM_MODEL_MAX_INCLUDE_DEPTH in lib/pam.sh. The shell builder is
# authoritative about which targets exist in the PAM dir: it resolves every
# reachable include up to this depth and fails closed on an existing target it
# cannot resolve within the cap. Here a manifest entry expanded past the cap is
# likewise unsupported, so neither layer may silently leave a deep rule
# unmodelled (T3's zero-addition/argsfp gate would then be fail-open).
MAX_INCLUDE_DEPTH = 12


class Unsupported(Exception):
    """Raised when the topology or syntax cannot be proven safe."""


def _norm_group(raw_type: str) -> str:
    bare = raw_type[1:] if raw_type.startswith("-") else raw_type
    # Synthetic severity used by the Debian-style test fixtures; libpam's real
    # service files use plain `session` here.  Map it to the session group, but
    # keep the raw type in the descriptor so a change is still visible.
    return "session" if bare == "session-noninteractive" else bare


def _argsfp_canonical(args: Sequence[str]) -> str:
    """Injective hex encoding of an already-tokenised argument vector.

    The authoritative argsfp is produced by lib/pam.sh's awk parser from the
    RAW argument bytes (only libpam-insignificant normalisations applied) and
    travels in the V record.  This helper exists for the synthetic canonical
    rule supplied on the command line, whose tokens come from split() and
    therefore need no further normalisation.  Hex-encoding every byte (with a
    `.` token separator, which is not a hex digit) is one-to-one.
    """
    return ".".join(
        token.encode("utf-8", "surrogateescape").hex() for token in args
    )


@dataclass
class Rule:
    filetag: str
    group: str
    raw_type: str
    kind: str  # module | include | substack | boundary
    control: str
    path: str
    args: Tuple[str, ...]
    start: int
    fp: bool
    canon: bool
    include_path: Tuple[str, ...] = ()
    dup_index: int = 0
    # Phase C/#3: injective hex fingerprint of the full argument vector, read
    # verbatim from the awk V record.  Distinct from `args` (kept for duplicate
    # instance numbering and diagnostics).
    argsfp: str = ""

    @property
    def dash(self) -> int:
        return 1 if self.raw_type.startswith("-") else 0

    @property
    def instance_id(self) -> str:
        return "{}|{}|{}|{}|{}|{}|{}".format(
            self.filetag,
            self.group,
            "/".join(self.include_path),
            self.path,
            self.control,
            self.argsfp,
            self.dup_index,
        )

    def tokens(self) -> Tuple[str, ...]:
        return (
            self.instance_id,
            self.raw_type,
            str(self.dash),
            self.control,
            self.path,
            self.argsfp,
        )


@dataclass
class Handler:
    rule: Rule
    frame: Tuple[str, ...]


@dataclass
class Descriptor:
    service: str
    group: str
    rule: Rule
    targets: Tuple[str, ...]
    actions: Tuple[str, ...]
    unsupported: bool = False

    def tokens(self) -> Tuple[str, ...]:
        return (
            self.service,
            self.group,
            *self.rule.tokens(),
            "|".join(self.targets),
            "|".join(self.actions),
        )

    def render(self) -> str:
        return "\t".join(
            (
                "P",
                self.service,
                self.group,
                self.rule.instance_id,
                self.rule.raw_type,
                str(self.rule.dash),
                self.rule.control,
                self.rule.path,
                self.rule.argsfp,
                "1" if self.rule.fp else "0",
                "|".join(self.targets),
                "|".join(self.actions),
            )
        )


@dataclass
class FileRules:
    filetag: str
    modules: List[Rule] = field(default_factory=list)
    # line, kind, target, scope-group (None = `@`, group-agnostic)
    includes: List[Tuple[int, str, str, Optional[str]]] = field(default_factory=list)
    uncertain: List[str] = field(default_factory=list)


def _read_manifest(path: str) -> List[Tuple[str, str]]:
    entries = []
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            fields = line.split("\t")
            if len(fields) < 2 or not fields[0] or not fields[1]:
                raise Unsupported("malformed model manifest line: {!r}".format(line))
            entries.append((fields[0], fields[1]))
    # An empty manifest is legitimate: a host/sandbox with none of the managed
    # service files present has no stack to prove, and adds no risk.
    return entries


def _read_file(path: str) -> FileRules:
    info = FileRules(filetag="")
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            kind = fields[0]
            if kind == "V":
                # V <type> <control> <path> <start> <filetag> <args> <fp>
                #   <canon> <argsfp>
                # Phase C/#3: a V record without argsfp is untrusted input;
                # fail closed instead of silently falling back to a lossy
                # whitespace-collapsed key.
                if len(fields) < 10:
                    raise Unsupported("short V record (missing argsfp) in {}".format(path))
                raw_type, control, module_path, start, tag, args_s, fp_s, canon_s, argsfp_s = fields[1:10]
                if _norm_group(raw_type) not in TYPES:
                    raise Unsupported("unknown PAM type {}".format(raw_type))
                info.filetag = tag
                info.modules.append(
                    Rule(
                        filetag=tag,
                        group=_norm_group(raw_type),
                        raw_type=raw_type,
                        kind="module",
                        control=control,
                        path=module_path,
                        args=tuple(args_s.split()) if args_s else (),
                        start=int(start),
                        fp=fp_s == "1",
                        canon=canon_s == "1",
                        argsfp=argsfp_s,
                    )
                )
            elif kind == "I":
                # I <start> <kind> <target> <filetag> <scope>
                # `@` (or an empty legacy scope) applies to EVERY group; a raw
                # type (`auth`, `-session`, ...) applies only to that group.
                if len(fields) < 6:
                    raise Unsupported("short I record in {}".format(path))
                scope = fields[5]
                group = None if scope in ("", "@") else _norm_group(scope)
                if group is not None and group not in TYPES:
                    raise Unsupported("unknown PAM include scope {}".format(scope))
                info.includes.append((int(fields[1]), fields[2], fields[3], group))
                info.filetag = fields[4]
            elif kind == "R":
                continue  # sed line ranges are the awk parser's business
            elif kind == "U":
                info.uncertain.append("\t".join(fields[1:]))
            elif kind == "D":
                continue
            else:
                raise Unsupported("unknown record {!r} in {}".format(kind, path))
    if info.uncertain:
        raise Unsupported("uncertain PAM syntax: {}".format("; ".join(info.uncertain)))
    return info


def _number_handler_index(
    handlers: Sequence[Handler], src_index: int, n: int
) -> Tuple[str, bool]:
    """Resolve a numeric jump in a flat, include-expanded group stack.

    ``N=0`` is libpam's "ignore" (no jump), NOT a jump to the next handler.
    Returns (target-identity, supports-substack-safe).
    """
    if n == 0:
        return "ignore", False
    target = src_index + n + 1
    if target >= len(handlers):
        return "END", False
    # A jump may not cross an opaque include/substack frame boundary: libpam
    # cannot jump into (or through) a frame we did not expand.
    for handler in handlers[src_index + 1 : target + 1]:
        if handler.rule.kind == "boundary":
            raise Unsupported("numeric jump crosses an unresolved include/substack boundary")
    return handlers[target].rule.instance_id, False


def _numeric_actions(control: str) -> List[Tuple[str, int]]:
    actions = []
    if not control.startswith("["):
        return actions
    for token in control[1:-1].split():
        match = NUMERIC_ACTION.match(token)
        if match:
            actions.append((token, int(match.group(1))))
    return actions


def _assign_dup_indices(rules: Sequence[Rule]) -> None:
    seen: Dict[Tuple[str, str, str, Tuple[str, ...]], int] = {}
    for rule in rules:
        key = (rule.filetag, rule.group, rule.path, rule.args)
        index = seen.get(key, 0)
        rule.dup_index = index
        seen[key] = index + 1


def _expand(
    service: str,
    group: str,
    files: Dict[str, FileRules],
    include_path: Tuple[str, ...],
    depth: int,
) -> List[Handler]:
    if depth > MAX_INCLUDE_DEPTH:
        raise Unsupported("PAM include graph exceeds depth limit")
    if service in include_path:
        raise Unsupported("PAM include cycle: {}".format(" -> ".join(include_path + (service,))))
    info = files.get(service)
    if info is None:
        # An include target that is not part of the modified closure stays an
        # opaque boundary: it is still ONE handler in the parent stack, and a
        # numeric jump into it is refused rather than guessed.
        boundary = Rule(
            filetag=service,
            group=group,
            raw_type=group,
            kind="boundary",
            control="-",
            path="include:" + service,
            args=(),
            start=0,
            fp=False,
            canon=False,
            include_path=include_path,
        )
        return [Handler(boundary, include_path)]
    handlers: List[Handler] = []
    for rule in info.modules:
        if rule.group != group:
            continue
        # Never mutate the shared parsed Rule: the same included file can be
        # expanded into several services/groups, and a shared instance_id would
        # collapse distinct instances (P2 aliasing).
        handlers.append(
            Handler(replace(rule, filetag=service, include_path=include_path), include_path)
        )
    # Includes are expanded at the position of the directive.  The awk parser
    # emits I records in file order; interpolate by start line so the expanded
    # handler order matches libpam's stack order.  man7 pam.conf(5): `@include`
    # is group-agnostic, while `auth include X` / `session substack X` introduce
    # ONLY that management group's lines.
    directives = sorted(info.includes, key=lambda item: item[0])
    if directives:
        expanded: List[Handler] = []
        # Rebuild order: walk original line positions, inserting inclusions in
        # place.  V records carry their own start line; I records carry theirs.
        markers = [(r.start, "module", r) for r in info.modules if r.group == group]
        for line, kind, target, scope in directives:
            if scope is not None and scope != group:
                continue
            # substack directives are boundaries in the parent frame; their
            # inner jumps cannot be reasoned about by this model and are
            # refused below.
            markers.append((line, kind, target))
        markers.sort(key=lambda item: item[0])
        for _line, what, payload in markers:
            if what == "module":
                module = replace(payload, filetag=service, include_path=include_path)
                expanded.append(Handler(module, include_path))
            elif what == "include":
                target = payload
                if not target or "/" in target or ".." in target:
                    raise Unsupported("unsupported PAM include target {!r}".format(target))
                expanded.extend(_expand(target, group, files, include_path + (service,), depth + 1))
            else:
                boundary = Rule(
                    filetag=service,
                    group=group,
                    raw_type=group,
                    kind="boundary",
                    control="substack",
                    path="substack:" + payload,
                    args=(),
                    start=_line,
                    fp=False,
                    canon=False,
                    include_path=include_path,
                )
                expanded.append(Handler(boundary, include_path))
        handlers = expanded
    return handlers


def _descriptors(manifest: str) -> Dict[Tuple[str, str], List[Descriptor]]:
    files: Dict[str, FileRules] = {}
    for tag, path in _read_manifest(manifest):
        if tag in files:
            raise Unsupported("duplicate filetag {} in manifest".format(tag))
        files[tag] = _read_file(path)
    services = list(files)
    result: Dict[Tuple[str, str], List[Descriptor]] = {}
    for service in services:
        # Same group set as the independent oracle: groups that actually hold
        # module rules, always including auth. Include/substack directives are
        # markers inside those groups, never standalone stack entries.
        groups = sorted({rule.group for rule in files[service].modules} | {"auth"})
        for group in groups:
            handlers = _expand(service, group, files, (), 0)
            # Assign dup indices over the full expansion so identical modules
            # from different include paths remain distinguishable.
            _assign_dup_indices([handler.rule for handler in handlers])
            has_jump = any(
                control.startswith("[") and bool(_numeric_actions(control))
                for handler in handlers
                for control in [handler.rule.control]
            )
            if has_jump and any(
                handler.rule.kind == "boundary"
                and handler.rule.path.startswith("substack:")
                for handler in handlers
            ):
                raise Unsupported(
                    "numeric jump combined with an unmodelled substack in {}/{}".format(
                        service, group
                    )
                )
            descriptors = []
            for index, handler in enumerate(handlers):
                rule = handler.rule
                actions = _numeric_actions(rule.control)
                targets = []
                for action, number in actions:
                    target_id, _ = _number_handler_index(handlers, index, number)
                    if target_id.startswith("include:") or target_id.startswith("substack:"):
                        raise Unsupported("numeric jump into a boundary")
                    targets.append(target_id)
                descriptors.append(Descriptor(service, group, rule, tuple(targets), tuple(a for a, _ in actions)))
            result[(service, group)] = descriptors
    return result


def _canonical_match(rule: Rule, canonical: Sequence[str]) -> bool:
    return (
        rule.raw_type == canonical[0]
        and rule.control == canonical[1]
        and rule.path == canonical[2]
        and tuple(rule.args) == tuple(canonical[3:])
        and rule.argsfp == _argsfp_canonical(canonical[3:])
    )


def _prove(pre_manifest: str, post_manifest: str, canonical: Optional[str]) -> int:
    pre = _descriptors(pre_manifest)
    post = _descriptors(post_manifest)
    canon_tokens = canonical.split() if canonical else []
    if canon_tokens:
        canon_total = sum(
            1
            for descriptors in post.values()
            for descriptor in descriptors
            if _canonical_match(descriptor.rule, canon_tokens)
        )
        if canon_total != 1:
            sys.stderr.write(
                "UNSAFE: canonical rule count {} (expected exactly 1)\n".format(canon_total)
            )
            return 1
    for key in sorted(set(pre) | set(post)):
        before = pre.get(key, [])
        after = post.get(key, [])
        before_by_id = {d.rule.instance_id: d for d in before}
        after_by_id = {d.rule.instance_id: d for d in after}
        removed = [d for d in before if d.rule.instance_id not in after_by_id]
        added = [d for d in after if d.rule.instance_id not in before_by_id]
        for gone in removed:
            if not gone.rule.fp:
                sys.stderr.write(
                    "UNSAFE {}/{}: removed non-fingerprint rule {}\n".format(
                        key[0], key[1], gone.rule.instance_id
                    )
                )
                return 1
        for fresh in added:
            if not canon_tokens or not _canonical_match(fresh.rule, canon_tokens):
                sys.stderr.write(
                    "UNSAFE {}/{}: unexpected added rule {}\n".format(
                        key[0], key[1], fresh.rule.instance_id
                    )
                )
                return 1
        cursor = 0
        for old in before:
            new = after_by_id.get(old.rule.instance_id)
            if new is None:
                continue
            found = False
            for index in range(cursor, len(after)):
                if after[index].rule.instance_id == old.rule.instance_id:
                    cursor = index + 1
                    found = True
                    break
            if not found:
                sys.stderr.write(
                    "UNSAFE {}/{}: rule order changed at {}\n".format(
                        key[0], key[1], old.rule.instance_id
                    )
                )
                return 1
            if old.tokens() != new.tokens():
                sys.stderr.write(
                    "UNSAFE {}/{}: rule descriptor changed: {} -> {}\n".format(
                        key[0], key[1], old.tokens(), new.tokens()
                    )
                )
                return 1
    return 0


def main(argv: Sequence[str]) -> int:
    if len(argv) < 3:
        sys.stderr.write(
            "usage: pam_stack_model.py descriptors [--nonfp] MANIFEST\n"
            "       pam_stack_model.py prove [--canonical LINE] PRE POST\n"
        )
        return 3
    mode = argv[1]
    args = list(argv[2:])
    canonical = None
    nonfp = False
    if "--canonical" in args:
        spot = args.index("--canonical")
        if spot + 1 >= len(args):
            return 3
        canonical = args[spot + 1]
        del args[spot : spot + 2]
    if "--nonfp" in args:
        nonfp = True
        args.remove("--nonfp")
    try:
        if mode == "descriptors" and len(args) == 1:
            for descriptors in _descriptors(args[0]).values():
                for descriptor in descriptors:
                    if not nonfp or not descriptor.rule.fp:
                        print(descriptor.render())
            return 0
        if mode == "prove" and len(args) == 2:
            return _prove(args[0], args[1], canonical)
    except Unsupported as exc:
        sys.stderr.write("UNSUPPORTED PAM topology: {}\n".format(exc))
        return 2
    except (OSError, ValueError) as exc:
        sys.stderr.write("UNSUPPORTED PAM input: {}\n".format(exc))
        return 2
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))

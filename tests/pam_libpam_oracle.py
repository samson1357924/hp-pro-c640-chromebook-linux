#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
"""Independent BLACK-BOX libpam oracle for re-review #19 finding #1.

This oracle does not parse PAM rules at all.  It compiles the tiny fake module
in tests/fixtures/pam_fake_fp.c, writes each fixture into a fresh isolated
``pam_start_confdir`` service directory, calls the REAL libpam
``pam_authenticate`` through ctypes, and compares (a) the decision rc and (b)
the module trace produced through $PAM_TRACE.  No host /etc/pam.d file, real
account, password or hardware is touched.

Usage::

    pam_libpam_oracle.py self-test
    pam_libpam_oracle.py compare [--ignore-trace TAG]...
                                [--include NAME=FILE]... PRE_CONF POST_CONF

``self-test`` uses the reviewer's mixed auth/account fixture: removing the fp
rule changes libpam's decision from 7 (auth failure) to 0 (success), so the
oracle MUST report UNSAFE (exit 1 would be wrong here -- see below).

Exit codes:

* ``compare``: 0 = SAFE (same rc AND same trace), 1 = UNSAFE (decision or
  trace changed), 2 = environment failure (missing symbol, gcc/build failure,
  unreadable fixture).  CI must treat 2 as a hard failure, never as a skip.
* ``self-test``: 0 when the mixed fixture was correctly classified UNSAFE
  (rc 7 -> 0) and the fake module trace proves which instance ran; 1/2
  otherwise.
"""

import ctypes
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_C = os.path.join(HERE, "fixtures", "pam_fake_fp.c")
SERVICE = "oracle-svc"
PAM_CONV_ERR = 1
PAM_SUCCESS = 0

# The reviewer's mixed management-group fixture.  A global module index sees
# the `success=1` landing as `account:pam_permit.so` both before and after
# removing the fp rule; the real auth stack lands on fp before and on the final
# pam_permit afterwards, so libpam's decision changes 7 -> 0.
MIXED_BEFORE = """\
auth [success=1 default=ignore] @PERMIT@ src
auth requisite @DENY@ skipme
account required @PERMIT@ acct
auth required @FAKEMOD@ fp
auth required @PERMIT@ final
"""
MIXED_AFTER = """\
auth [success=1 default=ignore] @PERMIT@ src
auth requisite @DENY@ skipme
account required @PERMIT@ acct
auth required @PERMIT@ final
"""


class OracleError(Exception):
    """Environment/setup failure: must never be reported as a safe result."""


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


CONV_CB = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_CB), ("appdata_ptr", ctypes.c_void_p)]


def _conv_callback(count, messages, responses, data):
    """Never prompt: fixtures only use non-interactive modules."""
    return PAM_CONV_ERR


def _real_module(name):
    for base in (
        "/lib/x86_64-linux-gnu/security",
        "/usr/lib/x86_64-linux-gnu/security",
        "/lib/security",
        "/usr/lib/security",
        "/usr/lib64/security",
    ):
        candidate = os.path.join(base, name)
        if os.path.isfile(candidate):
            return candidate
    raise OracleError("real PAM module {} not found".format(name))


def _compile_fake(workdir):
    if not os.path.isfile(FAKE_C):
        raise OracleError("fake module source missing: {}".format(FAKE_C))
    gcc = shutil.which("gcc")
    if not gcc:
        raise OracleError("gcc is required to build the libpam oracle fake module")
    output = os.path.join(workdir, "pam_fake_fp.so")
    proc = subprocess.run(
        [gcc, "-shared", "-fPIC", "-O2", "-o", output, FAKE_C],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        raise OracleError("gcc failed: {}".format(proc.stderr.decode("utf-8", "replace")))
    if not os.path.isfile(output):
        raise OracleError("gcc produced no fake module")
    return output


def _libpam():
    try:
        lib = ctypes.CDLL("libpam.so.0", use_errno=True)
    except OSError as exc:
        raise OracleError("libpam.so.0 unavailable: {}".format(exc))
    if not hasattr(lib, "pam_start_confdir"):
        # CI host gate MUST fail here -- never silently skip the regression.
        raise OracleError("libpam lacks pam_start_confdir (LIBPAM_1.4) symbol")
    lib.pam_start_confdir.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.POINTER(PamConv),
        ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    lib.pam_start_confdir.restype = ctypes.c_int
    lib.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.pam_authenticate.restype = ctypes.c_int
    lib.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.pam_end.restype = ctypes.c_int
    return lib


def _render(text, fake):
    """Substitute the fake/real module paths shared by service and includes."""
    return (
        text.replace("@FAKEMOD@", fake)
        .replace("@PERMIT@", _real_module("pam_permit.so"))
        .replace("@DENY@", _real_module("pam_deny.so"))
    )


def _write_service(workdir, confdir, text, fake, includes=()):
    path = os.path.join(confdir, SERVICE)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(_render(text, fake))
    # Include targets are resolved by libpam inside the isolated confdir. They
    # get the SAME token substitution so a type-prefixed include can really be
    # executed by libpam rather than silently treated as missing.
    for name, source in includes:
        if not name or "/" in name or ".." in name:
            raise OracleError("unsafe include name: {!r}".format(name))
        with open(source, "r", encoding="utf-8") as handle:
            content = handle.read()
        with open(os.path.join(confdir, name), "w", encoding="utf-8") as handle:
            handle.write(_render(content, fake))
    # A second service ensures libpam really uses the isolated confdir.
    with open(os.path.join(confdir, "other"), "w", encoding="utf-8") as handle:
        handle.write("auth required {}\n".format(_real_module("pam_deny.so")))
    return path


def _authenticate(lib, confdir, trace_path):
    conv = PamConv(CONV_CB(_conv_callback), None)
    handle = ctypes.c_void_p()
    rc_start = lib.pam_start_confdir(
        SERVICE.encode("utf-8"),
        b"oracle-user",
        ctypes.byref(conv),
        confdir.encode("utf-8"),
        ctypes.byref(handle),
    )
    if rc_start != PAM_SUCCESS:
        raise OracleError("pam_start_confdir failed with rc {}".format(rc_start))
    rc = rc_start
    environ = os.environ.get("PAM_TRACE")
    os.environ["PAM_TRACE"] = trace_path
    try:
        rc = lib.pam_authenticate(handle, 0)
    finally:
        if environ is None:
            os.environ.pop("PAM_TRACE", None)
        else:
            os.environ["PAM_TRACE"] = environ
        lib.pam_end(handle, rc)
    with open(trace_path, "r", encoding="utf-8") as handle_file:
        trace = handle_file.read()
    return rc, trace


def _run_fixture(lib, workdir, fake, label, text, includes=()):
    confdir = os.path.join(workdir, "confdir-" + label)
    os.makedirs(confdir, exist_ok=True)
    _write_service(workdir, confdir, text, fake, includes)
    trace_path = os.path.join(workdir, "trace-" + label)
    with open(trace_path, "w", encoding="utf-8"):
        pass
    return _authenticate(lib, confdir, trace_path)


def compare(before_text, after_text, workdir, ignore_tags=(), includes=()):
    lib = _libpam()
    fake = _compile_fake(workdir)
    before = _run_fixture(lib, workdir, fake, "before", before_text, includes)
    after = _run_fixture(lib, workdir, fake, "after", after_text, includes)
    ignored = set(ignore_tags)

    def normalise(trace):
        return tuple(line for line in trace.splitlines() if line not in ignored)

    before_norm = normalise(before[1])
    after_norm = normalise(after[1])
    print("libpam oracle: before rc={} raw_trace={!r} normalised={!r}".format(before[0], before[1], before_norm))
    print("libpam oracle: after  rc={} raw_trace={!r} normalised={!r}".format(after[0], after[1], after_norm))
    if before[0] == after[0] and before_norm == after_norm:
        print("libpam oracle: SAFE (decision and remaining module trace identical)")
        return 0
    print("libpam oracle: UNSAFE (decision or executed module instance changed)")
    return 1


def self_test(workdir):
    lib = _libpam()
    fake = _compile_fake(workdir)
    before = _run_fixture(lib, workdir, fake, "before", MIXED_BEFORE)
    after = _run_fixture(lib, workdir, fake, "after", MIXED_AFTER)
    print("libpam self-test: before rc={} trace={!r}".format(before[0], before[1]))
    print("libpam self-test: after  rc={} trace={!r}".format(after[0], after[1]))
    if before[0] != 7 or "fp" not in before[1]:
        print("libpam self-test FAILED: expected before decision 7 and an 'fp' trace")
        return 1
    if after[0] != 0 or after[1].strip():
        print("libpam self-test FAILED: expected after decision 0 and no module trace")
        return 1
    if before == after:
        print("libpam self-test FAILED: global-index false negative was not reproduced")
        return 1
    print("libpam self-test OK: UNSAFE 7 -> 0 reproduced with a real libpam decision")
    return 0


def main(argv):
    if len(argv) < 2:
        print("usage: pam_libpam_oracle.py self-test|compare PRE POST", file=sys.stderr)
        return 2
    mode = argv[1]
    workdir = tempfile.mkdtemp(prefix="pam-libpam-oracle-")
    try:
        if mode == "self-test":
            return self_test(workdir)
        if mode == "compare":
            ignore_tags = []
            includes = []
            rest = argv[2:]
            while "--ignore-trace" in rest:
                spot = rest.index("--ignore-trace")
                if spot + 1 >= len(rest):
                    return 2
                ignore_tags.append(rest[spot + 1])
                del rest[spot : spot + 2]
            while "--include" in rest:
                spot = rest.index("--include")
                if spot + 1 >= len(rest) or "=" not in rest[spot + 1]:
                    return 2
                name, source = rest[spot + 1].split("=", 1)
                includes.append((name, source))
                del rest[spot : spot + 2]
            if len(rest) != 2:
                return 2
            with open(rest[0], "r", encoding="utf-8") as handle:
                before_text = handle.read()
            with open(rest[1], "r", encoding="utf-8") as handle:
                after_text = handle.read()
            return compare(before_text, after_text, workdir, ignore_tags, includes)
        print("unknown pam_libpam_oracle mode: {}".format(mode), file=sys.stderr)
        return 2
    except (OracleError, OSError) as exc:
        print("libpam oracle ENVIRONMENT FAILURE: {}".format(exc), file=sys.stderr)
        return 2
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

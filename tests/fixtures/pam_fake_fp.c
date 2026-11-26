/* SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
 *
 * Minimal, non-interactive PAM module used ONLY by tests/pam_libpam_oracle.py.
 * It never touches accounts, the host PAM configuration or any device: it
 * appends its argv[0] to $PAM_TRACE and returns PAM_AUTH_ERR unless the first
 * argument is "allow".  That makes a numeric-jump landing observable as a
 * decision (7 vs 0) and as a trace line, without a real login.
 */
#include <stdio.h>
#include <stdlib.h>

typedef struct pam_handle pam_handle_t;

#define PAM_SUCCESS 0
#define PAM_AUTH_ERR 7

static void trace(const char *tag) {
    const char *path = getenv("PAM_TRACE");
    FILE *out;
    if (path == NULL) return;
    out = fopen(path, "a");
    if (out == NULL) return;
    fprintf(out, "%s\n", tag != NULL ? tag : "fake-fp");
    fclose(out);
}

/* This file includes only stdio/stdlib; avoid a string.h dependency by
 * comparing the first argument byte-by-byte. */
static int is_allow(const char *text) {
    const char *want = "allow";
    int i;
    if (text == NULL) return 0;
    for (i = 0; want[i] != '\0'; i++) {
        if (text[i] != want[i]) return 0;
    }
    return text[i] == '\0';
}

int pam_sm_authenticate(pam_handle_t *h, int flags, int argc, const char **argv) {
    (void)h; (void)flags;
    trace(argc > 0 ? argv[0] : "fake-fp");
    return is_allow(argc > 0 ? argv[0] : NULL) ? PAM_SUCCESS : PAM_AUTH_ERR;
}

int pam_sm_setcred(pam_handle_t *h, int flags, int argc, const char **argv) {
    (void)h; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

int pam_sm_acct_mgmt(pam_handle_t *h, int flags, int argc, const char **argv) {
    (void)h; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

int pam_sm_open_session(pam_handle_t *h, int flags, int argc, const char **argv) {
    (void)h; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

int pam_sm_close_session(pam_handle_t *h, int flags, int argc, const char **argv) {
    (void)h; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

int pam_sm_chauthtok(pam_handle_t *h, int flags, int argc, const char **argv) {
    (void)h; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

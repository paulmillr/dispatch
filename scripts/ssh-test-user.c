// Test-only NSS and PTY failure interposition. Never packaged in the helper.
#define _GNU_SOURCE
#include <pwd.h>
#include <stdlib.h>
#include <sys/types.h>
#include <termios.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <glob.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#include <dlfcn.h>
#endif

static int fixture_user_r(uid_t uid, struct passwd *user, char *bytes, size_t length,
                          struct passwd **result) {
    const char *home = getenv("DISPATCH_TEST_HOME"), *shell = getenv("DISPATCH_TEST_SHELL");
#ifdef __APPLE__
    // dyld does not interpose references originating in the replacement image.
    int status = getpwuid_r(uid, user, bytes, length, result);
#else
    int (*original)(uid_t, struct passwd *, char *, size_t, struct passwd **) = dlsym(RTLD_NEXT, "getpwuid_r");
    if (!original) { *result = NULL; return ENOSYS; }
    int status = original(uid, user, bytes, length, result);
#endif
    if (status == 0 && *result && uid == getuid()) {
        if (home) user->pw_dir = (char *)home;
        if (shell) user->pw_shell = (char *)shell;
    }
    return status;
}

static struct passwd *fixture_user(uid_t uid) {
    static struct passwd user;
    static char bytes[65536];
    struct passwd *result;
    return fixture_user_r(uid, &user, bytes, sizeof(bytes), &result) == 0 ? result : NULL;
}

static int fixture_openpty(int *master, int *slave, char *name,
                            const struct termios *term, const struct winsize *size) {
    const char *marker = getenv("DISPATCH_TEST_FAIL_OPENPTY");
    if (marker) {
        const char *home = getenv("DISPATCH_TEST_HOME");
        char pattern[4096];
        int count = snprintf(pattern, sizeof(pattern), "%s/.dispatch/run/*/startup-*", home ? home : "");
        glob_t matches = {0};
        int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd >= 0) {
            if (count > 0 && (size_t)count < sizeof(pattern) && glob(pattern, 0, NULL, &matches) == 0)
                for (size_t index = 0; index < matches.gl_pathc; index++) dprintf(fd, "%s\n", matches.gl_pathv[index]);
            dprintf(fd, "openpty failed\n"); close(fd);
        }
        globfree(&matches);
        errno = ENOSPC; return -1;
    }
#ifdef __APPLE__
    return openpty(master, slave, name, (struct termios *)term, (struct winsize *)size);
#else
    int (*original)(int *, int *, char *, const struct termios *, const struct winsize *) = dlsym(RTLD_NEXT, "openpty");
    if (!original) { errno = ENOSYS; return -1; }
    return original(master, slave, name, term, size);
#endif
}

#ifdef __APPLE__
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } replacement[] = {
    {(const void *)fixture_user, (const void *)getpwuid},
    {(const void *)fixture_user_r, (const void *)getpwuid_r},
    {(const void *)fixture_openpty, (const void *)openpty}
};
#else
struct passwd *getpwuid(uid_t uid) { return fixture_user(uid); }
int getpwuid_r(uid_t uid, struct passwd *user, char *bytes, size_t size, struct passwd **result) {
    return fixture_user_r(uid, user, bytes, size, result);
}
int openpty(int *master, int *slave, char *name, const struct termios *term, const struct winsize *size) {
    return fixture_openpty(master, slave, name, term, size);
}
#endif

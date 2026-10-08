// Test-only account lookup override for native dynamic helpers. Static Linux
// tests use a dedicated disposable account instead; this is never packaged.
#define _GNU_SOURCE
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef __APPLE__
#include <fcntl.h>
#include <stdarg.h>
#include <errno.h>

// Pause only an explicitly selected test login at owner-file publication. This
// exercises the real mkdir-before-owner race without any production test API.
static int fixture_openat(int directory, const char *name, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list arguments; va_start(arguments, flags);
        mode = (mode_t)va_arg(arguments, int);
        va_end(arguments);
    }
    const char *paused = getenv("DISPATCH_TEST_PAUSE_OWNER");
    const char *release = getenv("DISPATCH_TEST_RELEASE_OWNER");
    if (paused && release && (flags & O_CREAT) && strcmp(name, "owner") == 0) {
        int marker = open(paused, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (marker >= 0) {
            close(marker);
            for (int attempt = 0; access(release, F_OK) != 0; ++attempt) {
                if (attempt >= 10000) { errno = ETIMEDOUT; return -1; }
                usleep(1000);
            }
        }
    }
    return openat(directory, name, flags, mode);
}
#endif

static int fixture_getpwuid_r(uid_t uid, struct passwd *pw, char *buffer,
                             size_t size, struct passwd **result) {
    (void)buffer; (void)size;
    const char *home = getenv("DISPATCH_TEST_HOME");
    if (!home || uid != getuid()) { *result = NULL; return 1; }
    memset(pw, 0, sizeof(*pw));
    pw->pw_uid = uid; pw->pw_gid = getgid();
    pw->pw_name = "fixture"; pw->pw_dir = (char *)home;
    pw->pw_shell = "/bin/sh";
    *result = pw;
    return 0;
}
#ifdef __APPLE__
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } replace[] = {
    {(const void *)fixture_getpwuid_r, (const void *)getpwuid_r},
    {(const void *)fixture_openat, (const void *)openat}
};
#else
int getpwuid_r(uid_t uid, struct passwd *pw, char *buffer, size_t size,
               struct passwd **result) {
    return fixture_getpwuid_r(uid, pw, buffer, size, result);
}
#endif

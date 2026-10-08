/* Test-only privilege drop and one failed PTY ioctl for the static Rust helper.
 * Never linked into or packaged with the helper. The VM controller creates the
 * named account and owns the exact helper path before invoking this launcher. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <grp.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pwd.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#if defined(__aarch64__)
#define FIXTURE_ARCH AUDIT_ARCH_AARCH64
#elif defined(__x86_64__)
#define FIXTURE_ARCH AUDIT_ARCH_X86_64
#else
#error Unsupported fixture architecture
#endif

static int fail_pty(const char *marker, const char *home) {
    struct sock_filter instructions[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, FIXTURE_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_ioctl, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[1])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)TIOCSPTLCK, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_USER_NOTIF),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog filter = {(unsigned short)(sizeof(instructions) / sizeof(instructions[0])), instructions};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) return -1;
    int listener = (int)syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_NEW_LISTENER, &filter);
    if (listener < 0) return -1;
    pid_t owner = getpid(), monitor = fork();
    if (monitor < 0) { close(listener); return -1; }
    if (monitor == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != owner) _exit(9);
        close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
        alarm(12);
        struct seccomp_notif request = {0};
        int status;
        do { status = ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, &request); } while (status < 0 && errno == EINTR);
        if (status != 0) _exit(10);
        int output = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (output < 0) _exit(11);
        char pattern[4096];
        int count = snprintf(pattern, sizeof(pattern), "%s/.dispatch/run/*/startup-*", home);
        glob_t matches = {0};
        if (count <= 0 || (size_t)count >= sizeof(pattern) || glob(pattern, 0, NULL, &matches)) _exit(12);
        for (size_t index = 0; index < matches.gl_pathc; ++index) dprintf(output, "%s\n", matches.gl_pathv[index]);
        globfree(&matches);
        dprintf(output, "openpty failed\n");
        close(output);
        struct seccomp_notif_resp response = {.id=request.id, .error=-ENOSPC};
        status = ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, &response);
        close(listener);
        _exit(status == 0 ? 0 : 13);
    }
    close(listener);
    return 0;
}

int main(int argc, char **argv) {
    const char *account = getenv("DISPATCH_TEST_ACCOUNT"), *binary = getenv("DISPATCH_TEST_BINARY");
    const char *home = getenv("DISPATCH_TEST_HOME"), *shell = getenv("DISPATCH_TEST_SHELL");
    if (geteuid() != 0 || argc < 2 || !account || strncmp(account, "hsh-rust-", 9) || !binary || binary[0] != '/' || !home || !shell) return 2;
    struct passwd *user = getpwnam(account);
    if (!user || user->pw_uid < 1000 || strcmp(user->pw_dir, home) || strcmp(user->pw_shell, shell)) return 3;
    uid_t uid = user->pw_uid;
    gid_t gid = user->pw_gid;
    if (setgroups(0, NULL) || setgid(gid) || setuid(uid) || getuid() != uid || geteuid() != uid) return 4;
    if (setenv("USER", account, 1) || setenv("LOGNAME", account, 1)) return 5;
    const char *marker = getenv("DISPATCH_TEST_FAIL_OPENPTY");
    if (marker && strcmp(argv[1], "login") == 0 && fail_pty(marker, home)) { perror("fixture seccomp"); return 6; }
    argv[0] = (char *)binary;
    execv(binary, argv);
    perror("fixture helper");
    return 7;
}

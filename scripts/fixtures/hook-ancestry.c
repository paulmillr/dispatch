// Inert native processes for Rust hook-ownership tests. No shell, tool execution,
// sockets, credentials, or actual Codex session are involved.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static void stop(pid_t child) {
    if (child <= 0) return;
    kill(child, SIGTERM);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

int main(int argc, char **argv) {
    if (argc == 2 && (!strcmp(argv[1], "hook") || !strcmp(argv[1], "event"))) {
        if (write(STDOUT_FILENO, "R", 1) != 1) return 1;
        for (;;) pause();
    }
    if (argc != 4 || strcmp(argv[1], "--hook-fixture") ||
        (strcmp(argv[3], "hook") && strcmp(argv[3], "event"))) return 2;
    int ready[2];
    if (pipe(ready)) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (!child) {
        close(ready[0]);
        if (dup2(ready[1], STDOUT_FILENO) < 0) _exit(1);
        close(ready[1]);
        execl(argv[2], argv[2], argv[3], (char *)NULL);
        _exit(1);
    }
    close(ready[1]);
    char byte = 0;
    ssize_t count;
    do { count = read(ready[0], &byte, 1); } while (count < 0 && errno == EINTR);
    close(ready[0]);
    if (count != 1 || byte != 'R') { stop(child); return 1; }
    printf("%ld %ld\n", (long)getpid(), (long)child);
    fflush(stdout);
    for (;;) {
        count = read(STDIN_FILENO, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        if (byte == 'k') {
            stop(child);
            child = 0;
            puts("stopped");
            fflush(stdout);
        }
    }
    stop(child);
    return 0;
}

/* Test-only native Codex identity hosting a fixture WebSocket connection. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static int relay(int from, int to) {
    char bytes[16384];
    ssize_t count;
    do { count = read(from, bytes, sizeof(bytes)); } while (count < 0 && errno == EINTR);
    if (count <= 0) return -1;
    ssize_t offset = 0;
    while (offset < count) {
        ssize_t written = write(to, bytes + offset, (size_t)(count - offset));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        offset += written;
    }
    return 0;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    if (argc != 7 || strcmp(argv[1], "--remote") || strncmp(argv[2], "unix://", 7) || strcmp(argv[3], "--events-fixture")) return 2;
    const char *path = argv[2] + 7;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) return 2;
    memcpy(address.sun_path, path, strlen(path) + 1);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || chmod(path, 0600) || listen(listener, 1)) { perror("fixture socket"); return 3; }
    puts("ready"); fflush(stdout);
    pid_t child = 0;
    int finished = 0, child_status = 0, connection = -1, bridge = -1;
    for (;;) {
        if (child > 0) {
            int status = 0;
            pid_t result = waitpid(child, &status, WNOHANG);
            if (result == child) { child_status = WIFEXITED(status) ? WEXITSTATUS(status) : 4; child = 0; finished = 1; }
        }
        struct pollfd fds[4] = {{STDIN_FILENO, POLLIN, 0}, {listener, child == 0 && !finished ? POLLIN : 0, 0},
            {connection, POLLIN, 0}, {bridge, POLLIN, 0}};
        int result = poll(fds, 4, 100);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || fds[0].revents) break;
        if (fds[1].revents & POLLIN) {
            connection = accept(listener, NULL, NULL);
            int pair[2];
            if (connection < 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) break;
            child = fork();
            if (child == 0) {
                close(listener); close(connection); close(pair[0]);
                if (dup2(pair[1], STDIN_FILENO) < 0 || dup2(pair[1], STDOUT_FILENO) < 0) _exit(5);
                if (pair[1] > STDOUT_FILENO) close(pair[1]);
                execl("/usr/bin/python3", "python3", argv[4], argv[5], argv[6], (char *)NULL);
                _exit(6);
            }
            close(pair[1]); bridge = pair[0];
            if (child < 0) break;
        }
        if (fds[2].revents && relay(connection, bridge)) { close(connection); connection = -1; }
        if (fds[3].revents && relay(bridge, connection)) { close(bridge); bridge = -1; }
    }
    if (child > 0) { kill(child, SIGTERM); while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {} }
    if (connection >= 0) close(connection);
    if (bridge >= 0) close(bridge);
    close(listener); unlink(path);
    return child_status;
}

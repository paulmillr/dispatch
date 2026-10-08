/* Inert nanocodex TUI identity for the remote control relay tests. It publishes
 * a private registration, authenticates one socket client with its token,
 * answers with a hello snapshot, and echoes each forwarded request back as an
 * event so tests can inspect exactly what the helper relayed. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define INSTANCE "3e0d0f5f-5a83-4986-bdc9-d22e0a8f12a1"
#define SESSION "01a0eda9-5dba-7a53-b720-e274f8dc7ed3"
#define TOKEN "fixture-token-0123456789abcdef0123456789abcdef"

static int write_all(int fd, const char *bytes, size_t length) {
    while (length) {
        ssize_t written = write(fd, bytes, length);
        if (written <= 0) return -1;
        bytes += written; length -= (size_t)written;
    }
    return 0;
}

static int serve(int client) {
    char line[65536];
    size_t used = 0;
    int authenticated = 0;
    for (;;) {
        char *newline = memchr(line, '\n', used);
        if (!newline) {
            if (used == sizeof(line)) return -1;
            ssize_t count = read(client, line + used, sizeof(line) - used);
            if (count <= 0) return 0;
            used += (size_t)count; continue;
        }
        *newline = 0;
        size_t length = (size_t)(newline - line);
        if (!authenticated) {
            if (!strstr(line, "\"auth_token\":\"" TOKEN "\"") || !strstr(line, "\"instance_id\":\"" INSTANCE "\"")) return -1;
            authenticated = 1;
            const char *hello = "{\"type\":\"hello\",\"protocol_version\":1,\"snapshot\":{\"instance_id\":\"" INSTANCE
                "\",\"active_session_id\":\"" SESSION "\",\"active_generation\":\"1\",\"seq\":\"0\"}}\n";
            if (write_all(client, hello, strlen(hello))) return -1;
        } else {
            char prefix[] = "{\"type\":\"echo\",\"data\":";
            if (write_all(client, prefix, strlen(prefix)) || write_all(client, line, length) || write_all(client, "}\n", 2)) return -1;
        }
        memmove(line, newline + 1, used - length - 1);
        used -= length + 1;
    }
}

int main(void) {
    const char *home = getenv("CODEX_HOME");
    if (!home) return 2;
    char path[1024], directory[] = "/tmp/nc-fixture-XXXXXX", socket_path[256];
    snprintf(path, sizeof(path), "%s/nanocodex", home); mkdir(home, 0700); mkdir(path, 0700);
    snprintf(path, sizeof(path), "%s/nanocodex/tui", home); mkdir(path, 0700);
    snprintf(path, sizeof(path), "%s/nanocodex/tui/instances", home);
    if (mkdir(path, 0700) || !mkdtemp(directory)) return 3;
    snprintf(socket_path, sizeof(socket_path), "%s/control.sock", directory);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address)) || chmod(socket_path, 0600) || listen(listener, 4)) return 4;
    struct timeval now;
    gettimeofday(&now, NULL);
    char registration[2048], file[1100];
    snprintf(registration, sizeof(registration),
             "{\"protocol_version\":1,\"instance_id\":\"" INSTANCE "\",\"pid\":%d,\"started_at_unix_ms\":%lld,"
             "\"backend\":\"native\",\"socket_path\":\"%s\",\"auth_token\":\"" TOKEN "\",\"active_generation\":\"1\","
             "\"active_session_id\":\"" SESSION "\",\"conversation\":{\"session_id\":\"" SESSION "\",\"root_session_id\":\"" SESSION
             "\",\"parent_session_id\":null,\"origin\":\"root\",\"role\":\"root\",\"rollout_path\":\"%s/rollout.jsonl\"}}",
             getpid(), (long long)now.tv_sec * 1000 + now.tv_usec / 1000, socket_path, home);
    snprintf(file, sizeof(file), "%s/" INSTANCE ".json", path);
    FILE *output = fopen(file, "w");
    if (!output || chmod(file, 0600) || fputs(registration, output) < 0 || fclose(output)) return 5;
    puts("ready"); fflush(stdout);
    for (;;) {
        struct pollfd fds[2] = {{0, POLLIN, 0}, {listener, POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) return 6;
        if (fds[0].revents) {
            char byte;
            if (read(0, &byte, 1) <= 0) break;
        }
        if (fds[1].revents & POLLIN) {
            int client = accept(listener, NULL, NULL);
            if (client >= 0) { serve(client); close(client); }
        }
    }
    unlink(file); unlink(socket_path); rmdir(directory);
    return 0;
}

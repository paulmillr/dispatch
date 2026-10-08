// Inert Codex-shaped parent for real Rust hook socket tests. All child input is
// fixed synthetic data. No model, shell or user's conversation is involved.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    // Model the legacy native RPC contract: initialization works, but hook
    // trust is unavailable. Current Codex trust has its own native tests.
    if (argc == 3 && !strcmp(argv[1], "app-server") && !strcmp(argv[2], "--stdio")) {
        char line[16384];
        while (fgets(line, sizeof(line), stdin)) {
            char *id = strstr(line, "\"id\":");
            if (!id) continue;
            printf("{\"id\":%lu,%s}\n", strtoul(id + 5, NULL, 10),
                   strstr(line, "\"initialize\"") ? "\"result\":{}" :
                   "\"error\":{\"code\":-32601,\"message\":\"Method not found\"}");
            fflush(stdout);
        }
        return 0;
    }
    if (argc != 3 || strcmp(argv[1], "--hook-router-fixture")) return 2;
    printf("AGENT=%ld\n", (long)getpid()); fflush(stdout);
    char command;
    while (read(STDIN_FILENO, &command, 1) == 1) {
        if (!strchr("PSCQWKAB", command)) continue;
        int input[2], output[2];
        if (pipe(input) || pipe(output)) return 1;
        pid_t child = fork();
        if (child < 0) return 1;
        if (!child) {
            close(input[1]); close(output[0]);
            if (dup2(input[0], STDIN_FILENO) < 0 || dup2(output[1], STDOUT_FILENO) < 0) _exit(1);
            close(input[0]); close(output[1]);
            execl(argv[2], argv[2], "hook", (char *)NULL);
            _exit(1);
        }
        close(input[0]); close(output[1]);
        const char *body = command == 'C'
            ? "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"11111111-1111-4111-8111-111111111111\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo fixture\"}}"
            : command == 'A'
            ? "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"11111111-1111-4111-8111-111111111111\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Which example?\",\"header\":\"Example\",\"options\":[{\"label\":\"Swift\"},{\"label\":\"Rust\"}],\"multiSelect\":false}]}}"
            : command == 'B'
            ? "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"11111111-1111-4111-8111-111111111111\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo fixture\"}}"
            : command == 'Q'
            ? "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"33333333-3333-4333-8333-333333333333\",\"tool_name\":\"Bash\",\"tool_input\":{}}"
            : command == 'W'
            ? "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"11111111-1111-4111-8111-111111111111\",\"agent_id\":\"subagent\",\"tool_name\":\"Bash\",\"tool_input\":{}}"
            : command == 'K'
            ? "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"11111111-1111-4111-8111-111111111111\",\"tool_name\":\"\",\"tool_input\":{}}"
            : command == 'P'
            ? "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"synthetic\",\"tool_name\":\"shell\",\"tool_input\":{\"command\":\"echo fixture\"}}"
            : "{\"hook_event_name\":\"Stop\",\"session_id\":\"synthetic\"}";
        if (write(input[1], body, strlen(body)) != (ssize_t)strlen(body)) return 1;
        close(input[1]);
        printf("HOOK=%ld\n", (long)child); fflush(stdout);
        unsigned char bytes[250000]; size_t count = 0;
        while (count < sizeof(bytes)) {
            ssize_t n = read(output[0], bytes + count, sizeof(bytes) - count);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            count += (size_t)n;
        }
        close(output[0]);
        int status;
        while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return 1;
        printf("RESULT=");
        for (size_t i = 0; i < count; i++) printf("%02x", bytes[i]);
        puts(""); fflush(stdout);
    }
    return 0;
}

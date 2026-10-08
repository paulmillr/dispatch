/* Inert native Codex identity for the private side-process transport tests. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--side-fixture")) {
        puts("ready"); fflush(stdout);
        char byte;
        while (read(0, &byte, 1) > 0) {}
        return 0;
    }
    if (argc < 3 || strcmp(argv[1], "app-server") || strcmp(argv[2], "--stdio")) return 2;
    int readonly = 0;
    for (int i = 3; i < argc; i += 2) {
        if (i + 1 >= argc || strcmp(argv[i], "--disable")) return 3;
        if (!strcmp(argv[i + 1], "shell_tool")) readonly = 1;
    }
    char cwd[4096];
    if (!getcwd(cwd, sizeof(cwd))) return 4;
    printf("{\"pid\":%d,\"cwd\":\"%s\",\"home\":\"%s\",\"readonly\":%s}\n",
           getpid(), cwd, getenv("CODEX_HOME"), readonly ? "true" : "false");
    fflush(stdout);
    char bytes[16384];
    ssize_t count;
    while ((count = read(0, bytes, sizeof(bytes))) > 0) {
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(1, bytes + offset, (size_t)(count - offset));
            if (written <= 0) return 5;
            offset += written;
        }
    }
    return 0;
}

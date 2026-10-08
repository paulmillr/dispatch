/* A real foreground executable that exits at the paste/Return boundary. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) {
        puts("codex-cli 99.0.0-test");
        return 0;
    }
    const char *path = getenv("DISPATCH_SUBMISSION_CAPTURE");
    if (!path) return 2;
    int capture = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (capture < 0) return 3;
    struct termios settings;
    if (tcgetattr(0, &settings)) return 4;
    cfmakeraw(&settings);
    if (tcsetattr(0, TCSANOW, &settings)) return 5;
    const char ready[] = "\033[?2004hDISPATCH_EXIT_FIXTURE_READY\r\n";
    if (write(1, ready, sizeof(ready) - 1) < 0) return 6;
    char tail[6] = {0}, byte;
    while (read(0, &byte, 1) == 1) {
        if (write(capture, &byte, 1) != 1) return 7;
        memmove(tail, tail + 1, sizeof(tail) - 1);
        tail[sizeof(tail) - 1] = byte;
        if (!memcmp(tail, "\033[201~", sizeof(tail))) {
            close(capture);
            return 0;
        }
    }
    return 8;
}

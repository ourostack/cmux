#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* Synthetic native parent only; never installed in agent or wrapper resolution. */
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("2.1.295 (Claude Code)");
        return 0;
    }
    if (argc != 3) return 64;
    char *command = NULL, *payload = NULL;
    size_t command_size = 0, payload_size = 0;
    while (getline(&command, &command_size, stdin) >= 0) {
        if (getline(&payload, &payload_size, stdin) < 0) return 65;
        command[strcspn(command, "\n")] = 0;
        char *child_args[24] = {argv[1], "--socket", argv[2], "hooks", "claude"};
        size_t count = 5;
        char *cursor = command, *part;
        while ((part = strsep(&cursor, "\t")) != NULL) {
            if (count >= 23 || *part == 0) return 65;
            child_args[count++] = part;
        }
        int input[2];
        if (pipe(input) != 0) return 71;
        fflush(stdout);
        pid_t child = fork();
        if (child < 0) return 71;
        if (child == 0) {
            close(input[1]);
            if (dup2(input[0], STDIN_FILENO) < 0) _exit(71);
            close(input[0]);
            execv(child_args[0], child_args);
            _exit(71);
        }
        close(input[0]);
        size_t offset = 0, length = strlen(payload);
        while (offset < length) {
            ssize_t written = write(input[1], payload + offset, length - offset);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) return 74;
            offset += (size_t)written;
        }
        close(input[1]);
        int status;
        while (waitpid(child, &status, 0) < 0) {
            if (errno != EINTR) return 71;
        }
        printf("\n__SHEPHERD_STATUS__%d\n", WIFEXITED(status) ? WEXITSTATUS(status) : 128);
        fflush(stdout);
    }
    free(command);
    free(payload);
    return 0;
}

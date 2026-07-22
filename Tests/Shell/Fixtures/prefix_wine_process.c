#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 4 || chdir(argv[1]) != 0) return 2;
    if (strcmp(argv[3], "ignore-term") == 0) signal(SIGTERM, SIG_IGN);

    FILE *ready_file = fopen(argv[2], "w");
    if (ready_file == NULL) return 3;
    fprintf(ready_file, "%d\n", getpid());
    fclose(ready_file);

    for (;;) pause();
}

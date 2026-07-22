#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/param.h>
#include <unistd.h>

static volatile sig_atomic_t should_exit = 0;

static void handle_signal(int signal_number) {
    (void)signal_number;
    should_exit = 1;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;

    char lock_path[MAXPATHLEN];
    int path_length = snprintf(
        lock_path,
        sizeof(lock_path),
        "%s/.switchyard-prefix.lock",
        argv[1]
    );
    if (path_length < 0 || path_length >= (int)sizeof(lock_path)) {
        return 3;
    }
    int descriptor = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0 || flock(descriptor, LOCK_EX) != 0) return 4;

    signal(SIGTERM, handle_signal);
    FILE *ready_file = fopen(argv[2], "w");
    if (ready_file == NULL) return 5;
    fprintf(ready_file, "%d\n", getpid());
    fclose(ready_file);

    while (!should_exit) pause();
    flock(descriptor, LOCK_UN);
    close(descriptor);
    return 0;
}

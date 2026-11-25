#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

static int limit(int resource, rlim_t value) {
    struct rlimit current;
    if (getrlimit(resource, &current)) return -1;
    if (value > current.rlim_max) value = current.rlim_max;
    struct rlimit bounded = {value, value};
    return setrlimit(resource, &bounded);
}

int main(int argc, char **argv) {
    if (argc != 4 || chdir(argv[2])) return 126;
    if (!strcmp(argv[3], "--isolated")) {
        pid_t (*responsible)(pid_t) =
            (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        if (!responsible || responsible(getpid()) != getpid()) return 126;
    } else if (strcmp(argv[3], "--development")) {
        return 126;
    }
    if (!strcmp(argv[1], "--probe")) {
        char byte;
        return read(STDIN_FILENO, &byte, 1) < 0;
    }
    if (limit(RLIMIT_CPU, 10) || limit(RLIMIT_FSIZE, 64 * 1024 * 1024) || limit(RLIMIT_CORE, 0)) {
        return 126;
    }
    char *helper[] = {argv[1], NULL};
    execv(helper[0], helper);
    perror("Extension launch");
    return 126;
}

#include "PathemExtensionRuntime.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef int (*disclaim_fn)(posix_spawnattr_t *, int);
typedef pid_t (*responsible_fn)(pid_t);

static long long milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int spawn_helper(pid_t *pid, const char *launcher, const char *argument,
    const char *directory, int input, int output, int error, disclaim_fn disclaim) {
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t files;
    if (posix_spawnattr_init(&attr)) return -1;
    if (posix_spawn_file_actions_init(&files)) {
        posix_spawnattr_destroy(&attr);
        return -1;
    }
    char home[4096 + 5];
    int length = snprintf(home, sizeof(home), "HOME=%s", directory);
    char *env[] = {"PATH=/usr/bin:/bin", home, "LANG=C", NULL};
    char *args[] = {(char *)launcher, (char *)argument, (char *)directory,
        disclaim ? "--isolated" : "--development", NULL};
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    int failure = length < 0 || (size_t)length >= sizeof(home)
        || posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        || posix_spawnattr_setsigmask(&attr, &empty)
        || posix_spawnattr_setsigdefault(&attr, &defaults)
        || posix_spawnattr_setpgroup(&attr, 0)
        || posix_spawn_file_actions_adddup2(&files, input, STDIN_FILENO)
        || posix_spawn_file_actions_adddup2(&files, output, STDOUT_FILENO)
        || posix_spawn_file_actions_adddup2(&files, error, STDERR_FILENO);
    if (!failure) {
        if (disclaim) failure = disclaim(&attr, 1);
        if (!failure) failure = posix_spawn(pid, launcher, &files, &attr, args, env);
    }
    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attr);
    return failure ? -1 : 0;
}

static int open_pipe(int handles[2]) {
    if (pipe(handles)) return -1;
    if (fcntl(handles[0], F_SETFD, FD_CLOEXEC) < 0
        || fcntl(handles[1], F_SETFD, FD_CLOEXEC) < 0) {
        close(handles[0]);
        close(handles[1]);
        handles[0] = handles[1] = -1;
        return -1;
    }
    return 0;
}

static void terminate_group(pid_t pid, int *status) {
    // Keep the child unreaped until the group has been signaled, so the ID cannot be reused.
    killpg(pid, SIGKILL);
    while (waitpid(pid, status, 0) < 0 && errno == EINTR) {}
}

int pe_isolation_probe(const char *launcher, const char *directory, int omit_symbols) {
    disclaim_fn disclaim = omit_symbols ? NULL :
        (disclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    responsible_fn responsible = omit_symbols ? NULL :
        (responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (!disclaim || !responsible) return 0;
    int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    int lifetime[2];
    if (null_fd < 0) return 0;
    if (open_pipe(lifetime)) { close(null_fd); return 0; }
    pid_t pid;
    int spawned = spawn_helper(&pid, launcher, "--probe", directory,
        lifetime[0], null_fd, null_fd, disclaim);
    int result = 0;
    if (spawned == 0) {
        result = responsible(pid) == pid;
        int status;
        terminate_group(pid, &status);
    }
    close(lifetime[0]);
    close(lifetime[1]);
    close(null_fd);
    return result;
}

pe_result pe_run(const char *launcher, const char *executable, const char *directory,
    const uint8_t *input, size_t input_length, uint8_t *output, size_t output_capacity,
    uint8_t *errors, size_t error_capacity, int timeout_ms, int isolated) {
    pe_result result = {pe_io_failed, -1, 0, 0};
    disclaim_fn disclaim = isolated ?
        (disclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim") : NULL;
    if (isolated && !disclaim) {
        result.result = pe_isolation_failed;
        return result;
    }
    FILE *request = tmpfile();
    int out[2] = {-1, -1}, err[2] = {-1, -1};
    pid_t pid;
    if (!request || fcntl(fileno(request), F_SETFD, FD_CLOEXEC) < 0
        || fwrite(input, 1, input_length, request) != input_length
        || fflush(request) || fseek(request, 0, SEEK_SET)
        || open_pipe(out) || open_pipe(err)) goto cleanup;
    if (spawn_helper(&pid, launcher, executable, directory, fileno(request), out[1], err[1], disclaim)) {
        result.result = pe_spawn_failed;
        goto cleanup;
    }
    close(out[1]); out[1] = -1;
    close(err[1]); err[1] = -1;
    struct pollfd streams[] = {{out[0], POLLIN, 0}, {err[0], POLLIN, 0}};
    uint8_t *buffers[] = {output, errors};
    size_t limits[] = {output_capacity, error_capacity};
    size_t *lengths[] = {&result.output_length, &result.error_length};
    long long end = milliseconds() + timeout_ms;
    for (;;) {
        long long remaining = end - milliseconds();
        if (remaining <= 0) { result.result = pe_timeout; break; }
        if (streams[0].fd < 0 && streams[1].fd < 0) {
            siginfo_t state = {0};
            if (waitid(P_PID, (id_t)pid, &state, WEXITED | WNOHANG | WNOWAIT) < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (state.si_pid == pid) {
                result.result = pe_ok;
                result.status = state.si_code == CLD_EXITED ? state.si_status : -state.si_status;
                break;
            }
        }
        int ready = poll(streams, 2, remaining > 20 ? 20 : (int)remaining);
        if (ready < 0 && errno != EINTR) break;
        if (ready <= 0) continue;
        for (int i = 0; i < 2; i++) {
            if (!streams[i].revents) continue;
            uint8_t chunk[8192];
            ssize_t count = read(streams[i].fd, chunk, sizeof(chunk));
            if (count < 0) {
                if (errno == EINTR || errno == EAGAIN) continue;
                goto reap;
            }
            if (count == 0) { streams[i].fd = -1; continue; }
            if ((size_t)count > limits[i] - *lengths[i]) {
                result.result = pe_output_limit;
                goto reap;
            }
            memcpy(buffers[i] + *lengths[i], chunk, (size_t)count);
            *lengths[i] += (size_t)count;
        }
    }
reap:;
    int status;
    terminate_group(pid, &status);
cleanup:
    if (request) fclose(request);
    for (int i = 0; i < 2; i++) {
        if (out[i] >= 0) close(out[i]);
        if (err[i] >= 0) close(err[i]);
    }
    return result;
}

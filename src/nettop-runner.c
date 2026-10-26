// Unprivileged nettop supervisor. No timers or polling during normal operation.
#include <sys/event.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void interrupted(int signal_number) { (void)signal_number; }

static int watch(int queue, uintptr_t id, short filter, unsigned int flags) {
    struct kevent event;
    EV_SET(&event, id, filter, EV_ADD | EV_ENABLE, flags, 0, NULL);
    return kevent(queue, &event, 1, NULL, 0, NULL);
}

static double monotonic_time(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static int reap(pid_t child, int options) {
    int status = 0;
    pid_t result;
    do { result = waitpid(child, &status, options); } while (result < 0 && errno == EINTR);
    return result == child || (result < 0 && errno == ECHILD);
}

static void stop_child(int queue, pid_t child) {
    if (reap(child, WNOHANG)) return;
    kill(child, SIGTERM);
    double deadline = monotonic_time() + 1.0;
    while (!reap(child, WNOHANG)) {
        double remaining = deadline - monotonic_time();
        if (remaining <= 0) break;
        struct timespec timeout = { (time_t)remaining, (long)((remaining - (time_t)remaining) * 1e9) };
        struct kevent event;
        int result = kevent(queue, NULL, 0, &event, 1, &timeout);
        if (result == 0 || (result < 0 && errno != EINTR)) break;
    }
    if (!reap(child, WNOHANG)) { kill(child, SIGKILL); reap(child, 0); }
}

int main(void) {
    pid_t parent = getppid();
    if (parent <= 1) return EXIT_FAILURE;
    int queue = kqueue();
    if (queue < 0) return EXIT_FAILURE;
    if (fcntl(queue, F_SETFD, FD_CLOEXEC) < 0 ||
        watch(queue, (uintptr_t)parent, EVFILT_PROC, NOTE_EXIT) < 0 || getppid() != parent) {
        close(queue); return EXIT_FAILURE;
    }

    // Block signals until their filters are installed. A handler preserves
    // pending termination signals, unlike SIG_IGN during startup.
    sigset_t blocked, empty;
    sigemptyset(&blocked); sigemptyset(&empty);
    const int signals[] = { SIGTERM, SIGINT, SIGHUP };
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) sigaddset(&blocked, signals[i]);
    if (sigprocmask(SIG_BLOCK, &blocked, NULL) < 0) { close(queue); return EXIT_FAILURE; }
    struct sigaction action = {0};
    action.sa_handler = interrupted; sigemptyset(&action.sa_mask);
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        if (sigaction(signals[i], &action, NULL) < 0 || watch(queue, signals[i], EVFILT_SIGNAL, 0) < 0) {
            close(queue); return EXIT_FAILURE;
        }
    }

    // /dev/null gives nettop persistent EOF events and can burn an entire core.
    // Only this supervisor holds the write end; nettop receives the read end.
    int input[2];
    if (pipe(input) < 0) { close(queue); return EXIT_FAILURE; }
    posix_spawn_file_actions_t files;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&files) != 0) { close(input[0]); close(input[1]); close(queue); return EXIT_FAILURE; }
    if (posix_spawnattr_init(&attributes) != 0) {
        posix_spawn_file_actions_destroy(&files); close(input[0]); close(input[1]); close(queue); return EXIT_FAILURE;
    }
    int error = posix_spawn_file_actions_adddup2(&files, input[0], STDIN_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&files, input[0]);
    if (!error) error = posix_spawn_file_actions_addclose(&files, input[1]);
    if (!error) error = posix_spawnattr_setsigdefault(&attributes, &blocked);
    if (!error) error = posix_spawnattr_setsigmask(&attributes, &empty);
    if (!error) error = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    char *args[] = { "/usr/bin/nettop", "-n", "-P", "-x", "-l", "0", "-s", "3", "-J", "bytes_in,bytes_out", NULL };
    pid_t child = -1;
    if (!error) error = posix_spawn(&child, args[0], &files, &attributes, args, environ);
    posix_spawn_file_actions_destroy(&files); posix_spawnattr_destroy(&attributes);
    close(input[0]);
    if (error) { close(input[1]); close(queue); return EXIT_FAILURE; }

    if (watch(queue, (uintptr_t)child, EVFILT_PROC, NOTE_EXIT) < 0) {
        stop_child(queue, child); close(input[1]); close(queue); return EXIT_FAILURE;
    }
    fprintf(stderr, "nettop pid=%d\n", child);
    if (sigprocmask(SIG_SETMASK, &empty, NULL) == 0) {
        for (;;) {
            struct kevent event;
            int count = kevent(queue, NULL, 0, &event, 1, NULL);
            if (count < 0 && errno == EINTR) continue;
            // All registered events mean shutdown: parent/child exit or signal.
            break;
        }
    }
    stop_child(queue, child);
    close(input[1]); close(queue);
    return EXIT_SUCCESS;
}

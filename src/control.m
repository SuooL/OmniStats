// Serialized by ControlChannel. Bounded nonblocking I/O keeps a dead helper
// from stalling the UI or accumulating a queue of obsolete fan commands.
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <fcntl.h>
#import <poll.h>
#import <errno.h>
#import <time.h>
#import "control.h"

#ifndef OMNISTATS_SOCKET_PATH
#define OMNISTATS_SOCKET_PATH "/var/run/omnistats.sock"
#endif
static int gFd = -1;
static int gVersion = -1;
static uint64_t gConnection = 0;
uint64_t cb_ctl_connection_id(void) { return gConnection; }

static double monotonic(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
void cb_ctl_disconnect(void) {
    if(gFd >= 0) close(gFd);
    gFd = -1; gVersion = -1;
}
static int ready(int fd, short events, double deadline) {
    for(;;) {
        int remaining = (int)((deadline - monotonic()) * 1000);
        if(remaining <= 0) return 0;
        struct pollfd p = {fd, events, 0};
        int result = poll(&p, 1, remaining);
        if(result < 0 && errno == EINTR) continue;
        return result > 0 && (p.revents & events) && !(p.revents & (POLLERR | POLLNVAL));
    }
}
static int openConn(double deadline) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if(fd < 0) return -1;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    strncpy(address.sun_path, OMNISTATS_SOCKET_PATH, sizeof(address.sun_path) - 1);
    if(connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if(errno != EINPROGRESS || !ready(fd, POLLOUT, deadline)) { close(fd); return -1; }
        int error = 0; socklen_t length = sizeof(error);
        if(getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) || error) { close(fd); return -1; }
    }
    gConnection++;
    return fd;
}
static int request(const char *command, char *reply, size_t capacity) {
    // One total deadline, including reconnects and fragmented replies.
    double deadline = monotonic() + 0.75;
    for(int attempt = 0; attempt < 2; attempt++) {
        if(gFd < 0) { gFd = openConn(deadline); if(gFd < 0) return -1; }
        size_t sent = 0, total = strlen(command), used = 0;
        while(sent < total && ready(gFd, POLLOUT, deadline)) {
            ssize_t count = send(gFd, command + sent, total - sent, 0);
            if(count > 0) sent += (size_t)count;
            else if(count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            else break;
        }
        if(sent == total) {
            while(used + 1 < capacity && ready(gFd, POLLIN, deadline)) {
                ssize_t count = recv(gFd, reply + used, capacity - used - 1, 0);
                if(count > 0) {
                    used += (size_t)count; reply[used] = 0;
                    char *newline = strchr(reply, '\n');
                    if(newline) { *newline = 0; return 0; }
                } else if(count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                else break;
            }
        }
        cb_ctl_disconnect();
    }
    return -1;
}
static int ok(const char *command) {
    char reply[64];
    return request(command, reply, sizeof(reply)) == 0 && strcmp(reply, "OK") == 0 ? 0 : -1;
}
int cb_ctl_available(void) { return ok("PING\n") == 0; }
int cb_ctl_version(void) {
    if(gVersion >= 0) return gVersion;
    char reply[64]; int version = 0;
    if(request("VERSION\n", reply, sizeof(reply)) != 0) return 0;
    if(sscanf(reply, "OK %d", &version) != 1) version = 0;
    gVersion = version;
    return version;
}
int cb_ctl_set(int fan, int rpm) {
    char command[64], reply[64];
    snprintf(command, sizeof(command), "SET %d %d\n", fan, rpm);
    if(request(command, reply, sizeof(reply)) != 0) return -1;
    int applied = -1;
    return sscanf(reply, "OK %d", &applied) == 1 ? applied : -1;
}
int cb_ctl_auto(int fan) {
    char command[64]; snprintf(command, sizeof(command), "AUTO %d\n", fan);
    return ok(command);
}
int cb_ctl_auto_all(void) { return ok("AUTOALL\n"); }
int cb_ctl_heartbeat(void) { return ok("HB\n"); }
int cb_ctl_command(const char *command, char *reply, int capacity) {
    char line[256];
    if(!command || !reply || capacity < 2 || strchr(command, '\n')) return -1;
    if(snprintf(line, sizeof(line), "%s\n", command) >= (int)sizeof(line)) return -1;
    return request(line, reply, (size_t)capacity);
}

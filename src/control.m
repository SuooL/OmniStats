// OmniStats control client. Holds ONE persistent connection to omnistats-smcd:
// the helper reverts fans to auto when the connection drops (GUI gone), so the
// client must keep the socket open for the lifetime of manual control and send
// periodic heartbeats. Reconnects transparently if the link breaks.
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import "control.h"

#define SOCK_PATH "/var/run/omnistats.sock"

static int gFd = -1;

static int openConn(void){
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if(fd < 0) return -1;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path)-1);
    struct timeval tv = {2,0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if(connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0){ close(fd); return -1; }
    return fd;
}
static void dropConn(void){ if(gFd>=0){ close(gFd); gFd=-1; } }

// Send one command over the persistent connection and read its one-line reply.
// Reconnects once on failure. Returns 0 on success.
static int request(const char *cmd, char *buf, size_t buflen){
    for(int attempt=0; attempt<2; attempt++){
        if(gFd < 0){ gFd = openConn(); if(gFd < 0) return -1; }
        if(write(gFd, cmd, strlen(cmd)) < 0){ dropConn(); continue; }
        if(buf && buflen){
            ssize_t k = recv(gFd, buf, buflen-1, 0);
            if(k > 0){ buf[k]=0; return 0; }
            dropConn(); continue;            // timeout / closed -> retry once
        }
        return 0;
    }
    return -1;
}

int cb_ctl_available(void){
    char buf[64];
    if(request("PING\n", buf, sizeof(buf)) != 0) return 0;
    return strncmp(buf, "OK", 2) == 0;
}
int cb_ctl_set(int fan, int rpm){
    char cmd[64], buf[64];
    snprintf(cmd, sizeof(cmd), "SET %d %d\n", fan, rpm);
    if(request(cmd, buf, sizeof(buf)) != 0) return -1;
    int applied = -1;
    if(sscanf(buf, "OK %d", &applied) == 1) return applied;
    return -1;
}
int cb_ctl_auto(int fan){
    char cmd[64], buf[64];
    snprintf(cmd, sizeof(cmd), "AUTO %d\n", fan);
    if(request(cmd, buf, sizeof(buf)) != 0) return -1;
    return strncmp(buf, "OK", 2)==0 ? 0 : -1;
}
int cb_ctl_auto_all(void){
    char buf[64];
    if(request("AUTOALL\n", buf, sizeof(buf)) != 0) return -1;
    return strncmp(buf, "OK", 2)==0 ? 0 : -1;
}
void cb_ctl_heartbeat(void){
    char buf[64];
    request("HB\n", buf, sizeof(buf));
}

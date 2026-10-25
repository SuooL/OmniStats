// Privileged fan-control helper, protocol 2. Only SET/HB renew the manual-mode
// watchdog; PING, VERSION and malformed traffic cannot keep stale control alive.
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <signal.h>
#import <time.h>
#import <poll.h>
#import <errno.h>
#import "smc.h"

#define SOCK_PATH "/var/run/omnistats.sock"
#define WATCHDOG_SEC 12
#define MAX_FANS 8
static int gFanCount = 0;
static int gManual[MAX_FANS] = {0};
static volatile sig_atomic_t gStop = 0;

static double nowSeconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int autoFan(int fan) {
    char key[8]; smcFanModeKey(key, fan);
    int result = smcWriteU8(key, 0);
    // Keep retrying if firmware did not acknowledge the automatic-mode write.
    gManual[fan] = result != 0;
    return result == 0 ? 0 : -1;
}
static int autoAll(void) {
    int result = 0;
    for(int i = 0; i < gFanCount; i++) if(autoFan(i)) result = -1;
    return result;
}
static int anyManual(void) {
    for(int i = 0; i < gFanCount; i++) if(gManual[i]) return 1;
    return 0;
}
static int setFan(int fan, float rpm) {
    if(fan < 0 || fan >= gFanCount || !isfinite(rpm)) return -1;
    char minimumKey[8], maximumKey[8], modeKey[8], targetKey[8];
    smcFanKey(minimumKey, fan, "Mn"); smcFanKey(maximumKey, fan, "Mx");
    smcFanModeKey(modeKey, fan); smcFanKey(targetKey, fan, "Tg");
    float minimum = smcReadFloat(minimumKey), maximum = smcReadFloat(maximumKey);
    if(!isfinite(minimum) || !isfinite(maximum) || minimum < 0 || maximum <= minimum || (double)maximum >= (double)INT_MAX) return -1;
    rpm = fminf(maximum, fmaxf(minimum, rpm));
    if(smcWriteU8(modeKey, 1)) return -2;
    gManual[fan] = 1;
    if(smcWriteFloat(targetKey, rpm)) { autoFan(fan); return -3; }
    return (int)rpm;
}
static int peerAllowed(int fd) {
    uid_t uid; gid_t gid; struct stat console;
    if(getpeereid(fd, &uid, &gid)) return 0;
    return uid == 0 || (stat("/dev/console", &console) == 0 && uid == console.st_uid);
}
static void onSignal(int signal) { (void)signal; gStop = 1; }
static int sendReply(int fd, const char *reply) {
    size_t sent = 0, size = strlen(reply);
    while(sent < size) {
        ssize_t count = send(fd, reply + sent, size - sent, 0);
        if(count > 0) sent += (size_t)count;
        else if(count < 0 && errno == EINTR && !gStop) continue;
        else return -1;
    }
    return 0;
}
// Return 1 only for valid manual-control heartbeats, 0 for other replies,
// and -1 when the peer stopped reading. Parsing requires the full command.
static int handleLine(int fd, const char *line) {
    char reply[1024], extra;
    int fan = -1, heartbeat = 0;
    float rpm;
    if(strcmp(line, "PING") == 0) strcpy(reply, "OK\n");
    else if(strcmp(line, "VERSION") == 0) strcpy(reply, "OK 2\n");
    else if(strcmp(line, "HB") == 0) { strcpy(reply, "OK\n"); heartbeat = 1; }
    else if(strcmp(line, "AUTOALL") == 0) strcpy(reply, autoAll() == 0 ? "OK\n" : "ERR auto\n");
    else if(sscanf(line, "AUTO %d %c", &fan, &extra) == 1 && strncmp(line, "AUTO ", 5) == 0) {
        strcpy(reply, fan >= 0 && fan < gFanCount && autoFan(fan) == 0 ? "OK\n" : "ERR fan\n");
    } else if(sscanf(line, "SET %d %f %c", &fan, &rpm, &extra) == 2 && strncmp(line, "SET ", 4) == 0) {
        int applied = setFan(fan, rpm);
        if(applied < 0) snprintf(reply, sizeof(reply), "ERR %d\n", applied);
        else { snprintf(reply, sizeof(reply), "OK %d\n", applied); heartbeat = 1; }
    } else if(strcmp(line, "INFO") == 0) {
        size_t used = 0;
        for(int i = 0; i < gFanCount; i++) {
            char actual[8], minimum[8], maximum[8], target[8], mode[8];
            smcFanKey(actual,i,"Ac"); smcFanKey(minimum,i,"Mn"); smcFanKey(maximum,i,"Mx");
            smcFanKey(target,i,"Tg"); smcFanModeKey(mode,i);
            int count = snprintf(reply + used, sizeof(reply) - used,
                "fan%d %.0f %.0f %.0f %.0f %d\n", i, smcReadFloat(minimum), smcReadFloat(maximum),
                smcReadFloat(actual), smcReadFloat(target), smcReadU8(mode));
            if(count < 0 || (size_t)count >= sizeof(reply) - used - 5) break;
            used += (size_t)count;
        }
        snprintf(reply + used, sizeof(reply) - used, "END\n");
    } else strcpy(reply, "ERR command\n");
    return sendReply(fd, reply) == 0 ? heartbeat : -1;
}

int main(void) {
    if(geteuid() != 0) { fprintf(stderr, "omnistats-smcd must run as root\n"); return 1; }
    if(smcOpen() != 0) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }
    int count = smcReadU8("FNum"); gFanCount = count > 0 && count <= MAX_FANS ? count : 0;
    struct sigaction action = {0}; action.sa_handler = onSignal; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
    signal(SIGPIPE, SIG_IGN);
    autoAll();
    unlink(SOCK_PATH);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    strncpy(address.sun_path, SOCK_PATH, sizeof(address.sun_path) - 1);
    if(server < 0 || bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 4)) {
        perror("control socket"); if(server >= 0) close(server); return 1;
    }
    chmod(SOCK_PATH, 0666); // Every command additionally checks the console user's uid.
    fprintf(stderr, "omnistats-smcd protocol 2: %d fans\n", gFanCount);
    while(!gStop) {
        struct pollfd listening = {server, POLLIN, 0};
        int result = poll(&listening, 1, anyManual() ? 2000 : -1);
        if(result <= 0) { if(anyManual()) autoAll(); continue; }
        int client = accept(server, NULL, NULL);
        if(client < 0) continue;
        if(!peerAllowed(client)) { close(client); continue; }
        struct timeval timeout = {0, 750000};
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        double lastHeartbeat = nowSeconds();
        char buffer[1024]; size_t used = 0;
        int connected = 1;
        while(!gStop && connected) {
            if(anyManual() && nowSeconds() - lastHeartbeat > WATCHDOG_SEC) autoAll();
            struct pollfd incoming = {client, POLLIN, 0};
            int ready = poll(&incoming, 1, anyManual() ? 1000 : -1);
            if(ready < 0 && errno != EINTR) break;
            if(ready <= 0) continue;
            if(!(incoming.revents & POLLIN)) break;
            ssize_t got = recv(client, buffer + used, sizeof(buffer) - used - 1, 0);
            if(got <= 0 || !peerAllowed(client)) break;
            used += (size_t)got; buffer[used] = 0;
            char *newline;
            while((newline = strchr(buffer, '\n'))) {
                *newline = 0;
                int heartbeat = handleLine(client, buffer);
                if(heartbeat < 0) { connected = 0; break; }
                if(heartbeat) lastHeartbeat = nowSeconds();
                if(anyManual() && nowSeconds() - lastHeartbeat > WATCHDOG_SEC) autoAll();
                size_t consumed = (size_t)(newline - buffer) + 1;
                memmove(buffer, newline + 1, used - consumed + 1); used -= consumed;
            }
            if(used == sizeof(buffer) - 1) break; // Reject oversized partial commands.
        }
        close(client); autoAll();
    }
    autoAll(); close(server); unlink(SOCK_PATH);
    return 0;
}

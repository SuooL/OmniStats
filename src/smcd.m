// Privileged fan and battery helper, protocol 8. Only SET/HB renew the manual-mode
// watchdog; PING, VERSION, battery commands and malformed traffic cannot keep
// stale fan control alive. A certificate-signed helper only serves the app
// signed by that same certificate.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#import <libproc.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <time.h>
#import <poll.h>
#import <errno.h>
#import "smc.h"

#define SOCK_PATH "/var/run/omnistats.sock"
#define CLIENT_IDENTIFIER "io.github.suool.omnistats"
#define WATCHDOG_SEC 12
#define MAX_FANS 8
static int gFanCount = 0;
static int gManual[MAX_FANS] = {0};
static volatile sig_atomic_t gStop = 0;
static int gSignedHelper = 0;
static SecRequirementRef gClientRequirement = NULL;
// Fan commands run on the main thread and battery control on its own queue; one
// lock keeps their SMC calls (and smc.h's key cache) from interleaving.
static pthread_mutex_t gSMCLock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static void smcLock(void) { pthread_mutex_lock(&gSMCLock); }
static void smcUnlock(void) { pthread_mutex_unlock(&gSMCLock); }

static double nowSeconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int autoFan(int fan) {
    char key[8];
    smcLock(); smcFanModeKey(key, fan); int result = smcWriteU8(key, 0); smcUnlock();
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
static int setFanLocked(int fan, float rpm) {
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
static int setFan(int fan, float rpm) {
    smcLock(); int result = setFanLocked(fan, rpm); smcUnlock();
    return result;
}
static int peerAllowed(int fd) {
    uid_t uid; gid_t gid; struct stat console;
    if(getpeereid(fd, &uid, &gid)) return 0;
    return uid == 0 || (stat("/dev/console", &console) == 0 && uid == console.st_uid);
}
// The app's identifier, signed by this helper's certificate. The hash is the
// certificate's SHA-1, the same form codesign writes into designated requirements.
static int formatClientRequirement(char *out, size_t size, const unsigned char digest[CC_SHA1_DIGEST_LENGTH]) {
    char hex[CC_SHA1_DIGEST_LENGTH * 2 + 1];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    int count = snprintf(out, size, "identifier \"%s\" and certificate leaf = H\"%s\"", CLIENT_IDENTIFIER, hex);
    return count > 0 && (size_t)count < size;
}
// Release builds sign the app and helper with one fixed certificate. Ad-hoc
// development builds have no certificate and keep only the console-user check.
// A signed helper whose requirement cannot be built rejects every non-root peer.
static SecRequirementRef copyClientRequirement(void) {
    SecCodeRef selfCode = NULL; SecStaticCodeRef staticCode = NULL;
    CFDictionaryRef info = NULL; SecRequirementRef requirement = NULL;
    gSignedHelper = 0;
    if(SecCodeCopySelf(kSecCSDefaultFlags, &selfCode) == errSecSuccess &&
       SecCodeCopyStaticCode(selfCode, kSecCSDefaultFlags, &staticCode) == errSecSuccess &&
       SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info) == errSecSuccess) {
        CFArrayRef certificates = (CFArrayRef)CFDictionaryGetValue(info, kSecCodeInfoCertificates);
        if(certificates && CFArrayGetCount(certificates) > 0) {
            gSignedHelper = 1;
            CFDataRef leaf = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(certificates, 0));
            unsigned char digest[CC_SHA1_DIGEST_LENGTH]; char text[256];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if(leaf) CC_SHA1(CFDataGetBytePtr(leaf), (CC_LONG)CFDataGetLength(leaf), digest);
#pragma clang diagnostic pop
            if(leaf && formatClientRequirement(text, sizeof(text), digest)) {
                CFStringRef string = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
                if(string) { SecRequirementCreateWithString(string, kSecCSDefaultFlags, &requirement); CFRelease(string); }
            }
            if(leaf) CFRelease(leaf);
        }
    }
    if(info) CFRelease(info);
    if(staticCode) CFRelease(staticCode);
    if(selfCode) CFRelease(selfCode);
    return requirement;
}
// Checks the connected process through its audit token (a pid can be recycled).
static int peerSigned(int fd) {
    uid_t uid; gid_t gid;
    if(!gSignedHelper) return 1;
    if(getpeereid(fd, &uid, &gid)) return 0;
    if(uid == 0) return 1;
    if(!gClientRequirement) return 0;
    audit_token_t token; socklen_t size = sizeof(token);
    if(getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token)) return 0;
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    if(!data) return 0;
    const void *keys[] = {kSecGuestAttributeAudit}, *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus status = attributes ? SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) : errSecParam;
    if(status == errSecSuccess) status = SecCodeCheckValidity(code, kSecCSDefaultFlags, gClientRequirement);
    if(code) CFRelease(code);
    if(attributes) CFRelease(attributes);
    CFRelease(data);
    return status == errSecSuccess;
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
// ---- Battery charge control ----------------------------------------------
// The policy runs here rather than in the app, so it keeps working after the app
// quits and around sleep. Doubt resolves towards charging: an unreadable battery,
// another charge manager or helper exit all allow charging again.
typedef enum { BatteryBackendNone = 0, BatteryBackendCHTE, BatteryBackendCH0BC } BatteryBackend;
// ledMode: 0 leaves the MagSafe LED to macOS, 1 shows charging (orange) or not
// (green), 2 turns it off. heatLimit is in °C.
// autoDischarge runs a plugged-in Mac from its battery down to the limit.
typedef struct { int enabled, limit, sailing, sleepStop, stayAwake, heatProtect, heatLimit, ledMode, autoDischarge; } BatteryConfig;
// temperature is in 0.01 °C, 0 when unknown. plugged is the physical adapter
// (SMC AC-W), which stays true while we cut the adapter; external is what macOS
// reports and reads false then.
typedef struct { int valid, percent, external, charging, temperature, plugged; } BatteryReading;

static const BatteryConfig kBatteryDefaults = {0, 80, 5, 0, 0, 0, 40, 0, 0};
static BatteryConfig gBattery = {0, 80, 5, 0, 0, 0, 40, 0, 0};

// Adapter cut-off (CHIE = 08 runs the Mac from its battery while plugged in).
// It is the one fail-dangerous control here: a forgotten cut drains a plugged-in
// Mac, so every exit path restores it.
#define DISCHARGE_FLOOR 10          // never discharge below this percentage
#define DISCHARGE_MAX_SEC (8 * 3600)
#define CAL_LOW 15
#define CAL_HOLD_SEC 3600
#define CAL_CHARGE_MAX_SEC (6 * 3600)
#define CAL_DISCHARGE_MAX_SEC (24 * 3600)  // 100 % -> 15 % takes most of a day at light load
enum { CalIdle = 0, CalCharge1, CalHold1, CalDischarge, CalCharge2, CalHold2, CalToLimit };
static int gAdapterSupported = 0;
static int gAdapterCut = 0;         // what we wrote to CHIE
static int gDischargeTarget = 0;    // manual session target, 0 = none
static double gDischargeDeadline = 0;
static int gCalPhase = CalIdle;
static double gCalPhaseStart = 0;   // wall clock, survives sleep and restarts
static int gCalResult = 0;          // 0 none, 1 finished, 2 stopped early
static BatteryBackend gBackend = BatteryBackendNone;
static int gInhibited = 0;      // what the SMC holds: read at start, then our own writes
static int gTopUp = 0;          // charge past the limit until the adapter is removed
static int gWriteFailed = 0;
static int gHeatHeld = 0;       // heat protection is holding charging off
static int gLedSupported = 0;   // the Mac has a MagSafe LED key
static int gLedOwned = 0;       // we changed the LED and must hand it back
static int gLedValue = -1;      // what we last wrote; -1 forces the next write
static int gBatteryStopping = 0;  // set once on exit: nothing may pause charging after the release
static int gLowPowerOverridden = 0; // we switched Low Power Mode off and owe it back (persisted)
static int gLowPowerChecked = 0;    // looked at the energy mode during this discharge
static BatteryReading gLastReading = {0, 0, 0, 0, 0, 0};
static char gConflict[32] = "";
static const char *gBatteryConfigPath = "/Library/Application Support/OmniStats/battery.plist";
static dispatch_queue_t gBatteryQueue = NULL;
static dispatch_source_t gBatteryTimer = NULL;
static io_connect_t gRootPort = 0;

// Stop at the limit; resume only once the charge falls to limit - sailing.
static int batteryShouldInhibit(BatteryConfig config, BatteryReading reading, int topUp, int inhibited) {
    if(!config.enabled || topUp || config.limit >= 100 || !reading.valid) return 0;
    if(reading.percent >= config.limit) return 1;
    if(reading.percent <= config.limit - config.sailing) return 0;
    return inhibited;
}
// Heat protection pauses charging at heatLimit and resumes 3 °C below it. It
// applies during Top Up too: a hot battery comes first. Unknown temperature
// never holds charging off.
static int batteryHeatHold(BatteryConfig config, BatteryReading reading, int held) {
    if(!config.enabled || !config.heatProtect || !reading.valid || reading.temperature <= 0) return 0;
    if(reading.temperature >= config.heatLimit * 100) return 1;
    if(reading.temperature <= (config.heatLimit - 3) * 100) return 0;
    return held;
}
// MagSafe LED (ACLC): 00 hands it back to macOS, 01 off, 03 green, 04 orange.
static int batteryLedTarget(BatteryConfig config, BatteryReading reading) {
    if(config.ledMode == 1) return reading.charging ? 0x04 : 0x03;
    if(config.ledMode == 2) return 0x01;
    return 0x00;
}
static int batteryConfigValid(BatteryConfig c) {
    return (c.enabled == 0 || c.enabled == 1) && (c.sleepStop == 0 || c.sleepStop == 1)
        && (c.stayAwake == 0 || c.stayAwake == 1) && c.limit >= 20 && c.limit <= 100
        && c.sailing >= 1 && c.sailing <= 20 && (c.heatProtect == 0 || c.heatProtect == 1)
        && c.heatLimit >= 30 && c.heatLimit <= 50 && c.ledMode >= 0 && c.ledMode <= 2
        && (c.autoDischarge == 0 || c.autoDischarge == 1);
}
static int calibrationCharging(int phase) {
    return phase == CalCharge1 || phase == CalHold1 || phase == CalCharge2 || phase == CalHold2;
}
static int calibrationDischarging(int phase) { return phase == CalDischarge || phase == CalToLimit; }
// Full for calibration: 100 %, or 99 % once the charger has finished (macOS can
// sit at 99 % through a long top-off). A heat pause is not a finished charge.
static int calibrationFull(BatteryReading r, int heatHeld) {
    return r.percent >= 100 || (r.percent >= 99 && r.external && !r.charging && !heatHeld);
}
// Calibration: full -> hold 1 h -> 15 % -> full -> hold 1 h -> back to the limit.
// Returns the next phase, or -1 to stop early (unplugged, or a phase overran).
// The holds keep charging allowed, so a battery that is still topping off finishes there.
static int calibrationNext(int phase, BatteryReading r, double elapsed, BatteryConfig c, int heatHeld) {
    if(phase == CalIdle || !r.valid) return phase;
    if(!r.plugged) return -1;
    switch(phase) {
    case CalCharge1: case CalCharge2:
        if(calibrationFull(r, heatHeld)) return phase + 1;
        if(elapsed > CAL_CHARGE_MAX_SEC) return r.percent >= 99 ? phase + 1 : -1;
        return phase;
    case CalHold1: return elapsed >= CAL_HOLD_SEC ? CalDischarge : phase;
    case CalHold2: return elapsed >= CAL_HOLD_SEC ? (c.enabled && c.limit < 100 ? CalToLimit : CalIdle) : phase;
    case CalDischarge:
        if(r.percent <= CAL_LOW) return CalCharge2;
        return elapsed > CAL_DISCHARGE_MAX_SEC ? -1 : phase;
    case CalToLimit: return r.percent <= c.limit || elapsed > DISCHARGE_MAX_SEC ? CalIdle : phase;
    }
    return CalIdle;
}
// The discharge target in effect, 0 for none. Calibration's charging phases never cut.
static int batteryDischargeTarget(BatteryConfig c, BatteryReading r, int manualTarget, int calPhase) {
    if(calPhase == CalDischarge) return CAL_LOW;
    if(calPhase == CalToLimit) return c.limit;
    if(calPhase != CalIdle) return 0;
    if(manualTarget) return manualTarget;
    if(c.enabled && c.autoDischarge && c.limit < 100 && r.valid && r.percent > c.limit) return c.limit;
    return 0;
}
// Cut only while the adapter is physically plugged in and the battery is above target.
static int batteryWantsCut(BatteryReading r, int target) {
    return r.valid && r.plugged && target >= DISCHARGE_FLOOR && r.percent > target;
}
// "key=value ..." with every key optional; the update applies only if all of it is valid.
static int parseBatterySet(const char *arguments, BatteryConfig *config) {
    BatteryConfig c = *config;
    char buffer[256];
    if(strlcpy(buffer, arguments, sizeof(buffer)) >= sizeof(buffer)) return -1;
    int count = 0;
    char *save = NULL;
    for(char *token = strtok_r(buffer, " ", &save); token; token = strtok_r(NULL, " ", &save)) {
        char *equals = strchr(token, '=');
        if(!equals) return -1;
        *equals = 0;
        char *end = NULL;
        long value = strtol(equals + 1, &end, 10);
        if(end == equals + 1 || *end || value < 0 || value > 100) return -1;
        if(!strcmp(token, "enabled")) c.enabled = (int)value;
        else if(!strcmp(token, "limit")) c.limit = (int)value;
        else if(!strcmp(token, "sailing")) c.sailing = (int)value;
        else if(!strcmp(token, "sleepstop")) c.sleepStop = (int)value;
        else if(!strcmp(token, "stayawake")) c.stayAwake = (int)value;
        else if(!strcmp(token, "heat")) c.heatProtect = (int)value;
        else if(!strcmp(token, "heatlimit")) c.heatLimit = (int)value;
        else if(!strcmp(token, "led")) c.ledMode = (int)value;
        else if(!strcmp(token, "autodischarge")) c.autoDischarge = (int)value;
        else return -1;
        count++;
    }
    if(!count || !batteryConfigValid(c)) return -1;
    *config = c;
    return 0;
}

// CHTE (current firmware) holds 01000000 to stop charging; older firmware uses
// CH0B/CH0C = 02. Callers hold the SMC lock.
static int readInhibit(BatteryBackend backend) {
    unsigned char bytes[32]; unsigned int size = 0, type = 0;
    if(backend == BatteryBackendCHTE) return smcReadBytes("CHTE", bytes, &size, &type) == 4 ? bytes[0] != 0 : -1;
    if(backend == BatteryBackendCH0BC) return smcReadBytes("CH0C", bytes, &size, &type) == 1 ? bytes[0] != 0 : -1;
    return -1;
}
static int writeInhibit(BatteryBackend backend, int inhibit) {
    if(backend == BatteryBackendCHTE) {
        unsigned char bytes[4] = {inhibit ? 1 : 0, 0, 0, 0};
        return smcWriteBytes("CHTE", bytes, 4);
    }
    if(backend == BatteryBackendCH0BC) {
        unsigned char value = inhibit ? 2 : 0;
        return smcWriteBytes("CH0B", &value, 1) == 0 && smcWriteBytes("CH0C", &value, 1) == 0 ? 0 : -1;
    }
    return -1;
}
// Writing each key's current value back proves this firmware accepts our writes
// without changing anything. Newer firmware rejects them as not privileged.
static BatteryBackend probeBatteryBackend(void) {
    unsigned char b[32], c[32]; unsigned int size = 0, type = 0;
    if(smcReadBytes("CHTE", b, &size, &type) == 4 && smcWriteBytes("CHTE", b, 4) == 0) return BatteryBackendCHTE;
    if(smcReadBytes("CH0B", b, &size, &type) == 1 && smcReadBytes("CH0C", c, &size, &type) == 1
       && smcWriteBytes("CH0B", b, 1) == 0 && smcWriteBytes("CH0C", c, 1) == 0) return BatteryBackendCH0BC;
    return BatteryBackendNone;
}

// CHIE plus AC-W (to tell a real unplug from our own cut). A cut left over from
// a crash is restored here, unless another charge manager may own it. Callers
// hold the SMC lock.
static int probeAdapter(int mayRestore) {
    unsigned char chie[32], acw[32]; unsigned int size = 0, type = 0;
    if(smcReadBytes("CHIE", chie, &size, &type) != 1 || smcReadBytes("AC-W", acw, &size, &type) != 1) return 0;
    if(chie[0] != 0 && !mayRestore) return 0;
    unsigned char connected = 0x00;
    return smcWriteBytes("CHIE", &connected, 1) == 0;
}

static int readBatteryRegistry(BatteryReading *out) {
    *out = (BatteryReading){0, 0, 0, 0, 0, 0};
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if(!service) return -1;
    CFTypeRef current = IORegistryEntryCreateCFProperty(service, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0);
    CFTypeRef maximum = IORegistryEntryCreateCFProperty(service, CFSTR("MaxCapacity"), kCFAllocatorDefault, 0);
    CFTypeRef external = IORegistryEntryCreateCFProperty(service, CFSTR("ExternalConnected"), kCFAllocatorDefault, 0);
    CFTypeRef charging = IORegistryEntryCreateCFProperty(service, CFSTR("IsCharging"), kCFAllocatorDefault, 0);
    CFTypeRef temperature = IORegistryEntryCreateCFProperty(service, CFSTR("Temperature"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    int value = 0, full = 0, centiDegrees = 0;
    if(current && CFGetTypeID(current) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)current, kCFNumberIntType, &value)
       && maximum && CFGetTypeID(maximum) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)maximum, kCFNumberIntType, &full)
       && external && CFGetTypeID(external) == CFBooleanGetTypeID() && full > 0 && value >= 0) {
        out->valid = 1;
        out->percent = value * 100 / full > 100 ? 100 : value * 100 / full;
        out->external = CFBooleanGetValue((CFBooleanRef)external);
        out->charging = charging && CFGetTypeID(charging) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)charging);
        if(temperature && CFGetTypeID(temperature) == CFNumberGetTypeID()
           && CFNumberGetValue((CFNumberRef)temperature, kCFNumberIntType, &centiDegrees)
           && centiDegrees > -2000 && centiDegrees < 10000) out->temperature = centiDegrees;
    }
    if(current) CFRelease(current);
    if(maximum) CFRelease(maximum);
    if(external) CFRelease(external);
    if(charging) CFRelease(charging);
    if(temperature) CFRelease(temperature);
    return out->valid ? 0 : -1;
}
// Another charge manager writes the same keys; stand back while one runs.
static int findBatteryConflict(char *name, size_t size) {
    static const char *prefixes[][2] = {{"com.apphousekitchen.aldente", "AlDente"}, {"me.mhaeuser.batteryd", "Battery-Toolkit"}};
    int capacity = proc_listallpids(NULL, 0);
    if(capacity <= 0) return 0;
    capacity += 32;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if(!pids) return 0;
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    int found = 0;
    for(int i = 0; i < count && !found; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if(pids[i] <= 0 || proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if(!strcmp(base, "batt")) { strlcpy(name, "batt", size); found = 1; }
        for(size_t k = 0; k < sizeof(prefixes) / sizeof(prefixes[0]) && !found; k++)
            if(!strncmp(base, prefixes[k][0], strlen(prefixes[k][0]))) { strlcpy(name, prefixes[k][1], size); found = 1; }
    }
    free(pids);
    return found;
}
// SMC AC-W > 0 while an adapter is physically connected, even with CHIE cutting
// it; -1 when the key is missing. Callers hold the SMC lock.
static int readPluggedSMC(void) {
    unsigned char bytes[32]; unsigned int size = 0, type = 0;
    return smcReadBytes("AC-W", bytes, &size, &type) == 1 ? (signed char)bytes[0] > 0 : -1;
}
// Runs /usr/bin/pmset within 5 s: the battery queue also restores the adapter, so
// it never waits on a stuck child. Returns pmset's exit status, or -1.
static int runPmset(const char *const arguments[], char *output, size_t size) {
    int pipeFds[2];
    if(output && size) output[0] = 0;
    if(pipe(pipeFds)) return -1;
    // Only stdin/stdout/stderr reach pmset, never the control socket.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, "/usr/bin/pmset", &actions, &attributes, (char *const *)arguments, environment) == 0;
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(pipeFds[1]);
    double deadline = nowSeconds() + 5;
    size_t used = 0;
    while(spawned && nowSeconds() < deadline) {
        struct pollfd readable = {pipeFds[0], POLLIN, 0};
        int ready = poll(&readable, 1, (int)((deadline - nowSeconds()) * 1000) + 1);
        if(ready < 0 && errno == EINTR) continue;
        if(ready <= 0) break;
        char chunk[512];
        ssize_t got = read(pipeFds[0], chunk, sizeof(chunk));
        if(got < 0 && errno == EINTR) continue;
        if(got <= 0) break;
        size_t take = output && used + 1 < size ? MIN((size_t)got, size - 1 - used) : 0;
        if(take) { memcpy(output + used, chunk, take); used += take; }
    }
    close(pipeFds[0]);
    if(output && size) output[used] = 0;
    if(!spawned) return -1;
    int status = 0; pid_t done;
    while((done = waitpid(pid, &status, WNOHANG)) == 0 || (done < 0 && errno == EINTR)) {
        if(nowSeconds() > deadline) { kill(pid, SIGKILL); waitpid(pid, &status, 0); return -1; }
        usleep(10000);
    }
    return done == pid && WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}
// The battery profile's energy mode in `pmset -g custom`: 0 Automatic, 1 Low Power,
// 2 High Power, -1 unknown. Macs with High Power Mode list "powermode", others
// "lowpowermode" (0 or 1).
static int parseBatteryPowerMode(const char *text) {
    int battery = 0;
    for(const char *line = text; *line; ) {
        const char *end = strchr(line, '\n');
        if(*line != ' ') battery = !strncmp(line, "Battery Power:", 14);
        else if(battery) {
            char key[32]; int value;
            if(sscanf(line, " %31s %d", key, &value) == 2 && value >= 0 && value <= 2
               && (!strcmp(key, "powermode") || (!strcmp(key, "lowpowermode") && value <= 1))) return value;
        }
        if(!end) break;
        line = end + 1;
    }
    return -1;
}
static int readBatteryPowerMode(void) {
    char text[4096];
    const char *arguments[] = {"pmset", "-g", "custom", NULL};
    return runPmset(arguments, text, sizeof(text)) == 0 ? parseBatteryPowerMode(text) : -1;
}
static int writeBatteryLowPower(int on) {
    const char *arguments[] = {"pmset", "-b", "lowpowermode", on ? "1" : "0", NULL};
    return runPmset(arguments, NULL, 0) == 0 ? 0 : -1;
}
static int (*gReadBattery)(BatteryReading *) = readBatteryRegistry;
static int (*gReadPlugged)(void) = readPluggedSMC;
static int (*gFindConflict)(char *, size_t) = findBatteryConflict;
static int (*gReadPowerMode)(void) = readBatteryPowerMode;
static int (*gWriteLowPower)(int) = writeBatteryLowPower;

static int readConfigValue(NSDictionary *dictionary, NSString *key, int fallback) {
    id value = dictionary[key];
    return [value isKindOfClass:NSNumber.class] ? [value intValue] : fallback;
}
static void loadBatteryConfig(void) {
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:@(gBatteryConfigPath)];
    BatteryConfig c = kBatteryDefaults;
    if([saved isKindOfClass:NSDictionary.class]) {
        c.enabled = readConfigValue(saved, @"enabled", c.enabled);
        c.limit = readConfigValue(saved, @"limit", c.limit);
        c.sailing = readConfigValue(saved, @"sailing", c.sailing);
        c.sleepStop = readConfigValue(saved, @"sleepStop", c.sleepStop);
        c.stayAwake = readConfigValue(saved, @"stayAwake", c.stayAwake);
        c.heatProtect = readConfigValue(saved, @"heatProtect", c.heatProtect);
        c.heatLimit = readConfigValue(saved, @"heatLimit", c.heatLimit);
        c.ledMode = readConfigValue(saved, @"ledMode", c.ledMode);
        c.autoDischarge = readConfigValue(saved, @"autoDischarge", c.autoDischarge);
        int phase = readConfigValue(saved, @"calibrationPhase", CalIdle);
        id started = saved[@"calibrationStarted"];
        if(phase > CalIdle && phase <= CalToLimit && [started isKindOfClass:NSNumber.class]) {
            gCalPhase = phase; gCalPhaseStart = [started doubleValue];
        }
        gLowPowerOverridden = readConfigValue(saved, @"lowPowerRestore", 0) == 1;
    }
    gBattery = batteryConfigValid(c) ? c : kBatteryDefaults;
}
static int saveBatteryConfig(BatteryConfig c) {
    NSString *path = @(gBatteryConfigPath);
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755} error:nil];
    NSDictionary *values = @{@"enabled": @(c.enabled), @"limit": @(c.limit), @"sailing": @(c.sailing),
                             @"sleepStop": @(c.sleepStop), @"stayAwake": @(c.stayAwake),
                             @"heatProtect": @(c.heatProtect), @"heatLimit": @(c.heatLimit), @"ledMode": @(c.ledMode),
                             @"autoDischarge": @(c.autoDischarge), @"calibrationPhase": @(gCalPhase),
                             @"calibrationStarted": @(gCalPhaseStart), @"lowPowerRestore": @(gLowPowerOverridden)};
    return [values writeToURL:[NSURL fileURLWithPath:path] error:nil] ? 0 : -1;
}

static void batteryObserve(void) {
    char conflict[32] = "";
    gFindConflict(conflict, sizeof(conflict));
    strlcpy(gConflict, conflict, sizeof(gConflict));
    gReadBattery(&gLastReading);
    smcLock(); int plugged = gReadPlugged(); smcUnlock();
    gLastReading.plugged = plugged < 0 ? gLastReading.external : plugged;
    if(gLastReading.valid && !gLastReading.plugged) gTopUp = 0;
}
static double wallClock(void) { return (double)time(NULL); }
static int writeAdapter(int cut) {
    unsigned char value = cut ? 0x08 : 0x00;
    smcLock(); int failed = smcWriteBytes("CHIE", &value, 1) != 0; smcUnlock();
    if(!failed) gAdapterCut = cut;
    return failed ? -1 : 0;
}
static void restoreAdapter(void) {
    if(gAdapterCut) writeAdapter(0);
}
// Unplugged, the LED is dark: forget what we wrote so plugging in rewrites it.
// Mode 0 hands a changed LED back to macOS once and then leaves it alone.
static void batteryApplyLed(void) {
    if(!gLedSupported) return;
    if(gBattery.ledMode == 0) {
        if(!gLedOwned) return;
        unsigned char system = 0x00;
        smcLock(); int failed = smcWriteBytes("ACLC", &system, 1) != 0; smcUnlock();
        if(!failed) { gLedOwned = 0; gLedValue = -1; }
        return;
    }
    if(!gLastReading.valid || !gLastReading.external) { gLedValue = -1; return; }
    int target = batteryLedTarget(gBattery, gLastReading);
    if(target == gLedValue) return;
    unsigned char value = (unsigned char)target;
    smcLock(); int failed = smcWriteBytes("ACLC", &value, 1) != 0; smcUnlock();
    if(!failed) { gLedValue = target; gLedOwned = 1; }
}
// Something to enforce or to hand back; otherwise ticks cost nothing.
static int batteryActive(void) {
    return gBattery.enabled || gInhibited || gBattery.ledMode != 0 || gLedOwned
        || gAdapterCut || gDischargeTarget || gCalPhase != CalIdle || gLowPowerOverridden;
}
static void setCalibrationPhase(int phase, int result) {
    gCalPhase = phase; gCalPhaseStart = wallClock();
    if(result) gCalResult = result;
    saveBatteryConfig(gBattery);
}
// Low Power Mode would slow calibration's discharge, so those steps run in
// Automatic. With the adapter paused macOS uses the battery profile, the only one
// touched. It is checked once per discharge, so turning it back on meanwhile
// sticks, and given back afterwards, on exit and after a crash (persisted), unless
// a mode was picked in between. A failed restore is retried on the next tick.
static void batteryApplyEnergyMode(int discharging) {
    if(discharging) {
        if(gLowPowerChecked) return;
        gLowPowerChecked = 1;
        if(!gLowPowerOverridden && gReadPowerMode() == 1 && gWriteLowPower(0) == 0) {
            gLowPowerOverridden = 1; saveBatteryConfig(gBattery);
        }
        return;
    }
    gLowPowerChecked = 0;
    if(!gLowPowerOverridden) return;
    int mode = gReadPowerMode();
    if(mode < 0 || (mode == 0 && gWriteLowPower(1) != 0)) return;
    gLowPowerOverridden = 0; saveBatteryConfig(gBattery);
}
// Runs on the battery queue: every 10 s, on wake and after each command. A
// feature the user never turned on leaves the keys alone, unless a change in
// place is ours to undo.
static void batteryTick(void) {
    if(gBatteryStopping || !batteryActive()) return;
    batteryObserve();
    // Another charge manager may want the adapter: never leave it cut for them.
    if(gConflict[0]) { restoreAdapter(); batteryApplyEnergyMode(0); return; }
    double now = wallClock();
    if(gCalPhase != CalIdle) {
        int next = calibrationNext(gCalPhase, gLastReading, now - gCalPhaseStart, gBattery, gHeatHeld);
        if(next != gCalPhase) setCalibrationPhase(next < 0 ? CalIdle : next, next < 0 ? 2 : next == CalIdle ? 1 : 0);
    }
    if(gDischargeTarget && gLastReading.valid
       && (gLastReading.percent <= gDischargeTarget || !gLastReading.plugged || now > gDischargeDeadline)) gDischargeTarget = 0;
    int cut = gAdapterSupported
        && batteryWantsCut(gLastReading, batteryDischargeTarget(gBattery, gLastReading, gDischargeTarget, gCalPhase));
    gHeatHeld = batteryHeatHold(gBattery, gLastReading, gHeatHeld);
    int want = batteryShouldInhibit(gBattery, gLastReading, gTopUp || calibrationCharging(gCalPhase), gInhibited) || gHeatHeld;
    if(gBackend != BatteryBackendNone && want != gInhibited) {
        smcLock(); gWriteFailed = writeInhibit(gBackend, want) != 0; smcUnlock();
        if(!gWriteFailed) gInhibited = want;
    }
    if(cut != gAdapterCut && writeAdapter(cut) != 0) gWriteFailed = 1;
    batteryApplyEnergyMode(calibrationDischarging(gCalPhase));
    batteryApplyLed();
}
// Idle sleep waits while charging up to the limit, so it stops exactly there.
static int batteryKeepsAwake(void) {
    // Discharging and calibration only progress while awake.
    if(!gConflict[0] && (gAdapterCut || gDischargeTarget || gCalPhase != CalIdle)) return 1;
    return gBattery.enabled && gBattery.stayAwake && gBackend != BatteryBackendNone && !gConflict[0]
        && !gTopUp && !gInhibited && gLastReading.valid && gLastReading.external
        && gLastReading.percent < gBattery.limit;
}
// Asleep, nothing can stop charging at the limit, so optionally pause it first.
static void batteryWillSleep(void) {
    restoreAdapter();   // asleep, nothing would stop the drain
    if(gBatteryStopping || !gBattery.enabled || !gBattery.sleepStop || gTopUp || gBattery.limit >= 100
       || gBackend == BatteryBackendNone || gConflict[0] || gInhibited) return;
    smcLock(); if(writeInhibit(gBackend, 1) == 0) gInhibited = 1; smcUnlock();
}
// Exit (uninstall, shutdown) never leaves charging switched off. Ticks already
// queued behind this see gBatteryStopping and do nothing.
static void batteryRelease(void) {
    gBatteryStopping = 1;
    if(gBatteryTimer) dispatch_source_cancel(gBatteryTimer);
    restoreAdapter();   // our own cut is always undone, conflict or not
    batteryApplyEnergyMode(0);  // a restart mid-discharge switches it off again
    if(gConflict[0]) return;
    smcLock();
    if(gInhibited && gBackend != BatteryBackendNone && writeInhibit(gBackend, 0) == 0) gInhibited = 0;
    unsigned char system = 0x00;
    if(gLedOwned && smcWriteBytes("ACLC", &system, 1) == 0) gLedOwned = 0;
    smcUnlock();
}
static void formatBatteryStatus(char *out, size_t size) {
    static const char *backends[] = {"none", "chte", "ch0bc"};
    snprintf(out, size, "OK backend=%s enabled=%d limit=%d sailing=%d sleepstop=%d stayawake=%d "
             "heat=%d heatlimit=%d led=%d topup=%d inhibited=%d heatheld=%d percent=%d external=%d "
             "charging=%d temp=%d ledsupported=%d adapter=%d cut=%d plugged=%d discharge=%d "
             "autodischarge=%d calibration=%d calelapsed=%d calresult=%d conflict=%s writefailed=%d\n",
             backends[gBackend], gBattery.enabled, gBattery.limit, gBattery.sailing, gBattery.sleepStop,
             gBattery.stayAwake, gBattery.heatProtect, gBattery.heatLimit, gBattery.ledMode, gTopUp,
             gInhibited, gHeatHeld, gLastReading.valid ? gLastReading.percent : -1, gLastReading.external,
             gLastReading.charging, gLastReading.temperature, gLedSupported, gAdapterSupported, gAdapterCut,
             gLastReading.plugged, gDischargeTarget, gBattery.autoDischarge, gCalPhase,
             gCalPhase != CalIdle ? (int)(wallClock() - gCalPhaseStart) : 0, gCalResult,
             gConflict[0] ? gConflict : "-", gWriteFailed);
}
static void onBattery(void (^block)(void)) {
    if(gBatteryQueue) dispatch_sync(gBatteryQueue, block); else block();
}

static void powerCallback(void *context, io_service_t service, natural_t type, void *argument) {
    (void)context; (void)service;
    if(type == kIOMessageCanSystemSleep) {
        if(batteryKeepsAwake()) IOCancelPowerChange(gRootPort, (long)argument);
        else IOAllowPowerChange(gRootPort, (long)argument);
    } else if(type == kIOMessageSystemWillSleep) {
        batteryWillSleep();
        IOAllowPowerChange(gRootPort, (long)argument);
    } else if(type == kIOMessageSystemHasPoweredOn) {
        batteryTick();
    }
}
static void startBatteryControl(void) {
    gBatteryQueue = dispatch_queue_create("com.omnistats.battery", DISPATCH_QUEUE_SERIAL);
    dispatch_sync(gBatteryQueue, ^{
        loadBatteryConfig();
        gFindConflict(gConflict, sizeof(gConflict));
        unsigned char led[32]; unsigned int size = 0, type = 0;
        smcLock();
        gBackend = probeBatteryBackend();
        int current = readInhibit(gBackend);
        gLedSupported = smcReadBytes("ACLC", led, &size, &type) == 1;
        gAdapterSupported = probeAdapter(!gConflict[0]);
        smcUnlock();
        gInhibited = current == 1;
        batteryTick();
    });
    IONotificationPortRef port = NULL;
    io_object_t notifier = 0;
    gRootPort = IORegisterForSystemPower(NULL, &port, powerCallback, &notifier);
    if(gRootPort) IONotificationPortSetDispatchQueue(port, gBatteryQueue);
    gBatteryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gBatteryQueue);
    dispatch_source_set_timer(gBatteryTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                              10 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(gBatteryTimer, ^{ batteryTick(); });
    dispatch_resume(gBatteryTimer);
}

// Return 1 only for valid manual-control heartbeats, 0 for other replies,
// and -1 when the peer stopped reading. Parsing requires the full command.
static int handleLine(int fd, const char *line) {
    char reply[1024], extra;
    int fan = -1, heartbeat = 0;
    float rpm;
    if(strcmp(line, "PING") == 0) strcpy(reply, "OK\n");
    else if(strcmp(line, "VERSION") == 0) strcpy(reply, "OK 8\n");
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
        smcLock();
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
        smcUnlock();
        snprintf(reply + used, sizeof(reply) - used, "END\n");
    } else if(strcmp(line, "BSTATUS") == 0) {
        char *out = reply;
        onBattery(^{
            if(!batteryActive()) batteryObserve();  // idle ticks skip it
            formatBatteryStatus(out, sizeof(reply));
        });
    } else if(strncmp(line, "BSET ", 5) == 0) {
        __block int result = -1;
        onBattery(^{
            BatteryConfig update = gBattery;
            if(parseBatterySet(line + 5, &update) != 0) return;
            if(saveBatteryConfig(update) != 0) { result = -2; return; }
            gBattery = update; result = 0;
            batteryTick();
        });
        strcpy(reply, result == 0 ? "OK\n" : result == -2 ? "ERR save\n" : "ERR args\n");
    } else if(strcmp(line, "BTOPUP 1") == 0 || strcmp(line, "BTOPUP 0") == 0) {
        int enable = line[7] == '1';
        onBattery(^{ gTopUp = enable; if(enable) gDischargeTarget = 0; batteryTick(); });
        strcpy(reply, "OK\n");
    } else if(sscanf(line, "BDISCHARGE %d %c", &fan, &extra) == 1 && strncmp(line, "BDISCHARGE ", 11) == 0) {
        int target = fan;
        __block const char *result = "OK\n";
        onBattery(^{
            if(target == 0) { gDischargeTarget = 0; batteryTick(); return; }
            if(target < DISCHARGE_FLOOR || target > 95) { result = "ERR args\n"; return; }
            if(!gAdapterSupported) { result = "ERR unsupported\n"; return; }
            gTopUp = 0; gDischargeTarget = target; gDischargeDeadline = wallClock() + DISCHARGE_MAX_SEC;
            batteryTick();
        });
        strcpy(reply, result);
    } else if(strcmp(line, "BCALIBRATE 1") == 0 || strcmp(line, "BCALIBRATE 0") == 0) {
        int start = line[11] == '1';
        __block const char *result = "OK\n";
        onBattery(^{
            if(!start) { if(gCalPhase != CalIdle) setCalibrationPhase(CalIdle, 2); batteryTick(); return; }
            if(!gAdapterSupported) { result = "ERR unsupported\n"; return; }
            batteryObserve();
            if(!gLastReading.valid || !gLastReading.plugged) { result = "ERR unplugged\n"; return; }
            gTopUp = 0; gDischargeTarget = 0; gCalResult = 0;
            setCalibrationPhase(CalCharge1, 0);
            batteryTick();
        });
        strcpy(reply, result);
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
    gClientRequirement = copyClientRequirement();
    startBatteryControl();
    static const char *backends[] = {"none", "chte", "ch0bc"};
    fprintf(stderr, "omnistats-smcd protocol 8: %d fans, battery backend %s, %s clients\n", gFanCount,
        backends[gBackend], !gSignedHelper ? "console-user" : gClientRequirement ? "signed" : "no (requirement unavailable)");
    while(!gStop) {
        struct pollfd listening = {server, POLLIN, 0};
        int result = poll(&listening, 1, anyManual() ? 2000 : -1);
        if(result <= 0) { if(anyManual()) autoAll(); continue; }
        int client = accept(server, NULL, NULL);
        if(client < 0) continue;
        if(!peerAllowed(client) || !peerSigned(client)) { close(client); continue; }
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
    autoAll(); onBattery(^{ batteryRelease(); });
    close(server); unlink(SOCK_PATH);
    return 0;
}

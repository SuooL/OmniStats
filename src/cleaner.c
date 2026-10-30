// omnistats-cleaner: moves an uninstalled app's system-level leftovers into the
// user's Trash. It runs once per uninstall through an administrator prompt and
// never as a daemon. It reads a manifest of absolute paths (one per line), runs
// no shell, and only accepts direct children of a fixed set of directories:
// anything else, any symlink and any ".." is refused.
//
// usage: omnistats-cleaner <manifest> <uid> <folder name>
// output: "moved\t<path>\t<destination>" or "skipped\t<path>\t<reason>" per line
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

// Tests point this at a scratch directory; in production it is empty.
static const char *gRoot = "";
static const char *kAllowed[] = {
    "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools",
    "/Library/Application Support", "/Library/Caches", "/Library/Logs", "/Library/Preferences",
    "/private/var/db/receipts", NULL,
};

static int endsWith(const char *text, const char *suffix) {
    size_t length = strlen(text), tail = strlen(suffix);
    return length >= tail && strcmp(text + length - tail, suffix) == 0;
}

// 0 if `path` may be moved; otherwise a static reason. `allowedIndex` reports
// which directory it belongs to.
static const char *validatePath(const char *path, int *allowedIndex) {
    if(path[0] != '/') return "not absolute";
    if(strstr(path, "/../") || strstr(path, "/./") || endsWith(path, "/..") || endsWith(path, "/.")) return "relative component";
    for(int i = 0; kAllowed[i]; i++) {
        char directory[PATH_MAX];
        if(snprintf(directory, sizeof(directory), "%s%s/", gRoot, kAllowed[i]) >= (int)sizeof(directory)) return "too long";
        size_t length = strlen(directory);
        if(strncmp(path, directory, length) != 0) continue;
        const char *name = path + length;
        if(!*name || strchr(name, '/')) return "not a direct child of an allowed folder";
        if((i == 0 || i == 1) && !endsWith(name, ".plist")) return "not a launchd plist";
        if(i == 7 && !endsWith(name, ".bom") && !endsWith(name, ".plist")) return "not a package receipt";
        struct stat info;
        if(lstat(path, &info) != 0) return "missing";
        if(S_ISLNK(info.st_mode)) return "symbolic link";
        char resolved[PATH_MAX];
        if(!realpath(path, resolved) || strcmp(resolved, path) != 0) return "path is not canonical";
        if(allowedIndex) *allowedIndex = i;
        return NULL;
    }
    return "outside the allowed folders";
}

static int run(char *const argv[]) {
    pid_t pid;
    if(posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) != 0) return -1;
    int status = 0;
    while(waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int validFolderName(const char *name) {
    if(!*name || strlen(name) > 120) return 0;
    for(const char *c = name; *c; c++)
        if(!(( *c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || strchr(" -_.", *c))) return 0;
    return strcmp(name, ".") && strcmp(name, "..");
}

// Moves one validated item to <trash>/<allowed folder name>/<name>; returns 0 on success.
static int moveItem(const char *path, int allowedIndex, const char *trash, uid_t uid, gid_t gid,
                    char *destination, size_t size) {
    const char *folder = strrchr(kAllowed[allowedIndex], '/') + 1;
    char directory[PATH_MAX];
    snprintf(directory, sizeof(directory), "%s/%s", trash, folder);
    mkdir(trash, 0755); chown(trash, uid, gid);
    mkdir(directory, 0755); chown(directory, uid, gid);
    snprintf(destination, size, "%s/%s", directory, strrchr(path, '/') + 1);
    if(access(destination, F_OK) == 0) return EEXIST;
    if(rename(path, destination) != 0) return errno;
    char owner[32]; snprintf(owner, sizeof(owner), "%u:%u", uid, gid);
    char *chownArgs[] = {"/usr/sbin/chown", "-R", owner, destination, NULL};
    run(chownArgs);
    return 0;
}

static int cleanerMain(int argc, char **argv) {
    if(argc != 4) { fprintf(stderr, "usage: omnistats-cleaner <manifest> <uid> <folder name>\n"); return 2; }
    char *end = NULL;
    long uidValue = strtol(argv[2], &end, 10);
    struct passwd *user = (*end || uidValue <= 0) ? NULL : getpwuid((uid_t)uidValue);
    if(!user || !validFolderName(argv[3])) { fprintf(stderr, "invalid user or folder name\n"); return 2; }
    char trash[PATH_MAX];
    snprintf(trash, sizeof(trash), "%s%s/.Trash/%s", gRoot, user->pw_dir, argv[3]);
    FILE *manifest = fopen(argv[1], "r");
    if(!manifest) { perror("manifest"); return 2; }
    char line[PATH_MAX + 2];
    int failures = 0;
    while(fgets(line, sizeof(line), manifest)) {
        line[strcspn(line, "\n")] = 0;
        if(!*line) continue;
        int allowed = -1;
        const char *reason = validatePath(line, &allowed);
        if(reason) { printf("skipped\t%s\t%s\n", line, reason); failures++; continue; }
        if(allowed == 0 || allowed == 1) {
            char *bootout[] = {"/bin/launchctl", "bootout", "system", line, NULL};
            run(bootout);   // not loaded is fine
        }
        char destination[PATH_MAX];
        int error = moveItem(line, allowed, trash, user->pw_uid, user->pw_gid, destination, sizeof(destination));
        if(error) { printf("skipped\t%s\t%s\n", line, strerror(error)); failures++; }
        else printf("moved\t%s\t%s\n", line, destination);
    }
    fclose(manifest);
    return failures ? 1 : 0;
}

#ifndef OMNISTATS_CLEANER_NO_MAIN
int main(int argc, char **argv) {
    if(geteuid() != 0) { fprintf(stderr, "omnistats-cleaner must run as root\n"); return 2; }
    return cleanerMain(argc, argv);
}
#endif

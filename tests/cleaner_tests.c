// Path validation and moves for omnistats-cleaner, run against a scratch tree.
#define OMNISTATS_CLEANER_NO_MAIN
#include "../src/cleaner.c"
#include <assert.h>
#include <fcntl.h>

static void touch(const char *path) { int fd = open(path, O_CREAT | O_WRONLY, 0644); assert(fd >= 0); close(fd); }
static void makeDirectories(const char *path) {
    char partial[PATH_MAX]; strlcpy(partial, path, sizeof(partial));
    for(char *slash = partial + 1; *slash; slash++) if(*slash == '/') { *slash = 0; mkdir(partial, 0755); *slash = '/'; }
    mkdir(partial, 0755);
}
static char root[PATH_MAX];
static const char *at(const char *relative) {
    static char buffers[8][PATH_MAX]; static int next;
    char *buffer = buffers[next++ % 8];
    snprintf(buffer, PATH_MAX, "%s%s", root, relative);
    return buffer;
}

int main(void) {
    char base[] = "/tmp/omnistats-cleaner-XXXXXX";
    assert(mkdtemp(base) && realpath(base, root));   // /tmp is a symlink to /private/tmp
    gRoot = root;
    for(int i = 0; kAllowed[i]; i++) makeDirectories(at(kAllowed[i]));
    touch(at("/Library/LaunchDaemons/com.example.app.helper.plist"));
    touch(at("/Library/LaunchDaemons/not-a-plist"));
    touch(at("/Library/PrivilegedHelperTools/com.example.app.helper"));
    makeDirectories(at("/Library/Application Support/Example/nested"));
    touch(at("/Library/Caches/com.example.app"));
    symlink(at("/Library/Caches/com.example.app"), at("/Library/Caches/link"));
    touch(at("/private/var/db/receipts/com.example.pkg.bom"));
    touch(at("/private/var/db/receipts/com.example.pkg.txt"));

    int index = -1;
    assert(validatePath(at("/Library/LaunchDaemons/com.example.app.helper.plist"), &index) == NULL && index == 0);
    assert(validatePath(at("/Library/PrivilegedHelperTools/com.example.app.helper"), &index) == NULL && index == 2);
    assert(validatePath(at("/Library/Application Support/Example"), &index) == NULL && index == 3);
    assert(validatePath(at("/private/var/db/receipts/com.example.pkg.bom"), &index) == NULL && index == 7);
    assert(!strcmp(validatePath(at("/Library/LaunchDaemons"), NULL), "outside the allowed folders"));
    assert(!strcmp(validatePath(at("/Library/Application Support/Example/nested"), NULL), "not a direct child of an allowed folder"));
    assert(!strcmp(validatePath(at("/Library/LaunchDaemons/not-a-plist"), NULL), "not a launchd plist"));
    assert(!strcmp(validatePath(at("/private/var/db/receipts/com.example.pkg.txt"), NULL), "not a package receipt"));
    assert(!strcmp(validatePath(at("/Library/Caches/link"), NULL), "symbolic link"));
    assert(!strcmp(validatePath(at("/Library/Caches/../Caches/com.example.app"), NULL), "relative component"));
    assert(!strcmp(validatePath(at("/Library/Caches/missing"), NULL), "missing"));
    assert(!strcmp(validatePath("/etc/passwd", NULL), "outside the allowed folders"));
    assert(!strcmp(validatePath("Library/Caches/x", NULL), "not absolute"));
    assert(validFolderName("OmniStats Removed 2026-10-30 Example") && !validFolderName("../x") && !validFolderName("a/b")
           && !validFolderName("..") && !validFolderName(""));

    // A full run as the current user (bootout fails harmlessly without root).
    struct passwd *me = getpwuid(getuid());
    char trashParent[PATH_MAX]; snprintf(trashParent, sizeof(trashParent), "%s%s/.Trash", root, me->pw_dir);
    makeDirectories(trashParent);
    touch(at("/Library/Caches/Example Removed Twice"));
    char manifestPath[PATH_MAX]; snprintf(manifestPath, sizeof(manifestPath), "%s/manifest", root);
    FILE *manifest = fopen(manifestPath, "w");
    fprintf(manifest, "%s\n%s\n%s\n%s\n\n%s\n", at("/Library/LaunchDaemons/com.example.app.helper.plist"),
            at("/Library/PrivilegedHelperTools/com.example.app.helper"), at("/Library/Application Support/Example"),
            at("/Library/Caches/link"), "/etc/hosts");
    fclose(manifest);
    char uid[16]; snprintf(uid, sizeof(uid), "%u", getuid());
    char *argv[] = {"omnistats-cleaner", manifestPath, uid, "OmniStats Removed Test", NULL};
    fflush(stdout);
    int saved = dup(STDOUT_FILENO), quiet = open("/dev/null", O_WRONLY);
    dup2(quiet, STDOUT_FILENO); dup2(quiet, STDERR_FILENO);
    int status = cleanerMain(4, argv);
    fflush(stdout); dup2(saved, STDOUT_FILENO);
    assert(status == 1);   // two refusals
    char moved[PATH_MAX];
    snprintf(moved, sizeof(moved), "%s/OmniStats Removed Test/LaunchDaemons/com.example.app.helper.plist", trashParent);
    assert(access(moved, F_OK) == 0 && access(at("/Library/LaunchDaemons/com.example.app.helper.plist"), F_OK) != 0);
    snprintf(moved, sizeof(moved), "%s/OmniStats Removed Test/PrivilegedHelperTools/com.example.app.helper", trashParent);
    assert(access(moved, F_OK) == 0);
    snprintf(moved, sizeof(moved), "%s/OmniStats Removed Test/Application Support/Example/nested", trashParent);
    assert(access(moved, F_OK) == 0);
    struct stat info;
    assert(lstat(at("/Library/Caches/link"), &info) == 0 && S_ISLNK(info.st_mode));   // refused, left in place
    assert(access("/etc/hosts", F_OK) == 0);

    // A name clash never overwrites what is already in the Trash.
    touch(at("/Library/PrivilegedHelperTools/com.example.app.helper"));
    char destination[PATH_MAX];
    char trash[PATH_MAX]; snprintf(trash, sizeof(trash), "%s/OmniStats Removed Test", trashParent);
    assert(moveItem(at("/Library/PrivilegedHelperTools/com.example.app.helper"), 2, trash, getuid(), getgid(),
                    destination, sizeof(destination)) == EEXIST);
    assert(access(at("/Library/PrivilegedHelperTools/com.example.app.helper"), F_OK) == 0);

    char *cleanup[] = {"/bin/rm", "-rf", root, NULL};
    run(cleanup);
    puts("PASS: cleaner path allow-list, symlink and traversal refusal, moves into the Trash, no overwrite");
    return 0;
}

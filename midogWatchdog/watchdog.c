#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <syslog.h>
#include <unistd.h>

#include <CoreFoundation/CoreFoundation.h>
#include "proxy_catalog.h"

#define INTERVAL 3
#define BUNDLE_CACHE_SIZE 256
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }

static bool protected_path(const char *path) {
    // Do not exempt /usr/local: Homebrew cores must be detected on Intel Macs too.
    const char *prefixes[] = {"/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/Library/Apple/"};
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(*prefixes); i++)
        if (strncmp(path, prefixes[i], strlen(prefixes[i])) == 0) return true;
    const char *name = strrchr(path, '/');
    return name && (!strcmp(name, "/midog") || !strcmp(name, "/midog-core") ||
                    !strcmp(name, "/midog-watchdog") || !strcmp(name, "/com.xx.midog.mihomo"));
}

static bool listed(enum rule_kind kind, const char *value) {
    for (size_t i = 0; i < CATALOG_COUNT; i++)
        if (catalog[i].kind == kind && !strcmp(value, catalog[i].value)) return true;
    return false;
}

// Metadata is cached by plist location and file identity, not by app display name.
// Bounded memory; replacement or edits invalidate both positive and negative entries.
struct bundle_cache {
    char *path;
    struct stat info;
    int result; // -1: own app, 0: unknown, 1: catalogued proxy
};
static struct bundle_cache bundle_cache[BUNDLE_CACHE_SIZE];
static size_t cache_next;

static int bundle_result(const char *plist_path) {
    struct stat info;
    if (lstat(plist_path, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 1024 * 1024) return 0;
    struct bundle_cache *slot = NULL;
    for (size_t i = 0; i < BUNDLE_CACHE_SIZE; i++) {
        struct bundle_cache *entry = &bundle_cache[i];
        if (!entry->path || strcmp(entry->path, plist_path)) continue;
        slot = entry;
        if (info.st_dev == entry->info.st_dev && info.st_ino == entry->info.st_ino &&
            info.st_size == entry->info.st_size &&
            info.st_mtimespec.tv_sec == entry->info.st_mtimespec.tv_sec &&
            info.st_mtimespec.tv_nsec == entry->info.st_mtimespec.tv_nsec &&
            info.st_ctimespec.tv_sec == entry->info.st_ctimespec.tv_sec &&
            info.st_ctimespec.tv_nsec == entry->info.st_ctimespec.tv_nsec) return entry->result;
        break;
    }
    int fd = open(plist_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return 0;
    struct stat opened;
    if (fstat(fd, &opened) || !S_ISREG(opened.st_mode) || opened.st_dev != info.st_dev ||
        opened.st_ino != info.st_ino || opened.st_size != info.st_size) { close(fd); return 0; }
    char *bytes = malloc((size_t)info.st_size);
    if (!bytes) { close(fd); return 0; }
    size_t used = 0;
    while (used < (size_t)info.st_size) {
        ssize_t n = read(fd, bytes + used, (size_t)info.st_size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        used += (size_t)n;
    }
    close(fd);
    if (used != (size_t)info.st_size) { free(bytes); return 0; }
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)bytes, (CFIndex)used);
    free(bytes);
    if (!data) return 0;
    CFPropertyListRef plist = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    int result = 0;
    if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
        CFTypeRef identifier = CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR("CFBundleIdentifier"));
        char id[512];
        if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID() &&
            CFStringGetCString((CFStringRef)identifier, id, sizeof(id), kCFStringEncodingUTF8)) {
            if (!strcmp(id, "com.xx.midog") || !strcmp(id, "com.xx.midog.filter")) result = -1;
            else if (listed(RULE_BUNDLE, id)) result = 1;
        }
    }
    if (plist) CFRelease(plist);
    if (!slot) slot = &bundle_cache[cache_next++ % BUNDLE_CACHE_SIZE];
    free(slot->path);
    slot->path = strdup(plist_path);
    slot->info = info;
    slot->result = result;
    return result;
}

static bool matches(const char *path) {
    if (protected_path(path)) return false;
    // Walk enclosing app bundles, including renamed apps and nested helper apps.
    // No directory restriction: Downloads, App Translocation and external volumes work.
    const char *suffixes[] = {".app/Contents/", ".systemextension/Contents/", ".appex/Contents/"};
    bool bundle_match = false;
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(*suffixes); i++) {
        const char *cursor = path;
        while ((cursor = strstr(cursor, suffixes[i]))) {
            size_t prefix = (size_t)(cursor - path) + strlen(suffixes[i]);
            char plist[PROC_PIDPATHINFO_MAXSIZE];
            if (prefix + strlen("Info.plist") >= sizeof(plist)) break;
            memcpy(plist, path, prefix);
            strcpy(plist + prefix, "Info.plist");
            int result = bundle_result(plist);
            if (result == -1) return false;
            if (result == 1) bundle_match = true;
            cursor += strlen(suffixes[i]);
        }
    }
    const char *name = strrchr(path, '/');
    return bundle_match || (name && listed(RULE_EXECUTABLE, name + 1));
}

static void clear_cache(void) {
    for (size_t i = 0; i < BUNDLE_CACHE_SIZE; i++) {
        free(bundle_cache[i].path);
        bundle_cache[i].path = NULL;
    }
}

struct pending {
    pid_t pid;
    uint64_t seconds, microseconds;
};
static bool identity(pid_t pid, struct proc_bsdinfo *info) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == sizeof(*info);
}

static int monitor(bool dry) {
    signal(SIGTERM, stop); signal(SIGINT, stop);
    openlog("midog-watchdog", LOG_PID, LOG_DAEMON);
    pid_t *pids = NULL;
    size_t capacity = 0, previous_count = 0;
    struct pending *previous = NULL;
    int status = 0;
    do {
        int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
        if (bytes <= 0) { syslog(LOG_ERR, "Cannot enumerate processes"); status = 1; break; }
        if ((size_t)bytes + 4096 > capacity) {
            size_t new_capacity = (size_t)bytes + 4096;
            pid_t *next = realloc(pids, new_capacity);
            if (!next) { status = 1; break; }
            pids = next; capacity = new_capacity;
        }
        bytes = proc_listpids(PROC_ALL_PIDS, 0, pids, (int)capacity);
        if (bytes <= 0) { status = 1; break; }
        size_t count = (size_t)bytes / sizeof(pid_t), current_count = 0;
        struct pending *current = calloc(count ? count : 1, sizeof(*current));
        if (!current) { status = 1; break; }
        for (size_t i = 0; i < count && !stopping; i++) {
            pid_t pid = pids[i];
            if (pid <= 1 || pid == getpid()) continue;
            struct proc_bsdinfo before, after;
            char path[PROC_PIDPATHINFO_MAXSIZE], recheck[PROC_PIDPATHINFO_MAXSIZE];
            if (proc_pidpath(pid, path, sizeof(path)) <= 0 || !matches(path)) continue;
            if (dry) { printf("%d\t%s\n", pid, path); continue; }
            if (!identity(pid, &before)) continue;
            int sig = SIGTERM;
            for (size_t j = 0; j < previous_count; j++)
                if (previous[j].pid == pid && previous[j].seconds == before.pbi_start_tvsec &&
                    previous[j].microseconds == before.pbi_start_tvusec) { sig = SIGKILL; break; }
            // Recheck both identity and executable immediately before signaling a PID.
            if (!identity(pid, &after) || before.pbi_start_tvsec != after.pbi_start_tvsec ||
                before.pbi_start_tvusec != after.pbi_start_tvusec ||
                proc_pidpath(pid, recheck, sizeof(recheck)) <= 0 || strcmp(path, recheck) || !matches(recheck)) continue;
            if (kill(pid, sig) == 0) {
                syslog(LOG_NOTICE, "Sent %s to pid=%d path=%s", sig == SIGTERM ? "TERM" : "KILL", pid, path);
                current[current_count++] = (struct pending){pid, before.pbi_start_tvsec, before.pbi_start_tvusec};
            } else if (errno != ESRCH) {
                // Report once per surviving identity; avoid logging every polling cycle.
                if (sig == SIGTERM) syslog(LOG_WARNING, "Cannot terminate pid=%d path=%s: %s", pid, path, strerror(errno));
                current[current_count++] = (struct pending){pid, before.pbi_start_tvsec, before.pbi_start_tvusec};
            }
        }
        free(previous); previous = current; previous_count = current_count;
        if (!dry && !stopping) sleep(INTERVAL);
    } while (!dry && !stopping);
    free(previous); free(pids); clear_cache(); closelog();
    return status;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--list")) {
        for (size_t i = 0; i < CATALOG_COUNT; i++)
            printf("%s\t%s\t%s\t%s\n", catalog[i].project,
                   catalog[i].kind == RULE_BUNDLE ? "bundle" : "executable",
                   catalog[i].value, catalog[i].source);
        return 0;
    }
    bool dry = argc == 2 && !strcmp(argv[1], "--dry-run");
    if (argc != 1 && !dry) {
        fprintf(stderr, "Usage: midog-watchdog [--list|--dry-run]\n"); return 2;
    }
    if (!dry && geteuid() != 0) {
        fprintf(stderr, "Install as a launchd system service to enforce rules\n"); return 1;
    }
    return monitor(dry);
}

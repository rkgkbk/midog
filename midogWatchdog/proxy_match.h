// Shared by the watchdog and the content filter; callers serialize access to the cache.
#ifndef MIDOG_PROXY_MATCH_H
#define MIDOG_PROXY_MATCH_H
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include "proxy_catalog.h"
#define BUNDLE_CACHE_SIZE 256

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

#endif

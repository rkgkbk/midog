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
#include "proxy_match.h"

#define INTERVAL 3
static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }


struct pending {
    pid_t pid;
    uint64_t seconds, microseconds;
};
static bool identity(pid_t pid, struct proc_bsdinfo *info) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == sizeof(*info);
}

static int monitor(bool dry, pid_t owner) {
    signal(SIGTERM, stop); signal(SIGINT, stop);
    openlog("midog-watchdog", LOG_PID, LOG_DAEMON);
    pid_t *pids = NULL;
    size_t capacity = 0, previous_count = 0;
    struct pending *previous = NULL;
    int status = 0;
    do {
        if (owner && getppid() != owner) break;
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
            if (owner && before.pbi_uid != getuid()) continue;
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
    bool user = argc == 2 && !strcmp(argv[1], "--user-monitor");
    if (argc != 1 && !dry && !user) {
        fprintf(stderr, "Usage: midog-watchdog [--list|--dry-run|--user-monitor]\n"); return 2;
    }
    if (!dry && !user && geteuid() != 0) {
        fprintf(stderr, "Install as a launchd system service to enforce rules\n"); return 1;
    }
    pid_t owner = user ? getppid() : 0;
    if (user && owner <= 1) return 1;
    return monitor(dry, owner);
}

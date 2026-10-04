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

#define MAX_RULES 256
#define RULES_FILE "/Library/Application Support/midog-watchdog/proxies.list"
#define INTERVAL 3

static char rules[MAX_RULES][PROC_PIDPATHINFO_MAXSIZE];
static size_t rule_count;
static volatile sig_atomic_t stopping;

static void stop(int sig) { (void)sig; stopping = 1; }

static bool protected_path(const char *path) {
    const char *prefixes[] = {"/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"};
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(*prefixes); i++)
        if (strncmp(path, prefixes[i], strlen(prefixes[i])) == 0) return true;
    const char *name = strrchr(path, '/');
    return name && (!strcmp(name, "/midog") || !strcmp(name, "/midog-core") ||
                    !strcmp(name, "/midog-watchdog") || !strcmp(name, "/com.xx.midog.mihomo"));
}

// Exact paths only. No globbing, basename matching, commands or shell expansion.
static bool load_rules(const char *path, bool trusted) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) { perror(path); return false; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size > 1024 * 1024 ||
        (trusted && (st.st_uid != 0 || (st.st_mode & 022)))) {
        fprintf(stderr, "Unsafe or oversized rules file\n"); close(fd); return false;
    }
    FILE *file = fdopen(fd, "r");
    if (!file) { close(fd); return false; }
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    bool valid = true;
    rule_count = 0;
    while ((length = getline(&line, &capacity, file)) >= 0) {
        size_t n = (size_t)length;
        if (strlen(line) != n) { valid = false; break; }
        if (n && line[n - 1] == '\n') line[--n] = 0;
        if (n && line[n - 1] == '\r') line[--n] = 0;
        if (!n || line[0] == '#') continue;
        if (n >= PROC_PIDPATHINFO_MAXSIZE || line[0] != '/' || line[n - 1] == '/' ||
            strpbrk(line, "*?[]\t\r") || strstr(line, "/../") || strstr(line, "/./") ||
            strstr(line, "//") || protected_path(line) || rule_count == MAX_RULES) {
            fprintf(stderr, "Invalid or protected executable path: %s\n", line);
            valid = false; break;
        }
        strcpy(rules[rule_count++], line);
    }
    if (ferror(file)) valid = false;
    free(line);
    fclose(file);
    return valid;
}

static bool matches(const char *path) {
    if (protected_path(path)) return false;
    for (size_t i = 0; i < rule_count; i++)
        if (!strcmp(path, rules[i])) return true;
    return false;
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
                proc_pidpath(pid, recheck, sizeof(recheck)) <= 0 || strcmp(path, recheck)) continue;
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
    free(previous); free(pids); closelog();
    return status;
}

int main(int argc, char **argv) {
    bool dry = false, check = false;
    const char *config = RULES_FILE;
    if (argc == 3 && (!strcmp(argv[1], "--check") || !strcmp(argv[1], "--dry-run"))) {
        check = !strcmp(argv[1], "--check"); dry = !check; config = argv[2];
    } else if (argc != 1) {
        fprintf(stderr, "Usage: midog-watchdog [--check|--dry-run FILE]\n"); return 2;
    }
    if (!check && !dry && geteuid() != 0) {
        fprintf(stderr, "Install as a launchd system service to enforce rules\n"); return 1;
    }
    if (!load_rules(config, !check && !dry)) return 1;
    if (check) { printf("Valid rules: %zu\n", rule_count); return 0; }
    return monitor(dry);
}

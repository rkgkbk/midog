#include "ProxyFlow.h"
#include "../midogWatchdog/proxy_match.h"

bool midog_proxy_flow(const void *bytes, size_t length) {
    if (!bytes || length != sizeof(audit_token_t)) return false;
    audit_token_t token;
    memcpy(&token, bytes, sizeof(token));
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath_audittoken(&token, path, sizeof(path)) <= 0) return false;
    return matches(path);
}

void midog_proxy_cache_clear(void) { clear_cache(); }

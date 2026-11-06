#ifndef MIDOG_PROXY_FLOW_H
#define MIDOG_PROXY_FLOW_H
#include <stdbool.h>
#include <stddef.h>

// Uses the full audit token, including process version, rather than a reusable PID.
bool midog_proxy_flow(const void *bytes, size_t length);
void midog_proxy_cache_clear(void);
#endif

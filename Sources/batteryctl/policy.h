#ifndef CLAUDEBAR_BATTERY_POLICY_H
#define CLAUDEBAR_BATTERY_POLICY_H
#include <errno.h>
#include <stdlib.h>
#include <string.h>
// The same policy is used by the privileged monitor and the regression tests.
enum { BAT_SYSTEM, BAT_LIMIT, BAT_HOLD, BAT_DISCHARGE };
enum { POWER_SYSTEM, POWER_CHARGE, POWER_HOLD, POWER_DISCHARGE };
static int battery_decision(int mode, int limit, int percent, int previous) {
    if (mode < BAT_SYSTEM || mode > BAT_DISCHARGE || limit < 20 || limit > 100 || percent < 0 || percent > 100)
        return POWER_SYSTEM;
    if (mode == BAT_SYSTEM) return POWER_SYSTEM;
    if (percent < 20) return POWER_CHARGE;
    if (mode == BAT_HOLD) return POWER_HOLD;
    if (mode == BAT_DISCHARGE && percent > limit) return POWER_DISCHARGE;
    if (percent >= limit) return POWER_HOLD;
    // Two percentage points of hysteresis prevent toggling at the limit.
    if (previous == POWER_HOLD && percent > limit - 2) return POWER_HOLD;
    return POWER_CHARGE;
}
// Strict, bounded protocol: no signed values, overflow or trailing tokens.
static int battery_parse_command(const char *line, int *mode, int *limit, unsigned long *revision) {
    if (strncmp(line, "set ", 4)) return 0;
    const char *cursor = line + 4;
    unsigned long values[3];
    for (int i = 0; i < 3; i++) {
        if (*cursor < '0' || *cursor > '9') return 0;
        errno = 0; char *end;
        values[i] = strtoul(cursor, &end, 10);
        if (errno || (i < 2 ? *end != ' ' : *end != '\0')) return 0;
        cursor = end + (i < 2 ? 1 : 0);
    }
    if (values[0] > BAT_DISCHARGE || values[1] < 20 || values[1] > 100 || values[2] == 0) return 0;
    *mode = (int)values[0]; *limit = (int)values[1]; *revision = values[2]; return 1;
}
#endif

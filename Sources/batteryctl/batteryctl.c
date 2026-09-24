// ClaudeBar battery control. Original implementation; protocol references in
// docs/technical/12-battery-control.md. No arbitrary keys, paths or shell commands.
// --probe is read-only. --serve requires root and a private stdin/stdout pipe.
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include "policy.h"

#pragma pack(push, 4)
typedef struct {
    uint32_t key; uint8_t version[8];
    struct { uint16_t a,b; uint32_t c,d,e; } limits;
    struct { uint32_t size,type; uint8_t attributes,pad[3]; } info;
    uint8_t result,status,command,pad; uint32_t data; uint8_t bytes[32];
} Packet;
#pragma pack(pop)
_Static_assert(sizeof(Packet) == 80, "SMC ABI");
typedef struct { const char *name; Packet meta; uint8_t original[32]; } Key;
static io_connect_t smc, powerPort;
static Key charge[2], adapter;
static int chargeCount, hasAdapter, owned, sleeping, mode, limit = 80, applied = POWER_SYSTEM;
static unsigned long revision;
static double heartbeat;
static double monotonic(void);
static volatile sig_atomic_t stopping;
static const char *errorCode = "";
static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 | (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3];
}
static int call(Packet *in, Packet *out) {
    memset(out, 0, sizeof(*out)); size_t n = sizeof(*out);
    return IOConnectCallStructMethod(smc, 2, in, sizeof(*in), out, &n) == KERN_SUCCESS && n == sizeof(*out) && !out->result;
}
static int read_bytes(Key *key, uint8_t *bytes) {
    Packet in = key->meta, out; in.command = 5;
    if (!call(&in, &out)) return 0;
    memcpy(bytes, out.bytes, key->meta.info.size); return 1;
}
static int detect(Key *key, const char *name, uint32_t size) {
    Packet in = {0}, out; in.key = fourcc(name); in.command = 9;
    if (!call(&in, &out) || out.info.size != size) return 0;
    key->name = name; key->meta = in; key->meta.info = out.info;
    return read_bytes(key, key->original);
}
static int write_bytes(Key *key, const uint8_t *bytes) {
    uint8_t check[32] = {0};
    if (read_bytes(key, check) && !memcmp(bytes, check, key->meta.info.size)) return 1;
    Packet in = key->meta, out; in.command = 6;
    memcpy(in.bytes, bytes, key->meta.info.size);
    for (int i = 0; i < 3; i++) {
        if (call(&in, &out) && read_bytes(key, check) && !memcmp(bytes, check, key->meta.info.size)) return 1;
        usleep(20000);
    }
    return 0;
}
static int discover(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self_, 0, &smc); IOObjectRelease(service);
    if (result != KERN_SUCCESS) return 0;
    if (detect(&charge[0], "CHTE", 4)) chargeCount = 1;
    else if (detect(&charge[0], "CH0B", 1) && detect(&charge[1], "CH0C", 1)) chargeCount = 2;
    hasAdapter = detect(&adapter, "CHIE", 1) || detect(&adapter, "CH0J", 1) || detect(&adapter, "CH0I", 1);
    return chargeCount > 0;
}
static int restore(void) {
    if (!owned) return 1;
    int ok = 1;
    // Reconnect the adapter before enabling charge, including after a partial failure.
    if (hasAdapter && !write_bytes(&adapter, adapter.original)) ok = 0;
    for (int i = 0; i < chargeCount; i++) if (!write_bytes(&charge[i], charge[i].original)) ok = 0;
    if (ok) { applied = POWER_SYSTEM; owned = 0; }
    return ok;
}
static int apply(int next) {
    if (next == POWER_SYSTEM) return restore();
    if (next == POWER_DISCHARGE && !hasAdapter) return 0;
    owned = 1;
    uint8_t bytes[32] = {0};
    if (hasAdapter && next != POWER_DISCHARGE && !write_bytes(&adapter, bytes)) return 0;
    for (int i = 0; i < chargeCount; i++) {
        bytes[0] = next == POWER_CHARGE ? 0 : (chargeCount == 1 ? 1 : 2);
        if (!write_bytes(&charge[i], bytes)) return 0;
    }
    if (next == POWER_DISCHARGE) {
        memset(bytes, 0, sizeof bytes); bytes[0] = !strcmp(adapter.name, "CHIE") ? 8 : 1;
        if (!write_bytes(&adapter, bytes)) return 0;
    }
    applied = next; return 1;
}
static int number(CFDictionaryRef dict, CFStringRef key, int *value) {
    CFTypeRef v = CFDictionaryGetValue(dict, key);
    return v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue(v, kCFNumberIntType, value);
}
static int boolean(CFDictionaryRef dict, CFStringRef key) {
    CFTypeRef v = CFDictionaryGetValue(dict, key);
    if (!v) return 0;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) return CFBooleanGetValue(v);
    int n = 0; return number(dict, key, &n) && n != 0;
}
static int battery(int *percent, int *plugged, int *lidClosed) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!service) return 0;
    CFMutableDictionaryRef dict = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(service, &dict, kCFAllocatorDefault, 0); IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !dict) return 0;
    int valid = boolean(dict, CFSTR("BatteryInstalled")) && number(dict, CFSTR("CurrentCapacity"), percent);
    *plugged = boolean(dict, CFSTR("ExternalConnected"));
    CFRelease(dict);
    service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!service) return 0;
    CFTypeRef lid = IORegistryEntryCreateCFProperty(service, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(service);
    // Unknown lid state cannot authorize adapter disconnect.
    *lidClosed = !lid || CFGetTypeID(lid) != CFBooleanGetTypeID() || CFBooleanGetValue(lid);
    if (lid) CFRelease(lid);
    return valid && *percent >= 0 && *percent <= 100;
}
static void report(int percent) {
    char line[512];
    int count = snprintf(line, sizeof line,
        "{\"revision\":%lu,\"mode\":%d,\"limit\":%d,\"state\":%d,\"percent\":%d,\"dischargeSupported\":%s,\"sleeping\":%s,\"error\":\"%s\"}\n",
        revision, mode, limit, applied, percent, hasAdapter ? "true" : "false", sleeping ? "true" : "false", errorCode);
    // A caller that stops reading must not block the battery safety loop.
    if (count < 0 || count >= (int)sizeof line || write(STDOUT_FILENO, line, (size_t)count) != count) stopping = 1;
}
static void signal_stop(int sig) { (void)sig; stopping = 1; }
static void power_event(void *ref, io_service_t service, natural_t type, void *argument) {
    (void)ref; (void)service;
    if (type == kIOMessageCanSystemSleep) IOAllowPowerChange(powerPort, (long)argument);
    if (type == kIOMessageSystemWillSleep) {
        sleeping = 1;
        if (!restore()) { errorCode = "restore_failed"; stopping = 1; }
        if (mode == BAT_DISCHARGE) mode = BAT_LIMIT;
        report(-1);
        IOAllowPowerChange(powerPort, (long)argument);
    }
    if (type == kIOMessageSystemHasPoweredOn) { sleeping = 0; heartbeat = monotonic(); }
}
static double monotonic(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static int serve(void) {
    // Never allow simultaneous ClaudeBar monitors to fight over SMC state.
    int lock = open("/var/run/claudebar-battery.lock", O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC, 0600);
    struct stat st;
    if (lock < 0 || fstat(lock, &st) || !S_ISREG(st.st_mode) || st.st_uid != 0 || st.st_nlink != 1 ||
        (st.st_mode & 0022) || flock(lock, LOCK_EX|LOCK_NB)) { errorCode = "already_running"; report(-1); return 1; }
    if (!discover()) { errorCode = "unsupported"; report(-1); return 1; }
    // Refuse to take over a setting already owned by another battery utility.
    for (int i = 0; i < chargeCount; i++) for (unsigned j = 0; j < charge[i].meta.info.size; j++)
        if (charge[i].original[j]) { errorCode = "external_control"; report(-1); return 1; }
    if (hasAdapter && adapter.original[0]) { errorCode = "external_control"; report(-1); return 1; }
    IONotificationPortRef notifications = NULL; io_object_t notifier = 0;
    powerPort = IORegisterForSystemPower(NULL, &notifications, power_event, &notifier);
    if (!powerPort) { errorCode = "sleep_monitor_failed"; report(-1); return 1; }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(notifications), kCFRunLoopDefaultMode);
    signal(SIGTERM, signal_stop); signal(SIGINT, signal_stop); signal(SIGHUP, signal_stop); signal(SIGPIPE, SIG_IGN);
    fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK);
    fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK);
    heartbeat = monotonic(); double lastTick = 0;
    char buffer[256]; size_t used = 0;
    report(-1);
    while (!stopping) {
        char byte; ssize_t n;
        while ((n = read(STDIN_FILENO, &byte, 1)) == 1) {
            if (byte == 0) { errorCode = "invalid_command"; stopping = 1; break; }
            if (byte != '\n') { if (used == sizeof(buffer)-1) { stopping = 1; break; } buffer[used++] = byte; continue; }
            buffer[used] = 0; used = 0;
            if (!strcmp(buffer, "ping")) { heartbeat = monotonic(); continue; }
            int nextMode, nextLimit; unsigned long nextRevision;
            if (!battery_parse_command(buffer, &nextMode, &nextLimit, &nextRevision)) {
                errorCode = "invalid_command"; stopping = 1; break;
            }
            mode = nextMode; limit = nextLimit; revision = nextRevision; heartbeat = monotonic(); lastTick = 0;
        }
        if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) stopping = 1;
        if (!sleeping && monotonic() - heartbeat > 20) { errorCode = "heartbeat_lost"; stopping = 1; }
        if (stopping) break;
        if (!sleeping && monotonic() - lastTick >= 2) {
            lastTick = monotonic(); int percent = -1, plugged = 0, lid = 1;
            if (!battery(&percent, &plugged, &lid)) { errorCode = "battery_unavailable"; stopping = 1; break; }
            if (mode == BAT_DISCHARGE && (percent <= limit || lid)) mode = BAT_LIMIT;
            if (mode == BAT_DISCHARGE && !hasAdapter) { errorCode = "discharge_unsupported"; stopping = 1; break; }
            if (mode == BAT_DISCHARGE && applied != POWER_DISCHARGE && !plugged) {
                errorCode = "adapter_required"; mode = BAT_LIMIT;
            } else errorCode = "";
            int next = battery_decision(mode, limit, percent, applied);
            if (!apply(next)) { errorCode = "write_failed"; stopping = 1; break; }
            report(percent);
            if (mode == BAT_SYSTEM && revision > 0) stopping = 1;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    }
    if (!restore()) errorCode = "restore_failed";
    mode = BAT_SYSTEM; report(-1);
    IODeregisterForSystemPower(&notifier); IOServiceClose(powerPort); IONotificationPortDestroy(notifications);
    IOServiceClose(smc); close(lock);
    return errorCode[0] ? 1 : 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--probe")) {
        int supported = discover();
        printf("{\"supported\":%s,\"dischargeSupported\":%s}\n", supported ? "true" : "false", hasAdapter ? "true" : "false");
        if (smc) IOServiceClose(smc); return 0;
    }
    if (argc != 2 || strcmp(argv[1], "--serve")) return 64;
    if (geteuid() != 0) return 77;
    return serve();
}

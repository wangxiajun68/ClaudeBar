// claudebar-fanctl: privileged fan-speed helper for ClaudeBar.
// Reads/writes AppleSMC fans using the macOS 26 (Darwin 25) 80-byte protocol.
// Usage:
//   claudebar-fanctl set <fanID> <rpm>   force fan to rpm
//   claudebar-fanctl auto <fanID>        return fan to automatic control
//   claudebar-fanctl autoall             all fans automatic
//   claudebar-fanctl status              JSON with fan list (debug)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

// FourCC helpers (host byte order = little endian, but SMC keys are BE fourcc).
static UInt32 fourcc(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16)
         | ((UInt32)(unsigned char)s[2] << 8) | (UInt32)(unsigned char)s[3];
}

// 80-byte SMC struct (macOS 26).
#pragma pack(push, 4)
typedef struct {
    UInt32 key;
    UInt8 vers[8];
    struct { UInt16 a, b; UInt32 c, d, e; } pLimitData; // 16 bytes
    struct { UInt32 dataSize; UInt32 dataType; UInt8 dataAttributes; UInt8 pad[3]; } keyInfo; // 12 bytes at offset 28
    UInt8 result;
    UInt8 status;
    UInt8 data8;
    UInt8 pad2;
    UInt32 data32;
    UInt8 bytes[32];
} SMCKeyData;
#pragma pack(pop)

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData must be 80 bytes");

enum { CMD_READ_INFO = 9, CMD_READ_BYTES = 5, CMD_WRITE_BYTES = 6 };
static const UInt32 KERNEL_INDEX = 2;

static io_connect_t smc_open(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &it) != KERN_SUCCESS) return 0;
    io_object_t dev = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!dev) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(dev, mach_task_self_, 0, &conn);
    IOObjectRelease(dev);
    return kr == KERN_SUCCESS ? conn : 0;
}

static kern_return_t call(io_connect_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t isz = sizeof(SMCKeyData), osz = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX, in, isz, out, &osz);
}

// Returns kr of the struct call; on success fills size/type/bytes.
static kern_return_t read_key(io_connect_t conn, const char *key, UInt8 *bytes, UInt32 *size, UInt32 *type) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.data8 = CMD_READ_INFO;
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS || out.result != 0) return kr != KERN_SUCCESS ? kr : 0xe00002cc;
    *size = out.keyInfo.dataSize;
    *type = out.keyInfo.dataType;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.keyInfo.dataSize = *size;
    in.data8 = CMD_READ_BYTES;
    kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS || out.result != 0) return kr != KERN_SUCCESS ? kr : 0xe00002cc;
    memcpy(bytes, out.bytes, *size < 32 ? *size : 32);
    return KERN_SUCCESS;
}

static kern_return_t write_key(io_connect_t conn, const char *key, UInt32 type, UInt32 size, const UInt8 *bytes) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    in.key = fourcc(key);
    in.keyInfo.dataSize = size;
    in.keyInfo.dataType = type;
    in.data8 = CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, size < 32 ? size : 32);
    kern_return_t kr = call(conn, &in, &out);
    if (kr != KERN_SUCCESS) return kr;
    return out.result == 0 ? KERN_SUCCESS : 0xe00002cc;
}

static double get_value(io_connect_t conn, const char *key) {
    UInt8 bytes[32]; UInt32 size = 0, type = 0;
    if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS || size == 0) return -1;
    if (type == fourcc("flt ")) {
        float f; memcpy(&f, bytes, 4); return f;
    }
    if (type == fourcc(" 8iu") || type == fourcc("ui8 ")) {
        return size == 1 ? bytes[0] : (double)(bytes[0] | (bytes[1] << 8));
    }
    if (type == fourcc("ui16")) return (double)((bytes[0] << 8) | bytes[1]);
    if (type == fourcc("sp78")) return ((int)bytes[0] * 256 + bytes[1]) / 256.0;
    if (type == fourcc("fpe2")) return (double)((bytes[0] << 6) + (bytes[1] >> 2));
    return -1;
}

// Unlock a fan for manual control. Returns true if mode==1 written.
static int unlock_fan(io_connect_t conn, int fan) {
    char key[8];
    snprintf(key, sizeof key, "F%dMd", fan);
    UInt8 bytes[32]; UInt32 size = 0, type = 0;
    if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) {
        snprintf(key, sizeof key, "F%dmd", fan);
        if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) return 0;
    }
    bytes[0] = 1;
    kern_return_t kr = write_key(conn, key, type, size, bytes);
    if (kr == KERN_SUCCESS) return 1;
    // Stats-style Ftst fallback.
    snprintf(key, sizeof key, "Ftst");
    if (read_key(conn, key, bytes, &size, &type) == KERN_SUCCESS && bytes[0] == 0) {
        bytes[0] = 1;
        for (int i = 0; i < 100; i++) {
            if (write_key(conn, "Ftst", type, size, bytes) == KERN_SUCCESS) break;
            usleep(50000);
        }
        usleep(3000000);
        snprintf(key, sizeof key, "F%dMd", fan);
        if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) {
            snprintf(key, sizeof key, "F%dmd", fan);
            if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) return 0;
        }
        bytes[0] = 1;
        for (int i = 0; i < 300; i++) {
            if (write_key(conn, key, type, size, bytes) == KERN_SUCCESS) return 1;
            usleep(100000);
        }
        return 0;
    }
    return 0;
}

static int set_rpm(io_connect_t conn, int fan, int rpm) {
    if (!unlock_fan(conn, fan)) return 2;
    char key[8];
    snprintf(key, sizeof key, "F%dTg", fan);
    UInt8 bytes[32]; UInt32 size = 0, type = 0;
    if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) return 3;
    if (type == fourcc("flt ")) {
        float f = (float)rpm;
        memcpy(bytes, &f, 4);
    } else if (type == fourcc("fpe2")) {
        bytes[0] = (UInt8)(rpm >> 6);
        bytes[1] = (UInt8)((rpm << 2) ^ ((rpm >> 6) << 8));
    } else {
        return 4;
    }
    for (int i = 0; i < 10; i++) {
        if (write_key(conn, key, type, size, bytes) == KERN_SUCCESS) return 0;
        usleep(50000);
    }
    return 5;
}

static int set_auto(io_connect_t conn, int fan) {
    char key[8];
    snprintf(key, sizeof key, "F%dMd", fan);
    UInt8 bytes[32]; UInt32 size = 0, type = 0;
    if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) {
        snprintf(key, sizeof key, "F%dmd", fan);
        if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) return 1;
    }
    bytes[0] = 0;
    for (int i = 0; i < 10; i++) {
        if (write_key(conn, key, type, size, bytes) == KERN_SUCCESS) return 0;
        usleep(50000);
    }
    // Fallback: write F*Tg = 0 which re-enables auto.
    snprintf(key, sizeof key, "F%dTg", fan);
    if (read_key(conn, key, bytes, &size, &type) != KERN_SUCCESS) return 2;
    float f = 0.0f;
    memcpy(bytes, &f, 4);
    for (int i = 0; i < 10; i++) {
        if (write_key(conn, key, type, size, bytes) == KERN_SUCCESS) return 0;
        usleep(50000);
    }
    return 3;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: fanctl set|auto|autoall|status ...\n"); return 64; }
    io_connect_t conn = smc_open();
    if (!conn) { fprintf(stderr, "cannot open AppleSMC\n"); return 1; }

    if (!strcmp(argv[1], "set") && argc == 4) {
        int fan = atoi(argv[2]), rpm = atoi(argv[3]);
        int rc = set_rpm(conn, fan, rpm);
        if (rc) fprintf(stderr, "set failed rc=%d\n", rc);
        IOServiceClose(conn);
        return rc;
    }
    if (!strcmp(argv[1], "auto") && argc == 3) {
        int rc = set_auto(conn, atoi(argv[2]));
        if (rc) fprintf(stderr, "auto failed rc=%d\n", rc);
        IOServiceClose(conn);
        return rc;
    }
    if (!strcmp(argv[1], "autoall")) {
        int n = (int)get_value(conn, "FNum");
        int rc = 0;
        for (int i = 0; i < n; i++) { int r = set_auto(conn, i); if (r) rc = r; }
        IOServiceClose(conn);
        return rc;
    }
    if (!strcmp(argv[1], "status")) {
        int n = (int)get_value(conn, "FNum");
        printf("{\"fans\":[");
        for (int i = 0; i < n; i++) {
            char key[8];
            snprintf(key, sizeof key, "F%dAc", i);
            double rpm = get_value(conn, key);
            snprintf(key, sizeof key, "F%dMn", i);
            double mn = get_value(conn, key);
            snprintf(key, sizeof key, "F%dMx", i);
            double mx = get_value(conn, key);
            printf("%s{\"id\":%d,\"rpm\":%.0f,\"min\":%.0f,\"max\":%.0f}", i ? "," : "", i, rpm, mn, mx);
        }
        printf("]}\n");
        IOServiceClose(conn);
        return 0;
    }
    fprintf(stderr, "unknown command\n");
    IOServiceClose(conn);
    return 64;
}

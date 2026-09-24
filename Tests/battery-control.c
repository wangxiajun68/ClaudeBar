// Hardware-free tests run the actual privileged write/rollback implementation.
#define IOConnectCallStructMethod fake_smc_call
#define IOAllowPowerChange fake_allow_sleep
#define main batteryctl_program_main
#include "../Sources/batteryctl/batteryctl.c"
#undef main
#include <assert.h>

static uint8_t fakeCharge[4], fakeSecondCharge[4], fakeAdapter[1];
static int rejectCharge, rejectAdapter, writes, adapterFirst;
kern_return_t fake_allow_sleep(io_connect_t port, long argument) { (void)port; (void)argument; return KERN_SUCCESS; }
kern_return_t fake_smc_call(mach_port_t connection, uint32_t selector, const void *input, size_t inputSize, void *output, size_t *outputSize) {
    (void)connection; (void)selector; (void)inputSize;
    const Packet *in = input; Packet *out = output;
    memset(out, 0, sizeof(*out)); *outputSize = sizeof(*out);
    int isAdapter = in->key == fourcc("CHIE");
    uint8_t *storage = isAdapter ? fakeAdapter : in->key == fourcc("CH0C") ? fakeSecondCharge : fakeCharge;
    unsigned size = isAdapter || in->key == fourcc("CH0B") || in->key == fourcc("CH0C") ? 1 : 4;
    if (in->command == 6) {
        writes++;
        if (writes == 1) adapterFirst = isAdapter;
        if ((isAdapter && rejectAdapter) || (!isAdapter && rejectCharge)) return KERN_FAILURE;
        memcpy(storage, in->bytes, size);
    } else if (in->command == 5) memcpy(out->bytes, storage, size);
    else return KERN_FAILURE;
    return KERN_SUCCESS;
}
static void reset_fixture(void) {
    memset(charge, 0, sizeof charge); memset(&adapter, 0, sizeof adapter);
    memset(fakeCharge, 0, sizeof fakeCharge); memset(fakeSecondCharge, 0, sizeof fakeSecondCharge); memset(fakeAdapter, 0, sizeof fakeAdapter);
    charge[0].name = "CHTE"; charge[0].meta.key = fourcc("CHTE"); charge[0].meta.info.size = 4;
    adapter.name = "CHIE"; adapter.meta.key = fourcc("CHIE"); adapter.meta.info.size = 1;
    chargeCount = 1; hasAdapter = 1; owned = 0; applied = POWER_SYSTEM;
    rejectCharge = rejectAdapter = writes = adapterFirst = stopping = sleeping = 0;
    errorCode = "";
}
int main(void) {
    int parsedMode, parsedLimit; unsigned long parsedRevision;
    assert(battery_parse_command("set 3 80 1", &parsedMode, &parsedLimit, &parsedRevision));
    assert(parsedMode == BAT_DISCHARGE && parsedLimit == 80 && parsedRevision == 1);
    const char *invalid[] = { "set -1 80 1", "set 4 80 1", "set 1 19 1", "set 1 101 1", "set 1 80 0",
        "set 1 80 1 extra", "set 1 80 18446744073709551616", "set +1 80 1", "set 1 80", "set 1  80 1" };
    for (unsigned i = 0; i < sizeof(invalid)/sizeof(invalid[0]); i++)
        assert(!battery_parse_command(invalid[i], &parsedMode, &parsedLimit, &parsedRevision));
    // Upper/lower limits, hysteresis, and the 20% reserve.
    for (int l = 20; l <= 100; l++) {
        for (int p = 0; p <= 100; p++) {
            assert(battery_decision(BAT_SYSTEM, l, p, POWER_HOLD) == POWER_SYSTEM);
            assert(battery_decision(BAT_LIMIT, l, p, POWER_CHARGE) == (p >= l ? POWER_HOLD : POWER_CHARGE));
            assert(battery_decision(BAT_DISCHARGE, l, p, POWER_CHARGE) == (p > l ? POWER_DISCHARGE : p == l ? POWER_HOLD : POWER_CHARGE));
            assert(battery_decision(BAT_HOLD, l, p, POWER_HOLD) == (p < 20 ? POWER_CHARGE : POWER_HOLD));
        }
    }
    assert(battery_decision(BAT_LIMIT, 80, 79, POWER_HOLD) == POWER_HOLD);
    assert(battery_decision(BAT_LIMIT, 80, 78, POWER_HOLD) == POWER_CHARGE);
    assert(battery_decision(BAT_LIMIT, 101, 90, POWER_CHARGE) == POWER_SYSTEM);
    assert(battery_decision(BAT_DISCHARGE, 19, 21, POWER_DISCHARGE) == POWER_SYSTEM);
    assert(battery_decision(BAT_LIMIT, 80, -1, POWER_HOLD) == POWER_SYSTEM);
    assert(battery_decision(99, 80, 90, POWER_HOLD) == POWER_SYSTEM);

    reset_fixture(); assert(apply(POWER_HOLD)); assert(fakeCharge[0] == 1 && !fakeAdapter[0]);
    int before = writes; assert(apply(POWER_HOLD)); assert(writes == before); // no redundant writes
    assert(apply(POWER_DISCHARGE)); assert(fakeAdapter[0] == 8);
    writes = 0; assert(restore()); assert(adapterFirst); assert(!fakeCharge[0] && !fakeAdapter[0] && !owned);

    reset_fixture(); rejectAdapter = 1;
    assert(!apply(POWER_DISCHARGE)); assert(fakeCharge[0] == 1); // partial write
    rejectAdapter = 0; assert(restore()); assert(!fakeCharge[0] && !fakeAdapter[0]);

    reset_fixture(); assert(apply(POWER_DISCHARGE)); rejectCharge = 1;
    assert(!restore()); assert(!fakeAdapter[0]); assert(owned); // do not claim success
    rejectCharge = 0; assert(restore()); assert(!owned);

    reset_fixture(); hasAdapter = 0; assert(!apply(POWER_DISCHARGE)); assert(!owned);
    reset_fixture(); mode = BAT_DISCHARGE; assert(apply(POWER_DISCHARGE));
    power_event(NULL, 0, kIOMessageSystemWillSleep, NULL);
    assert(sleeping && mode == BAT_LIMIT && !owned && !fakeAdapter[0] && !fakeCharge[0]);
    power_event(NULL, 0, kIOMessageSystemHasPoweredOn, NULL); assert(!sleeping);
    reset_fixture(); chargeCount = 2;
    charge[0].name = "CH0B"; charge[0].meta.key = fourcc("CH0B"); charge[0].meta.info.size = 1;
    charge[1].name = "CH0C"; charge[1].meta.key = fourcc("CH0C"); charge[1].meta.info.size = 1;
    assert(apply(POWER_HOLD)); assert(fakeCharge[0] == 2 && fakeSecondCharge[0] == 2);
    assert(restore()); assert(!fakeCharge[0] && !fakeSecondCharge[0]);
    puts("Battery policy, readback, rollback, and sleep recovery passed (no hardware writes).");
}

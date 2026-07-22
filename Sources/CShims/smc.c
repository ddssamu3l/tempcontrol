#include "include/CShims.h"
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData_t;

static uint32_t str_to_key(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData_t), out, &outSize);
}

int smc_open(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? 0 : -1;
}

void smc_close(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

int smc_read_key(io_connect_t conn, const char *key, SMCVal_t *val) {
    SMCKeyData_t in;
    SMCKeyData_t out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    memset(val, 0, sizeof(SMCVal_t));

    in.key = str_to_key(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;

    val->dataSize = out.keyInfo.dataSize;
    val->dataType = out.keyInfo.dataType;
    if (val->dataSize > 32) return -1;

    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;

    memcpy(val->bytes, out.bytes, 32);
    return 0;
}

int smc_write_key(io_connect_t conn, const char *key, const SMCVal_t *val) {
    SMCKeyData_t in;
    SMCKeyData_t out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));

    in.key = str_to_key(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = val->dataSize;
    memcpy(in.bytes, val->bytes, 32);
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    return 0;
}

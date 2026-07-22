#ifndef CSHIMS_H
#define CSHIMS_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// ---------------------------------------------------------------------------
// Private IOHID sensor API.
// Apple Silicon exposes its ~20 die temperature sensors through the HID event
// system (usage page 0xff00, usage 5), not through classic SMC temp keys.
// These functions live in IOKit.framework but have no public headers, so we
// declare them ourselves. Every serious Mac monitoring app does exactly this.
// ---------------------------------------------------------------------------

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

CF_RETURNS_RETAINED IOHIDEventSystemClientRef _Nullable
IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator);

int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client,
                                      CFDictionaryRef _Nonnull match);

CF_RETURNS_RETAINED CFArrayRef _Nullable
IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef _Nonnull client);

CF_RETURNS_RETAINED CFTypeRef _Nullable
IOHIDServiceClientCopyProperty(IOHIDServiceClientRef _Nonnull service,
                               CFStringRef _Nonnull property);

CF_RETURNS_RETAINED IOHIDEventRef _Nullable
IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service,
                            int64_t type, int32_t options, int64_t timestamp);

double IOHIDEventGetFloatValue(IOHIDEventRef _Nonnull event, int32_t field);

#define kShimHIDEventTypeTemperature 15
#define kShimHIDTemperatureField (15 << 16)
#define kShimHIDVendorTempUsagePage 0xff00
#define kShimHIDVendorTempUsage 5

// ---------------------------------------------------------------------------
// SMC user client (AppleSMC). Reads work unprivileged; writes (fan control)
// require root. Struct layout is the long-established one from smcFanControl.
// ---------------------------------------------------------------------------

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;   // fourcc, e.g. 'flt ' or 'ui8 '
    uint8_t  bytes[32];
} SMCVal_t;

int smc_open(io_connect_t * _Nonnull conn);
void smc_close(io_connect_t conn);
int smc_read_key(io_connect_t conn, const char * _Nonnull key, SMCVal_t * _Nonnull val);
int smc_write_key(io_connect_t conn, const char * _Nonnull key, const SMCVal_t * _Nonnull val);

#endif

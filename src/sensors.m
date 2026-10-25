// OmniStats sensor implementation (Apple Silicon).
#import <CoreFoundation/CoreFoundation.h>
#import "sensors.h"
#import <stdlib.h>
#import "smc.h"

// ---- Private IOHIDEventSystemClient temperature API (undocumented, stable since M1) ----
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
#define kHIDTemperature 15
#define HIDFieldBase(t) ((t) << 16)
#define kHIDPageAppleVendor 0xff00
#define kHIDUsageTempSensor 5

static IOHIDEventSystemClientRef gHID = NULL;
static CFArrayRef gServices = NULL;

// cached snapshot
static float gSocMax, gSocAvg, gSsd, gBattery, gPower, gVolt;
static int   gFanCount = 0;
static float gFanRpm[8], gFanMin[8], gFanMax[8];
static int   gFanMode[8];

static CFDictionaryRef tempMatching(void){
    int pg=kHIDPageAppleVendor, us=kHIDUsageTempSensor;
    CFNumberRef p=CFNumberCreate(0,kCFNumberIntType,&pg), u=CFNumberCreate(0,kCFNumberIntType,&us);
    const void *k[]={CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")}, *v[]={p,u};
    CFDictionaryRef d=CFDictionaryCreate(0,k,v,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFRelease(p); CFRelease(u); return d;
}

enum SensorKind { Skip, Battery, SSD, SoC, Other };
static unsigned char *gKinds = NULL;
static double gBoundsTime = 0;

static int nameHas(CFStringRef name, CFStringRef part) {
    return name && CFStringFind(name, part, kCFCompareCaseInsensitive).location != kCFNotFound;
}

static unsigned char classify(CFStringRef name) {
    if(nameHas(name, CFSTR("battery"))) return Battery;
    if(nameHas(name, CFSTR("NAND")) || nameHas(name, CFSTR("SSD"))) return SSD;
    if(nameHas(name, CFSTR("tcal")) || nameHas(name, CFSTR("tdev"))) return Skip;
    if(nameHas(name, CFSTR("tdie")) || nameHas(name, CFSTR("SOC")) ||
       nameHas(name, CFSTR("CPU")) || nameHas(name, CFSTR("GPU"))) return SoC;
    return Other;
}

void cb_sensors_init(void) {
    smcOpen();
    if(!gHID) gHID = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if(gServices) { CFRelease(gServices); gServices = NULL; }
    free(gKinds); gKinds = NULL;
    if(gHID) {
        CFDictionaryRef matching = tempMatching();
        IOHIDEventSystemClientSetMatching(gHID, matching);
        gServices = IOHIDEventSystemClientCopyServices(gHID);
        CFRelease(matching);
    }
    long count = gServices ? CFArrayGetCount(gServices) : 0;
    if(count > 0) gKinds = calloc((size_t)count, 1);
    for(long i = 0; gKinds && i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, i);
        CFTypeRef property = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        CFStringRef name = property && CFGetTypeID(property) == CFStringGetTypeID() ? (CFStringRef)property : NULL;
        gKinds[i] = classify(name);
        if(property) CFRelease(property);
    }
    int fn = smcReadU8("FNum");
    gFanCount = fn > 0 && fn <= 8 ? fn : 0;
    for(int i = 0; i < 8; i++) gFanMin[i] = gFanMax[i] = NAN;
    gBoundsTime = 0;
}

static float temperature(long index) {
    IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices, index);
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kHIDTemperature, 0, 0);
    if(!event) return NAN;
    double value = IOHIDEventGetFloatValue(event, HIDFieldBase(kHIDTemperature));
    CFRelease(event);
    return isfinite(value) && value > -20 && value < 150 ? (float)value : NAN;
}

void cb_refresh(void) {
    float sum = 0, maximum = NAN, ssd = NAN, battery = NAN;
    int samples = 0;
    long count = gServices && gKinds ? CFArrayGetCount(gServices) : 0;
    // Classification is immutable until rediscovery. Calibration and unrelated
    // sensors no longer incur an IPC round trip on every sample.
    for(long i = 0; i < count; i++) {
        unsigned char kind = gKinds[i];
        if(kind == Skip || kind == Other) continue;
        float value = temperature(i);
        if(!isfinite(value)) continue;
        if(kind == Battery) battery = value;
        else if(kind == SSD) { if(isnan(ssd) || value > ssd) ssd = value; }
        else { if(isnan(maximum) || value > maximum) maximum = value; sum += value; samples++; }
    }
    if(samples == 0) {
        for(long i = 0; i < count; i++) {
            if(gKinds[i] != Other) continue;
            float value = temperature(i);
            if(value > 10 && value < 120) {
                if(isnan(maximum) || value > maximum) maximum = value;
                sum += value; samples++;
            }
        }
    }
    gSocMax = maximum; gSocAvg = samples ? sum / samples : NAN;
    gSsd = ssd; gBattery = battery;
    gPower = smcReadFloat("PSTR"); gVolt = smcReadFloat("VP0R");
    double now = CFAbsoluteTimeGetCurrent();
    int readBounds = gBoundsTime == 0 || now - gBoundsTime >= 60 || now < gBoundsTime;
    for(int i = 0; i < gFanCount; i++) {
        char actual[8], minimum[8], maximumKey[8], mode[8];
        smcFanKey(actual, i, "Ac"); smcFanKey(minimum, i, "Mn");
        smcFanKey(maximumKey, i, "Mx"); smcFanModeKey(mode, i);
        gFanRpm[i] = smcReadFloat(actual); gFanMode[i] = smcReadU8(mode);
        if(readBounds || !isfinite(gFanMin[i]) || !isfinite(gFanMax[i])) {
            gFanMin[i] = smcReadFloat(minimum); gFanMax[i] = smcReadFloat(maximumKey);
        }
    }
    if(readBounds) gBoundsTime = now;
}

float cb_soc_max(void){ return gSocMax; }
float cb_soc_avg(void){ return gSocAvg; }
float cb_ssd(void){ return gSsd; }
float cb_battery(void){ return gBattery; }
float cb_power(void){ return gPower; }
float cb_volt(void){ return gVolt; }
int   cb_fan_count(void){ return gFanCount; }
float cb_fan_rpm(int i){ return (i>=0&&i<gFanCount)?gFanRpm[i]:NAN; }
float cb_fan_min(int i){ return (i>=0&&i<gFanCount)?gFanMin[i]:NAN; }
float cb_fan_max(int i){ return (i>=0&&i<gFanCount)?gFanMax[i]:NAN; }
int   cb_fan_mode(int i){ return (i>=0&&i<gFanCount)?gFanMode[i]:-1; }

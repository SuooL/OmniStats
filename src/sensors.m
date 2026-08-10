// OmniStats sensor implementation (Apple Silicon).
#import <CoreFoundation/CoreFoundation.h>
#import "sensors.h"
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

void cb_sensors_init(void){
    smcOpen();
    gHID = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if(gHID){
        CFDictionaryRef m = tempMatching();
        IOHIDEventSystemClientSetMatching(gHID, m);
        gServices = IOHIDEventSystemClientCopyServices(gHID);
        CFRelease(m);
    }
    int fn = smcReadU8("FNum");
    gFanCount = (fn>0 && fn<=8) ? fn : 0;
}

static int nameHas(CFStringRef s, const char *sub){
    if(!s) return 0;
    CFStringRef q = CFStringCreateWithCString(0, sub, kCFStringEncodingUTF8);
    Boolean r = CFStringFind(s, q, kCFCompareCaseInsensitive).location != kCFNotFound;
    CFRelease(q); return r;
}

void cb_refresh(void){
    // --- temperatures ---
    float socSum=0; int socN=0; float socMax=NAN, ssd=NAN, batt=NAN;
    long n = gServices ? CFArrayGetCount(gServices) : 0;
    for(long i=0;i<n;i++){
        IOHIDServiceClientRef sc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices,i);
        CFStringRef nm = (CFStringRef)IOHIDServiceClientCopyProperty(sc, CFSTR("Product"));
        IOHIDEventRef e = IOHIDServiceClientCopyEvent(sc, kHIDTemperature, 0, 0);
        if(e){
            double c = IOHIDEventGetFloatValue(e, HIDFieldBase(kHIDTemperature));
            if(nm && c>-20 && c<150){
                if(nameHas(nm,"battery")) batt = c;
                else if(nameHas(nm,"NAND") || nameHas(nm,"SSD")){ if(isnan(ssd)||c>ssd) ssd=c; }
                else if(nameHas(nm,"tcal") || nameHas(nm,"tdev")) { /* calibration/inactive: skip */ }
                else if(nameHas(nm,"tdie") || nameHas(nm,"SOC") || nameHas(nm,"CPU") || nameHas(nm,"GPU")){
                    if(isnan(socMax)||c>socMax) socMax=c; socSum+=c; socN++;
                }
            }
            CFRelease(e);
        }
        if(nm) CFRelease(nm);
    }
    // Fallback for models whose die sensors are named differently: use any plausible
    // core temperature (10–120°C, excluding battery/ssd) so SoC is never empty.
    if(socN==0){
        for(long i=0;i<n;i++){
            IOHIDServiceClientRef sc=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(gServices,i);
            CFStringRef nm=(CFStringRef)IOHIDServiceClientCopyProperty(sc,CFSTR("Product"));
            IOHIDEventRef e=IOHIDServiceClientCopyEvent(sc,kHIDTemperature,0,0);
            if(e){ double c=IOHIDEventGetFloatValue(e,HIDFieldBase(kHIDTemperature));
                if(c>10&&c<120&&!nameHas(nm,"battery")&&!nameHas(nm,"NAND")&&!nameHas(nm,"tcal")&&!nameHas(nm,"tdev")){
                    if(isnan(socMax)||c>socMax) socMax=c; socSum+=c; socN++; }
                CFRelease(e); }
            if(nm) CFRelease(nm);
        }
    }
    gSocMax = socMax; gSocAvg = socN? socSum/socN : NAN; gSsd = ssd; gBattery = batt;

    // --- power / voltage ---
    gPower = smcReadFloat("PSTR");
    gVolt  = smcReadFloat("VP0R");

    // --- fans ---
    for(int i=0;i<gFanCount;i++){
        char a[8],mn[8],mx[8],md[8];
        smcFanKey(a,i,"Ac"); smcFanKey(mn,i,"Mn"); smcFanKey(mx,i,"Mx"); smcFanModeKey(md,i);
        gFanRpm[i]=smcReadFloat(a); gFanMin[i]=smcReadFloat(mn);
        gFanMax[i]=smcReadFloat(mx); gFanMode[i]=smcReadU8(md);
    }
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

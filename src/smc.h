// Shared AppleSMC access for OmniStats (Apple Silicon).
// Reads work unprivileged; writes require root. Handles fan-mode key case
// differences across models (older Macs use "F%dMd", M-series use "F%dmd").
#ifndef COOLBAR_SMC_H
#define COOLBAR_SMC_H
#import <IOKit/IOKitLib.h>
#import <string.h>
#import <math.h>
#import <stdio.h>

typedef struct { char a,b,c,r[1]; unsigned short rel; } SMCVers;
typedef struct { unsigned short v,l; unsigned int a,b,c; } SMCPLim;
typedef struct { unsigned int sz,ty; char at; } SMCKI;
typedef struct { unsigned int key; SMCVers vs; SMCPLim pl; SMCKI ki;
                 char res,st,d8; unsigned int d32; char by[32]; } SMCData;
enum { kSMCRead=5, kSMCWrite=6, kSMCReadIndex=8, kSMCInfo=9 };

static io_connect_t gSMC = 0;
static char gModeCase = 0;   // 'm' (F0md) or 'M' (F0Md); 0 = not yet probed

static inline int smcOpen(void){
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if(!s) return -1;
    return (IOServiceOpen(s, mach_task_self(), 0, &gSMC) == KERN_SUCCESS) ? 0 : -1;
}
static inline unsigned int smcFourcc(const char *s){
    return (s[0]<<24)|(s[1]<<16)|(s[2]<<8)|(unsigned char)s[3];
}
static inline kern_return_t smcCall(SMCData *i, SMCData *o){
    size_t s=sizeof(SMCData); return IOConnectCallStructMethod(gSMC, 2, i, sizeof(SMCData), o, &s);
}
static inline int smcInfo(const char *key, unsigned int *sz, unsigned int *ty){
    SMCData i={0},o={0}; i.key=smcFourcc(key); i.d8=kSMCInfo;
    if(smcCall(&i,&o)||o.res) return -1;
    if(sz)*sz=o.ki.sz; if(ty)*ty=o.ki.ty; return 0;
}
static inline int smcReadBytes(const char *key, unsigned char *buf, unsigned int *outsz, unsigned int *ty){
    unsigned int sz,t; if(smcInfo(key,&sz,&t)) return -1;
    SMCData i={0},o={0}; i.key=smcFourcc(key); i.ki.sz=sz; i.d8=kSMCRead;
    if(smcCall(&i,&o)||o.res) return -1;
    if(sz>32) sz=32; memcpy(buf,o.by,sz); if(outsz)*outsz=sz; if(ty)*ty=t; return (int)sz;
}
static inline float smcReadFloat(const char *key){
    unsigned char b[32]; unsigned int sz,ty; if(smcReadBytes(key,b,&sz,&ty)<0) return NAN;
    char t[5]={ty>>24,ty>>16,ty>>8,ty,0};
    if(strcmp(t,"flt ")==0){ float f; memcpy(&f,b,4); return f; }
    if(strcmp(t,"fpe2")==0) return ((b[0]<<8)|b[1])/4.0f;
    if(strcmp(t,"ui16")==0) return (float)((b[0]<<8)|b[1]);
    if(strcmp(t,"ui8 ")==0) return (float)b[0];
    return NAN;
}
static inline int smcReadU8(const char *key){
    unsigned char b[32]; unsigned int sz,ty; if(smcReadBytes(key,b,&sz,&ty)<0) return -1; return b[0];
}
static inline int smcWriteFloat(const char *key, float v){
    unsigned int sz,ty; if(smcInfo(key,&sz,&ty)) return -1;
    SMCData i={0},o={0}; i.key=smcFourcc(key); i.ki.sz=sz; i.d8=kSMCWrite; memcpy(i.by,&v,4);
    if(smcCall(&i,&o)) return -2; if(o.res) return -3; return 0;
}
static inline int smcWriteU8(const char *key, unsigned char v){
    unsigned int sz,ty; if(smcInfo(key,&sz,&ty)) return -1;
    SMCData i={0},o={0}; i.key=smcFourcc(key); i.ki.sz=sz; i.d8=kSMCWrite; i.by[0]=v;
    if(smcCall(&i,&o)) return -2; if(o.res) return -3; return 0;
}
// Build fan sub-keys. Mode key case is probed once and cached.
static inline void smcFanKey(char out[8], int fan, const char *suffix){
    snprintf(out, 8, "F%d%s", fan, suffix);
}
static inline void smcFanModeKey(char out[8], int fan){
    if(!gModeCase){
        char a[8],b[8]; unsigned int sz,ty;
        snprintf(a,8,"F%dmd",fan); snprintf(b,8,"F%dMd",fan);
        if(smcInfo(a,&sz,&ty)==0) gModeCase='m';
        else if(smcInfo(b,&sz,&ty)==0) gModeCase='M';
        else gModeCase='m';
    }
    snprintf(out, 8, "F%d%cd", fan, gModeCase);
}
#endif

// omnistats-smcd — privileged fan-control helper (runs as root via LaunchDaemon).
//
// Protocol (newline-terminated) over unix socket /var/run/omnistats.sock:
//   PING            -> OK
//   INFO            -> "fanN min max actual target mode" lines, then END
//   SET <n> <rpm>   -> manual mode fan n at clamped rpm  -> OK <applied>
//   AUTO <n>        -> fan n back to firmware auto        -> OK
//   AUTOALL         -> all fans auto                      -> OK
//   HB              -> heartbeat (resets watchdog)        -> OK
//
// Safety:
//   * rpm is clamped to [F{n}Mn, F{n}Mx] — never outside firmware limits.
//   * peer uid is verified: only root or the active console user may connect,
//     preventing other local users from hijacking fan control.
//   * watchdog reverts every fan to auto if no heartbeat arrives within
//     WATCHDOG_SEC while any fan is manual (covers a crashed/killed GUI).
//   * client disconnect and SIGTERM/SIGINT also revert to auto.
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/ucred.h>
#import <unistd.h>
#import <signal.h>
#import <time.h>
#import "smc.h"

#define SOCK_PATH "/var/run/omnistats.sock"
#define WATCHDOG_SEC 12
#define MAX_FANS 8

static int gFanCount = 0;
static int gManual[MAX_FANS] = {0};

static void autoFan(int n){ char k[8]; smcFanModeKey(k,n); smcWriteU8(k,0); gManual[n]=0; }
static void autoAll(void){ for(int i=0;i<gFanCount;i++) autoFan(i); }
static int  anyManual(void){ for(int i=0;i<gFanCount;i++) if(gManual[i]) return 1; return 0; }

static int setFan(int n, float rpm){
    if(n<0||n>=gFanCount) return -1;
    char kmn[8],kmx[8],kmd[8],ktg[8];
    smcFanKey(kmn,n,"Mn"); smcFanKey(kmx,n,"Mx"); smcFanModeKey(kmd,n); smcFanKey(ktg,n,"Tg");
    float mn=smcReadFloat(kmn), mx=smcReadFloat(kmx);
    if(!isnan(mn) && rpm<mn) rpm=mn;
    if(!isnan(mx) && rpm>mx) rpm=mx;
    if(smcWriteU8(kmd,1)!=0) return -2;
    if(smcWriteFloat(ktg,rpm)!=0){ smcWriteU8(kmd,0); return -3; }
    gManual[n]=1;
    return (int)rpm;
}

// Owner of /dev/console == the user currently logged in at the GUI.
static uid_t consoleUser(void){ struct stat st; if(stat("/dev/console",&st)==0) return st.st_uid; return (uid_t)-1; }

static int peerAllowed(int fd){
    uid_t euid; gid_t egid;
    if(getpeereid(fd, &euid, &egid) != 0) return 0;
    if(euid == 0) return 1;
    uid_t cu = consoleUser();
    return (cu != (uid_t)-1 && euid == cu);
}

static volatile sig_atomic_t gStop = 0;
static void onSignal(int s){ (void)s; gStop=1; }

static void handleLine(int fd, char *line){
    char reply[512]; reply[0]=0;
    if(strncmp(line,"PING",4)==0) strcpy(reply,"OK\n");
    else if(strncmp(line,"HB",2)==0) strcpy(reply,"OK\n");
    else if(strncmp(line,"AUTOALL",7)==0){ autoAll(); strcpy(reply,"OK\n"); }
    else if(strncmp(line,"AUTO",4)==0){ int n=-1; sscanf(line+4,"%d",&n);
        if(n>=0&&n<gFanCount){ autoFan(n); strcpy(reply,"OK\n"); } else strcpy(reply,"ERR fan\n"); }
    else if(strncmp(line,"SET",3)==0){ int n=-1; float r=0;
        if(sscanf(line+3,"%d %f",&n,&r)==2){ int got=setFan(n,r);
            if(got<0) snprintf(reply,sizeof(reply),"ERR %d\n",got); else snprintf(reply,sizeof(reply),"OK %d\n",got); }
        else strcpy(reply,"ERR parse\n"); }
    else if(strncmp(line,"INFO",4)==0){ char *p=reply;
        for(int i=0;i<gFanCount;i++){ char a[8],mn[8],mx[8],tg[8],md[8];
            smcFanKey(a,i,"Ac"); smcFanKey(mn,i,"Mn"); smcFanKey(mx,i,"Mx"); smcFanKey(tg,i,"Tg"); smcFanModeKey(md,i);
            p+=snprintf(p, sizeof(reply)-(p-reply), "fan%d %.0f %.0f %.0f %.0f %d\n",
                        i, smcReadFloat(mn), smcReadFloat(mx), smcReadFloat(a), smcReadFloat(tg), smcReadU8(md)); }
        snprintf(p, sizeof(reply)-(p-reply), "END\n"); }
    else strcpy(reply,"ERR unknown\n");
    if(reply[0]) write(fd, reply, strlen(reply));
}

int main(void){
    if(geteuid()!=0){ fprintf(stderr,"omnistats-smcd must run as root\n"); return 1; }
    if(smcOpen()!=0){ fprintf(stderr,"cannot open AppleSMC\n"); return 1; }
    int fn=smcReadU8("FNum"); gFanCount = (fn>0&&fn<=MAX_FANS)? fn : 0;

    signal(SIGTERM,onSignal); signal(SIGINT,onSignal); signal(SIGPIPE,SIG_IGN);

    unlink(SOCK_PATH);
    int srv=socket(AF_UNIX,SOCK_STREAM,0);
    struct sockaddr_un addr={0}; addr.sun_family=AF_UNIX; strncpy(addr.sun_path,SOCK_PATH,sizeof(addr.sun_path)-1);
    if(bind(srv,(struct sockaddr*)&addr,sizeof(addr))<0){ perror("bind"); return 1; }
    chmod(SOCK_PATH, 0666);   // peer-uid check is the real gate; see peerAllowed()
    listen(srv,4);
    fprintf(stderr,"omnistats-smcd up: %d fan(s), socket %s\n", gFanCount, SOCK_PATH);

    while(!gStop){
        fd_set rs; FD_ZERO(&rs); FD_SET(srv,&rs);
        struct timeval tv={1,0};
        if(select(srv+1,&rs,NULL,NULL,&tv)<=0){ if(gStop) break; continue; }
        int cli=accept(srv,NULL,NULL);
        if(cli<0) continue;
        if(!peerAllowed(cli)){ const char *m="ERR forbidden\n"; write(cli,m,strlen(m)); close(cli); continue; }

        struct timeval rto={2,0}; setsockopt(cli,SOL_SOCKET,SO_RCVTIMEO,&rto,sizeof(rto));
        time_t lastHB=time(NULL);
        char buf[1024]; int used=0;
        while(!gStop){
            char tmp[512];
            ssize_t k=recv(cli,tmp,sizeof(tmp),0);
            if(k>0){
                lastHB=time(NULL);
                if(used+k>=(int)sizeof(buf)) used=0;
                memcpy(buf+used,tmp,k); used+=k; buf[used]=0;
                char *nl;
                while((nl=strchr(buf,'\n'))){
                    *nl=0; if(nl>buf) handleLine(cli,buf);
                    int consumed=(int)(nl-buf)+1; memmove(buf,nl+1,used-consumed+1); used-=consumed;
                }
            } else if(k==0) break;
            else if(anyManual() && time(NULL)-lastHB > WATCHDOG_SEC){
                fprintf(stderr,"watchdog: no heartbeat, reverting to auto\n"); autoAll();
            }
        }
        close(cli);
        autoAll();
    }
    autoAll(); unlink(SOCK_PATH);
    fprintf(stderr,"omnistats-smcd exiting, fans reverted to auto\n");
    return 0;
}

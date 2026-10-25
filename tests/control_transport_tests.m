#import <Foundation/Foundation.h>
#import <assert.h>
#import <pthread.h>
static char testSocketPath[104];
#define OMNISTATS_SOCKET_PATH testSocketPath
#include "../src/control.m"
static int listener;
static void *serve(void *context) {
    int mode = (int)(intptr_t)context;
    for(int i=0;i<(mode==0?2:1);i++) {
        int client=accept(listener,NULL,NULL); assert(client>=0);
        char command[64]; assert(read(client,command,sizeof(command))>0);
        if(mode==0) {
            assert(write(client,"O",1)==1); usleep(10000);
            assert(write(client,"K\n",2)==2);
        } else { usleep(900000); }
        close(client);
    }
    return NULL;
}
static void startServer(void) {
    listener=socket(AF_UNIX,SOCK_STREAM,0); assert(listener>=0);
    struct sockaddr_un address={0}; address.sun_family=AF_UNIX;
    strncpy(address.sun_path,testSocketPath,sizeof(address.sun_path)-1);
    assert(bind(listener,(struct sockaddr *)&address,sizeof(address))==0);
    assert(listen(listener,4)==0);
}
int main(void) {
    snprintf(testSocketPath,sizeof(testSocketPath),"/tmp/omnistats-control-test-%d.sock",getpid());
    startServer(); pthread_t thread; assert(pthread_create(&thread,NULL,serve,(void *)0)==0);
    assert(cb_ctl_available()==1); // Fragmented response must wait for newline.
    uint64_t first=cb_ctl_connection_id();
    assert(cb_ctl_available()==1); // EOF/closed peer must reconnect without SIGPIPE.
    assert(cb_ctl_connection_id()>first);
    pthread_join(thread,NULL); cb_ctl_disconnect(); close(listener); unlink(testSocketPath);
    startServer(); assert(pthread_create(&thread,NULL,serve,(void *)1)==0);
    double start=monotonic(); assert(cb_ctl_available()==0);
    assert(monotonic()-start<1.0); // Total deadline must bound all retries.
    pthread_join(thread,NULL); cb_ctl_disconnect(); close(listener); unlink(testSocketPath);
    puts("PASS: fragmented replies, reconnect, SIGPIPE suppression and bounded timeouts");
    return 0;
}

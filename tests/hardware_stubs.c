// Mock hardware only: these tests never open SMC or the installed helper socket.
#include "sensors.h"
#include "control.h"
#include "hardware_stubs.h"
#include <stdatomic.h>
#include <unistd.h>
#include <stdio.h>
static atomic_int available, failure, delay, sets, heartbeats, autos;
static atomic_uint_fast64_t connection = 1;
void cb_test_reset(void) { available=0; failure=0; delay=0; sets=0; heartbeats=0; autos=0; connection=1; }
void cb_test_available(int v) { available=v; }
void cb_test_fail_set(int v) { failure=v; }
void cb_test_sensor_delay(int v) { delay=v; }
void cb_test_reconnect(void) { connection++; }
int cb_test_sets(void) { return sets; }
int cb_test_heartbeats(void) { return heartbeats; }
int cb_test_autos(void) { return autos; }
void cb_sensors_init(void) {}
void cb_refresh(void) { if(delay>0) usleep((useconds_t)delay*1000); }
float cb_soc_max(void) { return 50; }
float cb_soc_avg(void) { return 45; }
float cb_ssd(void) { return 40; }
float cb_battery(void) { return 32; }
float cb_power(void) { return 20; }
float cb_volt(void) { return 12; }
int cb_fan_count(void) { return 2; }
float cb_fan_rpm(int i) { return 1500; }
float cb_fan_min(int i) { return 1200; }
float cb_fan_max(int i) { return 6000; }
int cb_fan_mode(int i) { return 0; }
int cb_ctl_available(void) { return available; }
int cb_ctl_set(int fan, int rpm) { sets++; return available && !failure ? rpm : -1; }
int cb_ctl_auto(int fan) { autos++; return available ? 0 : -1; }
int cb_ctl_auto_all(void) { autos++; return available ? 0 : -1; }
int cb_ctl_heartbeat(void) { heartbeats++; return available && !failure ? 0 : -1; }
int cb_ctl_version(void) { return 2; }
void cb_ctl_disconnect(void) { connection++; }
uint64_t cb_ctl_connection_id(void) { return connection; }
int cb_ctl_command(const char *command, char *reply, int capacity) {
    (void)command;
    if(!available || capacity < 2) return -1;
    snprintf(reply, (size_t)capacity, "OK backend=chte enabled=0 limit=80 sailing=5 sleepstop=0 stayawake=0 "
             "heat=0 heatlimit=40 led=0 topup=0 inhibited=0 heatheld=0 percent=85 external=1 charging=0 "
             "temp=3050 ledsupported=1 conflict=- writefailed=0");
    return 0;
}

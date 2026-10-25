// Runtime UI tests must never connect to the fan-control helper or write SMC.
#include "sensors.h"
#include "control.h"

void cb_sensors_init(void) {}
void cb_refresh(void) {}
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
int cb_ctl_available(void) { return 0; }
int cb_ctl_set(int fan, int rpm) { return -1; }
int cb_ctl_auto(int fan) { return -1; }
int cb_ctl_auto_all(void) { return -1; }
void cb_ctl_heartbeat(void) {}

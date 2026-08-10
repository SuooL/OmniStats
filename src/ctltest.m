// Simulate the GUI: set a fan via the persistent control connection, hold it,
// and watch actual RPM. Verifies the short-connection revert bug is fixed.
#import <Foundation/Foundation.h>
#import <unistd.h>
#import "sensors.h"
#import "control.h"
int main(){
    cb_sensors_init();
    if(!cb_ctl_available()){ printf("helper NOT available\n"); return 1; }
    printf("helper available. Setting fan0 -> 3500 rpm and holding...\n");
    int applied = cb_ctl_set(0, 3500);
    printf("cb_ctl_set returned %d\n", applied);
    for(int t=1;t<=6;t++){
        sleep(1);
        cb_ctl_heartbeat();          // keep watchdog happy
        cb_refresh();
        printf("  t=%ds  fan0 actual=%.0f  mode=%d\n", t, cb_fan_rpm(0), cb_fan_mode(0));
    }
    printf("reverting to auto...\n");
    cb_ctl_auto(0);
    sleep(1); cb_refresh();
    printf("  after auto: fan0 actual=%.0f mode=%d\n", cb_fan_rpm(0), cb_fan_mode(0));
    return 0;
}

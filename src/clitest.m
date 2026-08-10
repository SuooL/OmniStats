// Standalone smoke test for the sensor + control C layer (no GUI).
#import <Foundation/Foundation.h>
#import "sensors.h"
#import "control.h"
int main(){
    cb_sensors_init();
    cb_refresh();
    printf("SoC max=%.1f avg=%.1f  SSD=%.1f  Batt=%.1f  Power=%.1fW  Volt=%.2fV\n",
           cb_soc_max(), cb_soc_avg(), cb_ssd(), cb_battery(), cb_power(), cb_volt());
    int n=cb_fan_count(); printf("Fans: %d\n", n);
    for(int i=0;i<n;i++)
        printf("  fan%d rpm=%.0f min=%.0f max=%.0f mode=%d\n",
               i, cb_fan_rpm(i), cb_fan_min(i), cb_fan_max(i), cb_fan_mode(i));
    printf("Helper available: %s\n", cb_ctl_available()? "YES":"NO (control disabled)");
    return 0;
}

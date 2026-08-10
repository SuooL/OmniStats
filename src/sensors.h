// OmniStats sensor layer — clean C API consumed by the SwiftUI app.
// Temperatures via private IOHIDEventSystemClient; fans/power via AppleSMC.
#ifndef COOLBAR_SENSORS_H
#define COOLBAR_SENSORS_H

void  cb_sensors_init(void);   // open SMC + HID client once
void  cb_refresh(void);        // sample all sensors into internal state

// Temperatures (°C); NAN when unavailable on this model.
float cb_soc_max(void);        // hottest SoC die sensor
float cb_soc_avg(void);        // mean of SoC die sensors
float cb_ssd(void);            // NAND/SSD
float cb_battery(void);

// Power / voltage; NAN when unavailable.
float cb_power(void);          // total system power (W)
float cb_volt(void);           // main rail voltage (V)

// Fans
int   cb_fan_count(void);
float cb_fan_rpm(int i);
float cb_fan_min(int i);
float cb_fan_max(int i);
int   cb_fan_mode(int i);      // 0 = firmware auto, 1 = manual

#endif

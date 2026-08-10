// OmniStats control client — talks to the privileged omnistats-smcd helper.
#ifndef COOLBAR_CONTROL_H
#define COOLBAR_CONTROL_H

int  cb_ctl_available(void);        // 1 if helper socket is reachable
int  cb_ctl_set(int fan, int rpm);  // manual fan speed; returns applied rpm, or <0 on error
int  cb_ctl_auto(int fan);          // fan back to firmware auto
int  cb_ctl_auto_all(void);
void cb_ctl_heartbeat(void);        // keep watchdog alive while any fan is manual

#endif

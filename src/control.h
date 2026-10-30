// OmniStats control client — talks to the privileged omnistats-smcd helper.
#ifndef COOLBAR_CONTROL_H
#define COOLBAR_CONTROL_H
#include <stdint.h>

int  cb_ctl_available(void);        // 1 if helper socket is reachable
int  cb_ctl_set(int fan, int rpm);  // manual fan speed; returns applied rpm, or <0 on error
int  cb_ctl_auto(int fan);          // fan back to firmware auto
int  cb_ctl_auto_all(void);
int  cb_ctl_heartbeat(void);        // 0 on success; keep watchdog alive in manual mode
int  cb_ctl_version(void);          // protocol version; 0 for legacy/unknown helpers
void cb_ctl_disconnect(void);       // drop connection and cached helper version
uint64_t cb_ctl_connection_id(void); // changes on every successful connection
int  cb_ctl_command(const char *command, char *reply, int capacity); // one-line request without '\n'; 0 on success

#endif

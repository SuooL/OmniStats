// Bridging header exposing OmniStats's C sensor + control APIs to Swift.
#import "sensors.h"
#import "control.h"

// System APIs used directly from Swift:
//   getifaddrs / if_data (per-interface byte counters) for network speed,
//   libproc (proc_listpids / proc_pid_rusage / proc_pidpath) for per-process CPU.
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/resource.h>

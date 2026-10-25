#!/usr/bin/env python3
"""Read-only sensor benchmark; never loads or calls the fan-control layer."""
import pathlib
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
BASELINE = sys.argv[1] if len(sys.argv) > 1 else "v1.3.4"
PROBE = r'''
#include "sensors.h"
#include <sys/resource.h>
#include <time.h>
#include <stdio.h>
static double wall(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static double cpu(void) {
    struct rusage r; getrusage(RUSAGE_SELF, &r);
    return r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6
         + r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6;
}
int main(void) {
    cb_sensors_init(); cb_refresh();
    double w = wall(), c = cpu();
    for (int i = 0; i < 30; i++) cb_refresh();
    printf("wall_ms=%.3f cpu_ms=%.3f soc_max=%.1f ssd=%.1f fans=%d\n",
           (wall()-w)*1000/30, (cpu()-c)*1000/30,
           cb_soc_max(), cb_ssd(), cb_fan_count());
}
'''

with tempfile.TemporaryDirectory(prefix="omnistats-sensor-bench-") as temporary:
    root = pathlib.Path(temporary)
    for label in ("baseline", "optimized"):
        directory = root / label
        directory.mkdir()
        for name in ("sensors.m", "sensors.h", "smc.h"):
            source = subprocess.check_output(
                ["git", "show", BASELINE + ":src/" + name], cwd=REPO
            ) if label == "baseline" else (REPO / "src" / name).read_bytes()
            (directory / name).write_bytes(source)
        (directory / "probe.m").write_text(PROBE)
        subprocess.run([
            "clang", "-O2", "-fobjc-arc", str(directory / "probe.m"),
            str(directory / "sensors.m"), "-framework", "Foundation",
            "-framework", "IOKit", "-framework", "CoreFoundation",
            "-o", str(directory / "probe"),
        ], check=True)
    for cycle in range(3):
        for label in ("baseline", "optimized"):
            result = subprocess.check_output([str(root / label / "probe")], text=True)
            print(label, cycle + 1, result.strip(), flush=True)

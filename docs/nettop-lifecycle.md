# nettop CPU and process lifetime

## Reproduction (2026-10-25)

On macOS 26.5.1 / Apple Silicon, two orphaned nettop processes (parent PID 1)
consumed about 140–146% CPU each. Their start times matched earlier crashed
runtime-test sessions; this provenance is inferred, not proven from historical
parent records. Both identified orphans were terminated before testing the fix.

A controlled seven-second comparison used the same PTY output and arguments
(-n -P -x -l 0 -s 3 -J bytes_in,bytes_out), draining stdout continuously:

| stdin | Measured child CPU |
| --- | ---: |
| /dev/null (persistent EOF) | 142.28% |
| Open pipe, no input | 1.49% |

These are short local measurements, not a battery-life guarantee or a claim
about every macOS version. Samples showed repeated kevent/libdispatch handling.
The result isolates input EOF as the trigger on this machine; increasing the
three-second display interval alone does not correct this event-loop problem.

## Implementation

The app launches the bundled, unprivileged omnistats-nettop executable. It starts
nettop with a private stdin pipe and retains the write end without writing data.
The app continues to parse PTY output, retaining the existing cadence, bounded
buffers and generation checks. A missing runner fails to Unavailable.

The runner blocks in kqueue, watching the app and nettop exit events plus
termination signals. It does not poll or introduce periodic wakeups. App crash,
force quit, normal panel closure and reader exit trigger cleanup. Cleanup sends
SIGTERM, waits at most one second, then uses SIGKILL if necessary and reaps the
child. Termination signals are blocked while their event filters are installed;
nettop receives default handlers and an empty signal mask. Parent registration
failures fail closed. This is a private subprocess, not a privileged helper or
persistent service. It exists only while process network monitoring is active.

Directly killing the supervisor itself with SIGKILL cannot run its cleanup;
normal app shutdown and forcibly terminating the app are covered. No unrelated
system/user nettop processes are scanned or terminated by the application.

## Regression checks

make test-logic runs tests/nettop_lifecycle_tests.py against real nettop. It
checks continued output, a generous CPU ceiling intended to detect EOF spinning,
normal termination, spontaneous reader exit, SIGKILL of the parent, and bounded
cleanup of a stopped child. Tests register kernel exit notifications for both
processes and clean up their own processes on failure.

make test-runtime also exercises rapid start/stop replacement and live parsing
in the app. The runner is explicitly injected into the test sampler; production
resolves it from the app bundle. make bundle embeds and signs the runner, and CI
checks that it is executable inside the shipped bundle.

"""Headless macOS checks against real nettop, without admin privileges."""
import errno
import os
import pty
import resource
import select
import selectors
import signal
import subprocess
import sys
import time

RUNNER = os.path.abspath(sys.argv[1])


def cpu_seconds():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def exercise(mode):
    master, slave = pty.openpty()
    os.set_blocking(master, False)
    parent_code = """
import subprocess, sys
runner = subprocess.Popen([sys.argv[1]], stdin=subprocess.DEVNULL)
print('runner pid=' + str(runner.pid), file=sys.stderr, flush=True)
sys.stdin.buffer.read()
runner.terminate()
runner.wait()
"""
    before = cpu_seconds()
    started = time.monotonic()
    command = [sys.executable, '-c', parent_code, RUNNER] if mode == 'parent-crash' else [RUNNER]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=slave, stderr=subprocess.PIPE)
    os.close(slave)
    runner = process.pid if mode != 'parent-crash' else None
    child = None
    events = select.kqueue()
    selector = selectors.DefaultSelector()
    selector.register(process.stderr, selectors.EVENT_READ)
    selector.register(master, selectors.EVENT_READ)
    exited = set()
    diagnostic = b''
    output = bytearray()
    try:
        deadline = time.monotonic() + 5
        while child is None or runner is None:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('startup timeout', mode, diagnostic)
            for key, _ in selector.select(remaining):
                data = os.read(key.fd, 65536)
                assert data, ('unexpected startup EOF', mode, diagnostic)
                if key.fd == master:
                    output.extend(data)
                else:
                    diagnostic += data
                    for line in diagnostic.splitlines():
                        if line.startswith(b'nettop pid='):
                            child = int(line.split(b'=')[1])
                        if line.startswith(b'runner pid='):
                            runner = int(line.split(b'=')[1])
        watched = {runner, child}
        for pid in watched:
            events.control([select.kevent(pid, filter=select.KQ_FILTER_PROC,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE, fflags=select.KQ_NOTE_EXIT)], 0)
        if mode == 'cpu':
            deadline = started + 7
            while time.monotonic() < deadline:
                for key, _ in selector.select(max(0, deadline - time.monotonic())):
                    try:
                        data = os.read(key.fd, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            data = b''
                        else:
                            raise
                    assert data, 'reader exited during CPU measurement'
                    if key.fd == master:
                        output.extend(data)
            assert output.count(b'bytes_in') >= 2, 'nettop must continue producing samples'
        if mode == 'stopped-child':
            os.kill(child, signal.SIGSTOP)
            state = subprocess.check_output(['ps', '-o', 'state=', '-p', str(child)], text=True)
            assert 'T' in state, 'child must be stopped before testing bounded shutdown'
        shutdown = time.monotonic()
        if mode == 'parent-crash':
            process.kill()
        elif mode == 'child-exit':
            os.kill(child, signal.SIGTERM)
        else:
            process.terminate()
        deadline = shutdown + 3
        while watched:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ('process cleanup timeout', mode, watched)
            for event in events.control(None, 8, remaining):
                if event.fflags & select.KQ_NOTE_EXIT:
                    watched.discard(event.ident)
                    exited.add(event.ident)
        process.wait(timeout=2)
        elapsed = time.monotonic() - shutdown
        if mode == 'cpu':
            percent = (cpu_seconds() - before) / (shutdown - started) * 100
            print(f'nettop + supervisor: {percent:.2f}% CPU over 7 seconds', flush=True)
            assert percent < 30, 'CPU regression: nettop may be spinning on stdin EOF'
        print(f'PASS: {mode}, both processes exited in {elapsed:.3f}s', flush=True)
    finally:
        # Never leave a real monitor behind, even when an assertion fails.
        for pid in (child, runner):
            if pid is not None and pid not in exited:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if process.poll() is None:
            process.kill()
        process.wait(timeout=3)
        selector.close()
        events.close()
        process.stderr.close()
        process.stdin.close()
        os.close(master)


for scenario in ('cpu', 'child-exit', 'parent-crash', 'stopped-child'):
    exercise(scenario)

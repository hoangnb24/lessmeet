"""External kill supervisor. Darwin RSS is sampled, NOT a kernel RSS ceiling.

Child CPU/core rlimits plus Node heap/WASM limits supplement RSS monitoring.
Never confuse RLIMIT_AS with a reliable Darwin virtual-memory ceiling (it aliases RSS).
"""
import argparse
import json
import os
import resource
import selectors
import signal
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--seconds', type=float, default=10)
p.add_argument('--rss-mib', type=int, default=256)
p.add_argument('--report', required=True)
p.add_argument('command', nargs=argparse.REMAINDER)
a = p.parse_args()
cmd = a.command[1:] if a.command[:1] == ['--'] else a.command
if not cmd:
    p.error('command required')

def limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (5, 6))

started = time.monotonic()
child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    start_new_session=True, preexec_fn=limits,
    env={'PATH': '/opt/homebrew/bin:/usr/bin:/bin'})
sel = selectors.DefaultSelector()
for stream in [child.stdout, child.stderr]:
    os.set_blocking(stream.fileno(), False)
    sel.register(stream, selectors.EVENT_READ)
data = {child.stdout: bytearray(), child.stderr: bytearray()}
peak = 0
reason = None
while child.poll() is None:
    elapsed = time.monotonic() - started
    try:
        rss = subprocess.run(['/bin/ps', '-o', 'rss=', '-p', str(child.pid)],
            capture_output=True, timeout=0.5, check=False).stdout.strip()
        if rss:
            peak = max(peak, int(rss) * 1024)
    except (ValueError, subprocess.TimeoutExpired):
        reason = 'memory-monitor-failed'
    for key, _ in sel.select(timeout=0.01):
        block = os.read(key.fileobj.fileno(), 8192)
        if block:
            data[key.fileobj].extend(block)
        else:
            sel.unregister(key.fileobj)
    if elapsed > a.seconds:
        reason = 'wall-time-kill'
    if peak > a.rss_mib * 1024**2:
        reason = 'sampled-rss-kill'
    if sum(map(len, data.values())) > 128 * 1024:
        reason = 'output-limit-kill'
    if reason:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        break
child.wait(timeout=2)
for stream in [child.stdout, child.stderr]:
    while len(data[stream]) < 128 * 1024:
        block = stream.read(8192)
        if not block:
            break
        data[stream].extend(block)
report = {'command': cmd, 'exit': child.returncode, 'reason': reason,
    'elapsedSeconds': time.monotonic() - started, 'sampledPeakRssBytes': peak,
    'limits': {'wallSeconds': a.seconds, 'sampledRssMiB': a.rss_mib,
        'cpuSoftSeconds': 5, 'cpuHardSeconds': 6,
        'note': 'No hard total-RSS ceiling on Darwin; samples can overshoot. Node flags and fixed WASM memory separately bound decoder allocations.'},
    'stdout': data[child.stdout].decode('utf8', errors='replace'),
    'stderr': data[child.stderr].decode('utf8', errors='replace')}
with open(a.report, 'w') as out:
    json.dump(report, out, indent=2)
    out.write('\n')
print(json.dumps(report, indent=2))
raise SystemExit(0 if child.returncode == 0 and not reason else 1)

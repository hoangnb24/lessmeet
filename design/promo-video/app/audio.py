"""Music and sound effects synthesized from scratch (standard library only).

render(cues, duration, path) writes a 48 kHz stereo 16-bit WAV. `cues` is a
list of (time_seconds, kind) in final-video time, produced by compose.py from
the real driver event log, so every effect lands on the on-screen action.
"""
import array
import math
import random
import wave

RATE = 48_000
TAU = 2 * math.pi


def note(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


class Track:
    def __init__(self, seconds):
        self.n = int(seconds * RATE) + RATE
        self.left = array.array("f", bytes(4 * self.n))
        self.right = array.array("f", bytes(4 * self.n))

    def add(self, start, samples, gain=1.0, pan=0.0):
        i0 = int(start * RATE)
        gl, gr = gain * math.cos((pan + 1) * math.pi / 4), gain * math.sin((pan + 1) * math.pi / 4)
        left, right, n = self.left, self.right, self.n
        for k, s in enumerate(samples):
            i = i0 + k
            if 0 <= i < n:
                left[i] += s * gl
                right[i] += s * gr


def pad_voice(freq, seconds, attack=1.2, release=1.6):
    n = int(seconds * RATE)
    out = [0.0] * n
    detunes = (0.997, 1.0, 1.004)
    phases = [random.random() * TAU for _ in detunes]
    for k in range(n):
        t = k / RATE
        env = min(1.0, t / attack) * min(1.0, (seconds - t) / release)
        s = 0.0
        for d, ph in zip(detunes, phases):
            w = TAU * freq * d * t + ph
            s += math.sin(w) + 0.18 * math.sin(2 * w) + 0.06 * math.sin(3 * w)
        out[k] = s * env / 3.7
    return out


def pluck(freq, seconds=0.9, brightness=0.5):
    period = max(2, int(RATE / freq))
    buf = [random.uniform(-1, 1) for _ in range(period)]
    out = []
    prev = 0.0
    for k in range(int(seconds * RATE)):
        v = buf[k % period]
        nxt = buf[(k + 1) % period]
        avg = 0.996 * (brightness * v + (1 - brightness) * (v + nxt) / 2)
        buf[k % period] = avg
        prev = prev + 0.35 * (v - prev)
        out.append(prev)
    return out


def kick():
    out = []
    for k in range(int(0.32 * RATE)):
        t = k / RATE
        f = 48 + 90 * math.exp(-t * 28)
        out.append(math.sin(TAU * f * t) * math.exp(-t * 11))
    return out


def shaker():
    return [random.uniform(-1, 1) * math.exp(-k / RATE * 70) for k in range(int(0.06 * RATE))]


def click():
    out = []
    for k in range(int(0.05 * RATE)):
        t = k / RATE
        out.append(0.55 * random.uniform(-1, 1) * math.exp(-t * 900) + 0.6 * math.sin(TAU * 2100 * t) * math.exp(-t * 140))
    return out


def key_tick():
    pitch = random.uniform(2600, 3600)
    out = []
    for k in range(int(0.025 * RATE)):
        t = k / RATE
        out.append(0.5 * random.uniform(-1, 1) * math.exp(-t * 1400) + 0.25 * math.sin(TAU * pitch * t) * math.exp(-t * 300))
    return out


def blip(f0, f1, seconds=0.22):
    out, ph = [], 0.0
    for k in range(int(seconds * RATE)):
        t = k / RATE
        f = f0 + (f1 - f0) * (t / seconds)
        ph += TAU * f / RATE
        env = min(1.0, t / 0.008) * math.exp(-t * 9)
        out.append((math.sin(ph) + 0.25 * math.sin(2 * ph)) * env)
    return out


def whoosh(seconds=0.7, rising=True):
    out, low = [], 0.0
    for k in range(int(seconds * RATE)):
        x = k / (seconds * RATE)
        env = math.sin(math.pi * x) ** 2
        cut = 0.02 + 0.25 * (x if rising else 1 - x)
        low += cut * (random.uniform(-1, 1) - low)
        out.append(low * env * 2.2)
    return out


def chime(base=880.0, seconds=1.8):
    partials = ((1.0, 1.0), (2.01, 0.45), (3.0, 0.22), (4.2, 0.1))
    out = []
    for k in range(int(seconds * RATE)):
        t = k / RATE
        s = sum(a * math.sin(TAU * base * m * t) * math.exp(-t * (2.2 + m)) for m, a in partials)
        out.append(s * min(1.0, t / 0.004) * 0.5)
    return out


def sparkle(seconds):
    out = [0.0] * int(seconds * RATE)
    for _ in range(int(seconds * 14)):
        i = random.randrange(len(out))
        f = random.choice((1760, 2093, 2349, 2637))
        for k in range(int(0.08 * RATE)):
            if i + k < len(out):
                t = k / RATE
                out[i + k] += math.sin(TAU * f * t) * math.exp(-t * 45) * 0.3
    return out


CHORDS = [  # D major: Dmaj9, Bm9, Gmaj9, A6/9 (MIDI)
    (50, 62, 66, 69, 73, 76), (47, 62, 66, 69, 73, 74), (43, 62, 66, 71, 74, 81), (45, 61, 64, 66, 69, 71),
]


def music(track, duration, beat, intro_end, outro_start):
    bar = beat * 4
    random.seed(7)
    start = 0.0
    index = 0
    while start < duration:
        chord = CHORDS[index % len(CHORDS)]
        length = min(bar * 2, duration - start) + 1.4
        for j, m in enumerate(chord):
            track.add(start, pad_voice(note(m), length), gain=0.05 if j else 0.08, pan=(j - 2.5) / 5)
        # Arpeggio after the intro, eighth notes.
        if start + bar * 2 > intro_end:
            tones = chord[1:]
            for e in range(16):
                t = start + e * beat / 2
                if intro_end <= t < duration - 1.0:
                    m = tones[(e * 3) % len(tones)] + (12 if e % 4 == 3 else 0)
                    track.add(t, pluck(note(m), 0.8, 0.45), gain=0.10, pan=0.35 if e % 2 else -0.35)
        start += bar * 2
        index += 1
    t = intro_end
    while t < outro_start:
        b = round((t - intro_end) / beat)
        if b % 2 == 0:
            track.add(t, kick(), gain=0.20)
        track.add(t + beat / 2, shaker(), gain=0.035, pan=0.4)
        t += beat


def render(cues, duration, path, beat=60 / 96, intro_end=4.0, outro_start=None):
    random.seed(1)
    track = Track(duration)
    music(track, duration, beat, intro_end, outro_start or duration - 4)
    fx = {
        "click": lambda: (click(), 0.55), "key": lambda: (key_tick(), 0.28),
        "record": lambda: (blip(520, 980), 0.40), "stop": lambda: (blip(900, 420), 0.38),
        "whoosh": lambda: (whoosh(0.7, True), 0.42), "whoosh-out": lambda: (whoosh(0.9, False), 0.40),
        "chime": lambda: (chime(880), 0.45), "chime-low": lambda: (chime(587.33, 2.6), 0.5),
        "sparkle": lambda: (sparkle(3.0), 0.5), "riser": lambda: (whoosh(2.2, True), 0.35),
    }
    for time, kind in cues:
        samples, gain = fx[kind]()
        track.add(time, samples, gain=gain, pan=random.uniform(-0.15, 0.15))
    # Fade in/out, gentle saturation, normalise to -1 dBFS.
    n = int(duration * RATE)
    left, right = track.left, track.right
    peak = 1e-9
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / 1.0) * min(1.0, (duration - t) / 2.0)
        left[i] = math.tanh(left[i] * 1.3) * env
        right[i] = math.tanh(right[i] * 1.3) * env
        peak = max(peak, abs(left[i]), abs(right[i]))
    scale = 0.89 / peak * 32767
    pcm = array.array("h", bytes(4 * n))
    for i in range(n):
        pcm[2 * i] = int(left[i] * scale)
        pcm[2 * i + 1] = int(right[i] * scale)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())

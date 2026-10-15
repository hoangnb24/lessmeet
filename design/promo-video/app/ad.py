"""30-second LessMeet ad cut from the real 60 fps app capture.

Hook (0-3 s) -> promise (3-5 s) -> real-app demo (5-23 s) -> call to action (23-30 s).
App frames come only from the capture. Some demo shots play faster (speed is listed
per shot and in the README); nothing in the app is redrawn. Graphics are drawn in
code with the app icon. Music and effects are synthesized here at 120 BPM and placed
from the driver's real event times.

Usage: python3 ad.py <take-dir> <output.mp4>
"""
import math
import os
import random
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

import audio
import compose as c

W, H, FPS = c.W, c.H, c.FPS
DURATION = 30.0
BEAT = 0.5  # 120 BPM; cuts land on beats
DARK = (0x1f, 0x2a, 0x20)
ACCENT = (0xd4, 0xe3, 0xa5)
IVORY = (0xf7, 0xf7, 0xf0)
SOFT = (0xb9, 0xc4, 0xa8)


def pt(x, y):
    return x * c.SCALE_PT, y * c.SCALE_PT


def shots(events):
    rec = c.find(events, "click", "New recording")
    stop = c.find(events, "click", "Stop")
    weekly = c.find(events, "click", "Product weekly")
    typing = c.find(events, "typing-start")
    send = c.find(events, "click", "Send")
    # (final start, final end, source start, speed, captions, zoom keys in source time)
    return [
        dict(t=(5.0, 7.5), src=rec - 0.6, speed=1.0, cap=("Hit record.", "Stay in the conversation."),
             zoom=[(rec - 0.6, 1.0, pt(640, 360)), (rec + 1.9, 1.6, pt(1060, 110))]),
        dict(t=(7.5, 8.5), src=stop - 0.3, speed=1.0, cap=("Hit record.", "Stay in the conversation."),
             zoom=[(stop - 0.3, 1.6, pt(1060, 110)), (stop + 0.7, 1.35, pt(900, 200))]),
        dict(t=(8.5, 12.0), src=weekly + 0.4, speed=1.6, cap=("Every word.", "Transcribed right on your Mac."),
             zoom=[(weekly + 0.4, 1.15, pt(760, 380)), (weekly + 6.0, 1.45, pt(700, 470))]),
        dict(t=(12.0, 14.5), src=typing - 0.4, speed=2.0, cap=("Forgot what was decided?", "Just ask."),
             zoom=[(typing - 0.4, 1.7, pt(700, 560)), (typing + 4.6, 1.8, pt(720, 560))]),
        dict(t=(14.5, 20.5), src=send - 0.5, speed=1.0, cap=("Ask. Get the answer.", "Straight from this meeting\u2019s transcript."),
             zoom=[(send - 0.5, 1.5, pt(900, 560)), (send + 1.0, 1.3, pt(760, 330)), (send + 5.5, 1.42, pt(760, 330))]),
        dict(t=(20.5, 23.0), src=send + 5.5, speed=1.0, cap=("Decisions. Owners.", "Next steps. Done."),
             zoom=[(send + 5.5, 1.42, pt(760, 330)), (send + 8.0, 1.6, pt(740, 330))]),
    ]


def text_img(text, size, color, weight="Bold", path=c.SANS):
    f = c.font(size, weight, path)
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    box = probe.textbbox((0, 0), text, font=f)
    img = Image.new("RGBA", (box[2] + 12, box[3] + 24), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((6, 6), text, font=f, fill=color)
    return img


def slam(canvas, img, cx, cy, t, start, hold_end=None):
    """Word slam: scale 1.25 -> 1 with fast fade in; optional fade out."""
    if t < start:
        return
    k = c.ease_out((t - start) / 0.22)
    a = min(1.0, (t - start) / 0.12)
    if hold_end is not None:
        a *= max(0.0, min(1.0, (hold_end - t) / 0.15))
    c.paste_center(canvas, img, cx, cy, a, 1.25 - 0.25 * k)


def main():
    take, output = Path(sys.argv[1]), Path(sys.argv[2])
    times, events = c.load_take(take)
    plan = shots(events)
    at_cursor = c.cursor_track(events)
    sprite = c.cursor_sprite(40)
    icon = Image.open(c.ICON).convert("RGBA")
    source = c.Source(take / "app-raw.mp4")

    # Hook texture: a heavily blurred real transcript frame.
    texture = source.get(c.bisect.bisect_left(times, c.find(events, "click", "Product weekly") + 0.2))
    source = c.Source(take / "app-raw.mp4")  # restart the sequential reader
    texture = texture.resize((W // 4, H // 4)).filter(ImageFilter.GaussianBlur(6)).resize((W, H), Image.BICUBIC)
    texture = Image.blend(Image.new("RGB", (W, H), DARK), texture, 0.16).convert("RGBA")

    hook_words = [
        (text_img("A 47-minute meeting.", 92, SOFT, "Semibold"), 0.0, 1.0),
        (text_img("One question:", 92, SOFT, "Semibold"), 1.0, 1.75),
    ]
    hook_big1 = text_img("What did we", 150, IVORY)
    hook_big2 = text_img("decide?", 150, ACCENT)
    promise1 = text_img("LessMeet remembers", 96, IVORY)
    promise2 = text_img("so you don\u2019t have to.", 96, ACCENT)
    mark = c.wordmark(132)
    mark_img = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    # Recolour the wordmark for dark backgrounds (keep the olive period).
    px = mark.load()
    for y in range(mark.height):
        for x in range(mark.width):
            r, g, b, a = px[x, y]
            if a and (r, g, b) != c.OLIVE:
                mark_img.putpixel((x, y), IVORY + (a,))
            elif a:
                mark_img.putpixel((x, y), ACCENT + (a,))
    tagline = text_img("Be in the conversation. Keep the details.", 50, SOFT, path=c.SERIF_ITALIC)
    meta = text_img("For Apple Silicon Macs \u00b7 macOS 15 or later", 30, SOFT, "Regular")
    disclaimer1 = text_img("Real LessMeet app, offline demo build, sample meeting. Chat answer is a demo fixture; some shots sped up.",
                           20, (0x8c, 0x98, 0x80), "Regular")
    disclaimer2 = text_img("ChatGPT is a trademark of OpenAI. LessMeet is independent and not endorsed by OpenAI.",
                           20, (0x8c, 0x98, 0x80), "Regular")
    pill_text = text_img("Coming soon for Mac", 40, DARK, "Semibold")
    pill = Image.new("RGBA", (pill_text.width + 64, pill_text.height + 22), (0, 0, 0, 0))
    ImageDraw.Draw(pill).rounded_rectangle((0, 0, pill.width - 1, pill.height - 1), pill.height // 2, fill=ACCENT + (255,))
    pill.alpha_composite(pill_text, (32, 8))
    caps = {}
    for s in plan:
        if s["cap"] not in caps:
            caps[s["cap"]] = (text_img(s["cap"][0], 78, IVORY), text_img(s["cap"][1], 40, ACCENT, "Semibold"))
    badge = c.badge_image("REAL APP \u00b7 DEMO BUILD \u00b7 SAMPLE MEETING")

    vw, vh = 1472, 828
    vx, vy = (W - vw) // 2, 232
    mask = Image.new("L", (vw, vh), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, vw - 1, vh - 1), 20, fill=255)
    shadow, pad = c.rounded_shadow(vw, vh, 20, 40, 150)
    vignette = Image.new("L", (W, H), 0)
    ImageDraw.Draw(vignette).rectangle((0, 0, W, 330), fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(90))
    top_shade = Image.new("RGBA", (W, H), DARK + (0,))
    top_shade.putalpha(vignette.point(lambda v: int(v * 0.92)))

    def app_shot(s, t):
        lt = t - s["t"][0]
        st = s["src"] + lt * s["speed"]
        frame = source.get(max(0, c.bisect.bisect_left(times, st)))
        z, (fx, fy) = c.zoom_at(s["zoom"], st)
        # Subtle push-in across every shot keeps the frame alive.
        z *= 1.0 + 0.03 * (lt / (s["t"][1] - s["t"][0]))
        cw, ch = W / z, H / z
        x0 = min(max(fx - cw / 2, 0), W - cw)
        y0 = min(max(fy - ch / 2, 0), H - ch)
        view = frame.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((vw, vh), Image.BICUBIC)
        canvas = Image.new("RGBA", (W, H), (0x2c, 0x3b, 0x2d, 255))
        canvas.alpha_composite(shadow, (vx - pad, vy - pad))
        canvas.paste(view, (vx, vy), mask)
        k = vw / cw
        cx, cy = at_cursor(st)
        sx, sy = vx + (cx - x0) * k, vy + (cy - y0) * k
        d = ImageDraw.Draw(canvas)
        for e in events:
            if e[1] == "click" and 0 <= st - e[0] < 0.5:
                f = (st - e[0]) / 0.5
                r = 14 + 60 * c.ease_out(f)
                d.ellipse((sx - r, sy - r, sx + r, sy + r), outline=ACCENT + (int(255 * (1 - f)),), width=6)
        if vx < sx < vx + vw and vy < sy < vy + vh:
            canvas.alpha_composite(sprite, (int(sx - 4), int(sy - 3)))
        big, small = caps[s["cap"]]
        first = next(p for p in plan if p["cap"] == s["cap"])["t"][0]
        slam(canvas, big, vx + big.width / 2 - 6, 88, t, first)
        slam(canvas, small, vx + small.width / 2 - 6, 168, t, first + 0.35)
        c.paste_at(canvas, badge, W - badge.width - 50, H - badge.height - 26, 0.9)
        return canvas

    def hook(t):
        canvas = texture.copy()
        for img, a, b in hook_words:
            slam(canvas, img, W / 2, H / 2 - 40, t, a, b)
        slam(canvas, hook_big1, W / 2, H / 2 - 95, t, 1.75)
        slam(canvas, hook_big2, W / 2, H / 2 + 80, t, 2.25)
        return canvas

    def promise(t):
        canvas = Image.new("RGBA", (W, H), DARK + (255,))
        lt = t - 3.0
        k = c.ease_out(lt / 0.35)
        c.paste_center(canvas, icon, W / 2, 380, min(1, lt / 0.1), 0.30 * (1.5 - 0.5 * k))
        if lt < 0.6:  # shockwave ring
            d = ImageDraw.Draw(canvas)
            r = 150 + 520 * c.ease_out(lt / 0.6)
            d.ellipse((W / 2 - r, 380 - r, W / 2 + r, 380 + r), outline=ACCENT + (int(200 * (1 - lt / 0.6)),), width=8)
        slam(canvas, promise1, W / 2, 680, t, 3.25)
        slam(canvas, promise2, W / 2, 800, t, 3.6)
        return canvas

    def cta(t):
        canvas = Image.new("RGBA", (W, H), DARK + (255,))
        lt = t - 23.0
        k = c.ease_out(lt / 0.4)
        c.paste_center(canvas, icon, W / 2, 330, min(1, lt / 0.1), 0.30 * (1.35 - 0.35 * k))
        if lt < 0.7:
            d = ImageDraw.Draw(canvas)
            r = 150 + 600 * c.ease_out(lt / 0.7)
            d.ellipse((W / 2 - r, 330 - r, W / 2 + r, 330 + r), outline=ACCENT + (int(180 * (1 - lt / 0.7)),), width=8)
        slam(canvas, mark_img, W / 2, 575, t, 23.3)
        slam(canvas, tagline, W / 2, 680, t, 23.8)
        # Pill gently pulses on the beat after it lands.
        if t >= 24.5:
            pulse = 1.0 + 0.025 * max(0.0, math.cos(math.pi * ((t - 24.5) % 1.0) / 0.5)) if (t - 24.5) % 1.0 < 0.5 else 1.0
            slam(canvas, pill, W / 2, 800, t, 24.5)
            if t > 24.8:
                c.paste_center(canvas, pill, W / 2, 800, 1.0, pulse)
        c.paste_center(canvas, meta, W / 2, 885, c.ease((t - 25.2) / 0.4))
        c.paste_center(canvas, disclaimer1, W / 2, 985, c.ease((t - 25.6) / 0.4))
        c.paste_center(canvas, disclaimer2, W / 2, 1018, c.ease((t - 25.6) / 0.4))
        return canvas

    def flash(frame, t, at, length=0.18):
        if 0 <= t - at < length:
            a = 1 - (t - at) / length
            return Image.blend(frame, Image.new("RGBA", (W, H), IVORY + (255,)), 0.85 * a)
        return frame

    work = Path(tempfile.mkdtemp(prefix="lessmeet-ad-"))
    video = work / "video.mp4"
    preview = [float(x) for x in os.environ.get("PREVIEW", "").split(",") if x]
    enc = None if preview else subprocess.Popen(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
         "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "16", "-pix_fmt", "yuv420p",
         str(video)], stdin=subprocess.PIPE)
    total = int(DURATION * FPS)
    for n in range(total):
        t = n / FPS
        if preview and not any(abs(t - p) < 0.5 / FPS for p in preview):
            if t > max(preview):
                break
            continue
        if t < 3.0:
            frame = hook(t)
        elif t < 5.0:
            frame = promise(t)
        elif t < 23.0:
            shot = next(s for s in plan if s["t"][0] <= t < s["t"][1])
            frame = app_shot(shot, t)
        else:
            frame = cta(t)
        for at in (3.0, 5.0, 8.5, 12.0, 14.5, 23.0):
            frame = flash(frame, t, at)
        if t > DURATION - 0.6:
            frame = Image.blend(frame, Image.new("RGBA", (W, H), (0, 0, 0, 255)), (t - (DURATION - 0.6)) / 0.6)
        if preview:
            frame.convert("RGB").save(work / f"ad-{t:05.2f}.png")
        else:
            enc.stdin.write(frame.convert("RGB").tobytes())
        if n % 300 == 0:
            print(f"frame {n}/{total}", flush=True)
    if preview:
        print(f"Previews in {work}")
        return
    enc.stdin.close()
    enc.wait()

    cues = [(0.0, "hit"), (1.0, "hit"), (1.75, "hit-big"), (2.25, "hit-big"), (0.0, "drone"),
            (3.0, "impact"), (5.0, "whoosh"), (8.5, "whoosh"), (12.0, "whoosh"), (14.5, "whoosh"),
            (20.8, "riser"), (23.0, "impact"), (24.5, "chime")]
    for s in plan:
        a, b = s["t"]
        for e in events:
            ft = a + (e[0] - s["src"]) / s["speed"]
            if a <= ft < b:
                if e[1] == "click":
                    cues.append((ft, "click"))
                    if e[4] == "New recording":
                        cues.append((ft + 0.06, "record"))
                    elif e[4] == "Stop":
                        cues.append((ft + 0.06, "stop"))
                    elif e[4] == "Send":
                        cues.append((ft + 0.9, "sparkle"))
                elif e[1] == "key":
                    cues.append((ft, "key"))
    send_final = 14.5 + 0.5
    cues.append((send_final + 4.4, "chime"))
    wav = work / "audio.wav"
    render_audio(cues, str(wav))
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(video), "-i", str(wav), "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-shortest", str(output)], check=True)
    output.with_suffix(".cues.tsv").write_text("".join(f"{t:.3f}\t{k}\n" for t, k in sorted(cues)))
    print(f"Built {output}")


# ---------------------------------------------------------------- audio
def sub_hit(seconds=0.9, f0=110, f1=38):
    out = []
    for k in range(int(seconds * audio.RATE)):
        t = k / audio.RATE
        f = f1 + (f0 - f1) * math.exp(-t * 18)
        out.append(math.sin(audio.TAU * f * t) * math.exp(-t * 3.2))
    return out


def impact():
    hit = sub_hit(1.6, 140, 32)
    for k in range(int(0.5 * audio.RATE)):
        hit[k] += random.uniform(-1, 1) * math.exp(-k / audio.RATE * 9) * 0.6
    return hit


def clap():
    out = []
    for k in range(int(0.18 * audio.RATE)):
        t = k / audio.RATE
        burst = sum(math.exp(-max(0, t - o) * 60) * (t >= o) for o in (0, 0.008, 0.017))
        out.append(random.uniform(-1, 1) * (burst * 0.4 + math.exp(-t * 22) * 0.5))
    return out


def bass(freq, seconds):
    out = []
    for k in range(int(seconds * audio.RATE)):
        t = k / audio.RATE
        env = min(1, t / 0.005) * math.exp(-t * 4) * min(1, (seconds - t) / 0.02)
        w = audio.TAU * freq * t
        out.append((math.sin(w) + 0.35 * math.sin(2 * w) + 0.12 * math.sin(3 * w)) * env)
    return out


def drone(seconds=3.0):
    out = []
    for k in range(int(seconds * audio.RATE)):
        t = k / audio.RATE
        env = min(1, t / 0.3) * min(1, (seconds - t) / 0.08)
        f = 55 * (1 + 0.5 * t / seconds)
        out.append((math.sin(audio.TAU * f * t) + 0.5 * math.sin(audio.TAU * f * 1.5 * t)) * env * (0.4 + 0.6 * t / seconds))
    return out


PROGRESSION = [  # B minor, G, D, A (vi-IV-I-V in D) with colour tones
    (35, (59, 62, 66, 69)), (31, (59, 62, 67, 71)), (38, (57, 62, 66, 69)), (33, (57, 61, 64, 69)),
]


def render_audio(cues, path):
    random.seed(11)
    track = audio.Track(DURATION)
    bar = BEAT * 4
    # Groove from the drop (3 s) to the CTA impact (23 s); a calmer bed under the CTA.
    t = 3.0
    while t < 23.0 - 1e-6:
        i = int(round((t - 3.0) / bar))
        root, chord = PROGRESSION[i % 4]
        for j, m in enumerate(chord):
            track.add(t, audio.pad_voice(audio.note(m), bar + 0.6, 0.05, 0.5), gain=0.035, pan=(j - 1.5) / 3)
        for b in range(4):
            bt = t + b * BEAT
            track.add(bt, audio.kick(), gain=0.55)
            if b in (1, 3):
                track.add(bt, clap(), gain=0.20, pan=0.1)
            for e in range(2):
                track.add(bt + e * BEAT / 2 + BEAT / 4, audio.shaker(), gain=0.07, pan=0.45)
            track.add(bt + BEAT / 2, bass(audio.note(root), BEAT / 2 - 0.02), gain=0.22)
            track.add(bt, bass(audio.note(root), BEAT / 2 - 0.02), gain=0.16)
            for s16 in range(4):
                m = chord[(b * 4 + s16 * 3) % 4] + 12
                track.add(bt + s16 * BEAT / 4, audio.pluck(audio.note(m), 0.35, 0.6), gain=0.05,
                          pan=-0.4 if s16 % 2 else 0.4)
        t += bar
    for j, m in enumerate((50, 62, 66, 69, 74, 78)):  # D major bloom under the CTA
        track.add(23.0, audio.pad_voice(audio.note(m), 7.0, 0.4, 2.5), gain=0.06, pan=(j - 2.5) / 5)
    for k in range(10):
        track.add(23.0 + 0.5 + k * BEAT, audio.pluck(audio.note((74, 78, 81, 86)[k % 4]), 0.9, 0.5), gain=0.08,
                  pan=0.3 if k % 2 else -0.3)
    fx = {
        "hit": lambda: (sub_hit(0.7), 0.55), "hit-big": lambda: (impact(), 0.55), "drone": lambda: (drone(3.0), 0.16),
        "impact": lambda: (impact(), 0.75), "whoosh": lambda: (audio.whoosh(0.45, True), 0.45),
        "riser": lambda: (audio.whoosh(2.2, True), 0.5), "click": lambda: (audio.click(), 0.6),
        "key": lambda: (audio.key_tick(), 0.3), "record": lambda: (audio.blip(520, 980), 0.45),
        "stop": lambda: (audio.blip(900, 420), 0.42), "sparkle": lambda: (audio.sparkle(3.0), 0.55),
        "chime": lambda: (audio.chime(880), 0.5),
    }
    for time, kind in cues:
        samples, gain = fx[kind]()
        track.add(time, samples, gain=gain, pan=random.uniform(-0.1, 0.1))
    n = int(DURATION * audio.RATE)
    left, right = track.left, track.right
    peak = 1e-9
    for i in range(n):
        tt = i / audio.RATE
        env = min(1.0, (DURATION - tt) / 1.2)
        left[i] = math.tanh(left[i] * 1.6) * env
        right[i] = math.tanh(right[i] * 1.6) * env
        peak = max(peak, abs(left[i]), abs(right[i]))
    scale = 0.70 / peak * 32767
    import array
    import wave
    pcm = array.array("h", bytes(4 * n))
    for i in range(n):
        pcm[2 * i] = int(left[i] * scale)
        pcm[2 * i + 1] = int(right[i] * scale)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(audio.RATE)
        w.writeframes(pcm.tobytes())


if __name__ == "__main__":
    main()

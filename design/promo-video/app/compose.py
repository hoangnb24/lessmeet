"""Compose the promo from a real 60 fps capture of the running LessMeet app.

Inputs (one take directory from record.sh): app-raw.mp4 (frames grabbed in-process
from the app window), frames.tsv (wall-clock time per frame) and events.tsv (the
XCUITest driver's real actions). Titles, cursor, click ripples, zooms and
transitions are drawn here with Pillow using the app's own icon artwork. audio.py
synthesizes music and effects aligned to the same events. FFmpeg muxes the result.

Usage: python3 compose.py <take-dir> <output.mp4>
"""
import bisect
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import audio

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ICON = ROOT / "Resources/Artwork/lessmeet-v2/LessMeet-1024.png"
W, H, FPS = 1920, 1080, 60
STAGE = (0xdc, 0xe1, 0xcf)
PAPER = (0xf7, 0xf7, 0xf0)
INK = (0x28, 0x36, 0x2a)
MUTED = (0x62, 0x6a, 0x5d)
GREEN = (0x35, 0x4b, 0x33)
OLIVE = (0x7b, 0x96, 0x51)
SCALE_PT = 1.5  # capture pixels per window point
BASE = 0.80     # window scale on the stage
TOP = 196       # window top on the stage, leaving room for captions

SANS = "/System/Library/Fonts/SFNS.ttf"
SERIF_ITALIC = "/System/Library/Fonts/Supplemental/Georgia Italic.ttf"


def font(size, weight="Regular", path=SANS):
    f = ImageFont.truetype(path, size)
    if path == SANS:
        try:
            f.set_variation_by_name(weight)
        except (OSError, ValueError):
            pass
    return f


def ease(x):
    x = min(1.0, max(0.0, x))
    return x * x * (3 - 2 * x)


def ease_out(x):
    x = min(1.0, max(0.0, x))
    return 1 - (1 - x) ** 3


# ---------------------------------------------------------------- take data
def load_take(take):
    times = [float(x) for x in (take / "frames.tsv").read_text().split()]
    t0 = times[0]
    times = [t - t0 for t in times]
    events = []
    for line in (take / "events.tsv").read_text().splitlines():
        stamp, kind, x, y, label = (line.split("\t") + [""])[:5]
        events.append((float(stamp) - t0, kind, float(x) * SCALE_PT, float(y) * SCALE_PT, label))
    return times, events


def find(events, kind, label=None):
    for e in events:
        if e[1] == kind and (label is None or e[4] == label):
            return e[0]
    raise KeyError((kind, label))


# ---------------------------------------------------------------- cursor
def cursor_track(events):
    """Piecewise glide: the pointer travels to each target during the 0.55 s
    between the driver's 'move' and 'click' marks, then rests."""
    keys = [(0.0, 1400.0, 820.0)]
    for t, kind, x, y, _ in events:
        if kind == "move" and x >= 0:
            keys.append((t, keys[-1][1], keys[-1][2]))
            keys.append((t + 0.5, x, y))
    def at(t):
        if t <= keys[0][0]:
            return keys[0][1:]
        for (ta, xa, ya), (tb, xb, yb) in zip(keys, keys[1:]):
            if ta <= t <= tb:
                f = ease((t - ta) / max(tb - ta, 1e-6))
                return xa + (xb - xa) * f, ya + (yb - ya) * f
        return keys[-1][1:]
    return at


def cursor_sprite(size=34):
    s = 4
    img = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pts = [(2, 1), (2, 24), (8, 18.5), (12.5, 28), (16.5, 26.3), (12.3, 17.2), (20, 17.2)]
    pts = [(x * s * size / 32, y * s * size / 32) for x, y in pts]
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(x + 3 * s, y + 4 * s) for x, y in pts], fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(3 * s))
    img = Image.alpha_composite(shadow, img)
    d = ImageDraw.Draw(img)
    d.polygon(pts, fill=(20, 20, 20, 255), outline=(255, 255, 255, 255), width=int(2.2 * s))
    return img.resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------------- static art
def rounded_shadow(w, h, radius=18, blur=34, alpha=95):
    pad = blur * 3
    img = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle((pad, pad + 22, pad + w, pad + h + 22), radius, fill=(0x3e, 0x4e, 0x39, alpha))
    return img.filter(ImageFilter.GaussianBlur(blur)), pad


def text_block(lines, width=W, center=False):
    """lines: [(text, font, color, gap_after)] -> RGBA image, height trimmed."""
    height = sum(f.size + g for _, f, _, g in lines) + 20
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    width = min(width, int(max(probe.textlength(text, font=f) for text, f, _, _ in lines)) + 8)
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    y = 0
    for text, f, color, gap in lines:
        x = (width - probe.textlength(text, font=f)) / 2 if center else 0
        d.text((x, y), text, font=f, fill=color)
        y += f.size + gap
    return img


def caption_image(title, subtitle):
    return text_block([(title, font(54, "Semibold"), INK, 14), (subtitle, font(27), MUTED, 0)])


def badge_image(text):
    f = font(19, "Semibold")
    box = ImageDraw.Draw(Image.new("RGB", (1, 1))).textbbox((0, 0), text, font=f)
    w, h = box[2] + 36, 42
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, w - 1, h - 1), 9, fill=INK + (235,))
    d.text((18, (h - f.size) / 2 - 3), text, font=f, fill=PAPER)
    return img


def wordmark(size):
    f = font(size, "Medium")
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    w1 = probe.textlength("LessMeet", font=f)
    w2 = probe.textlength(".", font=f)
    img = Image.new("RGBA", (int(w1 + w2) + 8, int(size * 1.3)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.text((0, 0), "LessMeet", font=f, fill=INK)
    d.text((w1, 0), ".", font=f, fill=OLIVE)
    return img


def paste_center(canvas, img, cx, cy, alpha=1.0, scale=1.0):
    if alpha <= 0.001:
        return
    if scale != 1.0:
        img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))), Image.LANCZOS)
    if alpha < 1.0:
        img = img.copy()
        img.putalpha(img.getchannel("A").point(lambda a: int(a * alpha)))
    canvas.alpha_composite(img, (int(cx - img.width / 2), int(cy - img.height / 2)))


def paste_at(canvas, img, x, y, alpha=1.0):
    if alpha <= 0.001:
        return
    if alpha < 1.0:
        img = img.copy()
        img.putalpha(img.getchannel("A").point(lambda a: int(a * alpha)))
    canvas.alpha_composite(img, (int(x), int(y)))


# ---------------------------------------------------------------- edit
def build_edit(events):
    """Cuts are in source seconds. Dead time (model list loading, menus opening)
    is cut, never sped up; every kept frame plays at real speed."""
    rec = find(events, "click", "New recording")
    stop = find(events, "click", "Stop")
    weekly = find(events, "click", "Product weekly")
    chat = find(events, "click", "Chat")
    load = find(events, "click", "Load models")
    model = find(events, "click", "Model")
    pick = find(events, "click", "Synthetic Chat Model")
    editor = find(events, "move", "Editor")
    send = find(events, "click", "Send")
    end = find(events, "end")
    def p(x, y):
        return x * SCALE_PT, y * SCALE_PT
    return [
        dict(src=(rec - 1.6, stop + 2.2), caption=("Record the meeting.",
             "Captures microphone and system audio. Saved on this Mac."),
             zoom=[(rec - 1.6, 1.0, None), (rec - 0.2, 1.45, p(1000, 150)), (stop + 0.6, 1.45, p(1000, 150)),
                   (stop + 1.8, 1.0, None)]),
        dict(src=(weekly - 1.0, weekly + 8.6), caption=("Read it back.",
             "A local transcript with speakers and timestamps. Transcription runs on this Mac."),
             zoom=[(weekly - 1.0, 1.0, None), (weekly + 1.4, 1.0, None), (weekly + 3.0, 1.30, p(760, 470)),
                   (weekly + 8.6, 1.36, p(760, 500))]),
        dict(src=(chat - 0.9, load + 1.4), caption=("Ask about the meeting.",
             "Connect your ChatGPT plan, then ask about this recording only."),
             zoom=[(chat - 0.9, 1.0, None)]),
        dict(src=(model - 0.9, pick + 1.2), caption=("Ask about the meeting.",
             "Connect your ChatGPT plan, then ask about this recording only."),
             zoom=[(model - 0.9, 1.25, p(640, 560)), (pick + 1.2, 1.25, p(640, 560))]),
        dict(src=(editor - 0.4, end - 0.2), caption=("Get decisions and next steps.",
             "Answers come from this recording\u2019s transcript, sent to OpenAI when you ask."),
             zoom=[(editor - 0.4, 1.30, p(640, 540)), (send + 0.6, 1.30, p(640, 540)),
                   (send + 2.0, 1.22, p(660, 380)), (end - 0.2, 1.22, p(660, 380))]),
    ]


def zoom_at(zoom, t):
    def resolve(k):
        s, f = k[1], k[2]
        return s, f if f is not None else (W / 2, H / 2)
    if t <= zoom[0][0]:
        return resolve(zoom[0])
    for a, b in zip(zoom, zoom[1:]):
        if a[0] <= t <= b[0]:
            (sa, fa), (sb, fb) = resolve(a), resolve(b)
            f = ease((t - a[0]) / max(b[0] - a[0], 1e-6))
            return sa + (sb - sa) * f, (fa[0] + (fb[0] - fa[0]) * f, fa[1] + (fb[1] - fa[1]) * f)
    return resolve(zoom[-1])


# ---------------------------------------------------------------- render
class Source:
    """Sequential reader of the capture (cuts only move forward in time)."""
    def __init__(self, path):
        self.proc = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo",
                                      "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        self.index = -1
        self.frame = None

    def get(self, index):
        while self.index < index:
            data = self.proc.stdout.read(W * H * 3)
            if len(data) < W * H * 3:
                break
            self.frame = data
            self.index += 1
        return Image.frombytes("RGB", (W, H), self.frame)


def main():
    take, output = Path(sys.argv[1]), Path(sys.argv[2])
    times, events = load_take(take)
    cuts = build_edit(events)
    at_cursor = cursor_track(events)
    sprite = cursor_sprite()
    icon = Image.open(ICON).convert("RGBA")
    icon_shadowless = icon
    INTRO, OUTRO, XF = 4.2, 6.0, 0.45
    # Final timeline.
    t = INTRO - XF
    for c in cuts:
        c["start"] = t
        c["len"] = c["src"][1] - c["src"][0]
        t += c["len"] - XF
    app_end = t + XF
    duration = app_end + OUTRO - XF
    for c in cuts:
        c["cap"] = caption_image(*c["caption"])
    badge = badge_image("REAL LESSMEET APP \u00b7 OFFLINE DEMO BUILD \u00b7 SAMPLE DATA")
    answer_badge = badge_image("SAMPLE TRANSCRIPT \u00b7 FIXTURE ANSWER, NOT A LIVE CHATGPT REPLY")
    base_w, base_h = int(W * BASE), int(H * BASE)
    shadow, shadow_pad = rounded_shadow(base_w, base_h)
    big_mark, small_mark = wordmark(104), wordmark(84)
    tagline = text_block([("A quiet place to revisit your meetings.", font(40, path=SERIF_ITALIC), (0x61, 0x73, 0x4b), 0)])
    out_tag = text_block([("Record. Transcribe. Ask.", font(46, path=SERIF_ITALIC), (0x61, 0x73, 0x4b), 0)])
    out_meta = text_block([("For Apple Silicon Macs \u00b7 macOS 15 or later", font(28), MUTED, 0)])
    disclaimer = text_block([
        ("Recorded from the LessMeet app running an offline demo build with sample meeting data.", font(21), MUTED, 8),
        ("The chat answer is a local fixture. ChatGPT is a trademark of OpenAI; LessMeet is independent and not endorsed by OpenAI.", font(21), MUTED, 0)], center=True)

    def src_index(src_t):
        return max(0, bisect.bisect_left(times, src_t))

    bx, by = (W - base_w) // 2, TOP
    mask = Image.new("L", (base_w, base_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, base_w - 1, base_h - 1), 15, fill=255)

    def app_frame(c, local_t, source):
        src_t = c["src"][0] + local_t
        frame = source.get(src_index(src_t))
        z, (fx, fy) = zoom_at(c["zoom"], src_t)
        # Camera inside a fixed window frame: crop around the focus, clamp to the capture.
        cw, ch = W / z, H / z
        x0 = min(max(fx - cw / 2, 0), W - cw)
        y0 = min(max(fy - ch / 2, 0), H - ch)
        view = frame.crop((int(x0), int(y0), int(x0 + cw), int(y0 + ch))).resize((base_w, base_h), Image.BICUBIC)
        canvas = Image.new("RGBA", (W, H), STAGE + (255,))
        canvas.alpha_composite(shadow, (bx - shadow_pad, by - shadow_pad))
        canvas.paste(view, (bx, by), mask)
        k = base_w / cw
        cx, cy = at_cursor(src_t)
        sx, sy = bx + (cx - x0) * k, by + (cy - y0) * k
        draw = ImageDraw.Draw(canvas)
        for e in events:
            if e[1] == "click" and 0 <= src_t - e[0] < 0.45:
                f = (src_t - e[0]) / 0.45
                r = 10 + 34 * ease_out(f)
                draw.ellipse((sx - r, sy - r, sx + r, sy + r), outline=GREEN + (int(200 * (1 - f)),), width=4)
        press = any(e[1] == "click" and 0 <= src_t - e[0] < 0.12 for e in events)
        cur = sprite if not press else sprite.resize((30, 30), Image.LANCZOS)
        if bx - 40 < sx < bx + base_w and by - 40 < sy < by + base_h:
            canvas.alpha_composite(cur, (int(sx - 3), int(sy - 2)))
        return canvas

    def overlay_captions(canvas, c, local_t, alpha):
        a = alpha * ease((local_t - 0.15) / 0.5)
        paste_at(canvas, c["cap"], 120, 46 - 10 * (1 - a), a)
        paste_at(canvas, badge, W - badge.width - 64, 58, alpha)
        if c is cuts[-1]:
            sent = find(events, "click", "Send") - c["src"][0]
            paste_at(canvas, answer_badge, W - answer_badge.width - 64, 110, alpha * ease((local_t - sent) / 0.5))

    def intro(t):
        canvas = Image.new("RGBA", (W, H), PAPER + (255,))
        s = 0.55 + 0.45 * ease_out(t / 1.3)
        paste_center(canvas, icon_shadowless, W / 2, 420 - 20 * (1 - ease_out(t / 1.3)), ease(t / 0.7), 0.36 * s)
        paste_center(canvas, big_mark, W / 2, 690, ease((t - 0.9) / 0.6))
        paste_center(canvas, tagline, W / 2, 812, ease((t - 1.6) / 0.7))
        return canvas

    def outro(t):
        canvas = Image.new("RGBA", (W, H), PAPER + (255,))
        paste_center(canvas, icon_shadowless, W / 2, 330, ease(t / 0.6), 0.26 + 0.02 * ease_out(t / 3))
        paste_center(canvas, small_mark, W / 2, 545, ease((t - 0.4) / 0.6))
        paste_center(canvas, out_tag, W / 2, 650, ease((t - 0.9) / 0.6))
        paste_center(canvas, out_meta, W / 2, 738, ease((t - 1.4) / 0.6))
        paste_center(canvas, disclaimer, W / 2, 960, ease((t - 2.0) / 0.6))
        return canvas

    work = Path(tempfile.mkdtemp(prefix="lessmeet-compose-"))
    video = work / "video.mp4"
    enc = subprocess.Popen(["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
                            "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium",
                            "-crf", "16", "-pix_fmt", "yuv420p", str(video)], stdin=subprocess.PIPE)
    source = Source(take / "app-raw.mp4")
    total = int(round(duration * FPS))
    preview = [float(x) for x in os.environ.get("PREVIEW", "").split(",") if x]
    for n in range(total):
        if preview and not any(abs(n / FPS - p) < 0.5 / FPS for p in preview):
            if n / FPS > max(preview):
                break
            # Keep the sequential source reader aligned without composing.
            continue
        t = n / FPS
        if t < INTRO - XF:
            frame = intro(t)
        elif t >= app_end:
            frame = outro(t - (app_end - XF))
        else:
            frame = None
            for c in cuts:
                lt = t - c["start"]
                if 0 <= lt < c["len"]:
                    img = app_frame(c, lt, source)
                    overlay_captions(img, c, lt, 1.0)
                    frame = img if frame is None else Image.blend(frame, img, ease(lt / XF))
            if t < INTRO:
                frame = Image.blend(intro(t), frame, ease((t - (INTRO - XF)) / XF))
            if t >= app_end - XF:
                frame = Image.blend(frame, outro(t - (app_end - XF)), ease((t - (app_end - XF)) / XF))
        if preview:
            frame.convert("RGB").save(work / f"preview-{n / FPS:06.2f}.png")
            continue
        enc.stdin.write(frame.convert("RGB").tobytes())
        if n % 300 == 0:
            print(f"frame {n}/{total}", flush=True)
    enc.stdin.close()
    enc.wait()
    if preview:
        print(f"Previews in {work}")
        return
    # Sound cues from the real driver events, mapped into final time.
    cues = [(0.15, "riser"), (1.0, "chime-low"), (INTRO - 0.35, "whoosh")]
    for i, c in enumerate(cuts):
        if i:
            cues.append((c["start"] - 0.2, "whoosh"))
        for e in events:
            if c["src"][0] <= e[0] < c["src"][1]:
                ft = c["start"] + e[0] - c["src"][0]
                if e[1] == "click":
                    cues.append((ft, "click"))
                    if e[4] == "New recording":
                        cues.append((ft + 0.08, "record"))
                    if e[4] == "Stop":
                        cues.append((ft + 0.08, "stop"))
                    if e[4] == "Send":
                        cues.append((ft + 0.9, "sparkle"))
                        cues.append((ft + 4.6, "chime"))
                if e[1] == "key":
                    cues.append((ft, "key"))
    cues += [(app_end - XF - 0.3, "whoosh-out"), (app_end + 0.2, "chime-low")]
    wav = work / "audio.wav"
    audio.render(cues, duration, str(wav), intro_end=INTRO, outro_start=app_end)
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(video), "-i", str(wav), "-c:v", "copy",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-shortest", str(output)], check=True)
    (output.with_suffix(".cues.tsv")).write_text("".join(f"{t:.3f}\t{k}\n" for t, k in sorted(cues)))
    print(f"Built {output} ({duration:.2f}s)")


if __name__ == "__main__":
    main()

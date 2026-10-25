#!/usr/bin/env python3
"""Generates Trivia Clash's original app icon and sound effects.

  python3 scripts/make_assets.py

Outputs:
  ios/TriviaClash/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024×1024, no alpha)
  ios/TriviaClash/Resources/Sounds/*.wav (short synthesized effects, 44.1 kHz mono)
"""
import json
import math
import struct
import wave
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "ios" / "TriviaClash" / "Resources"
NAVY = (11, 16, 32)
PANEL = (29, 38, 71)
VOLT = (198, 255, 61)
INK = (242, 244, 255)


def icon() -> None:
    size = 1024
    img = Image.new("RGB", (size, size), NAVY)
    d = ImageDraw.Draw(img)
    # Two opposing slabs meeting at a slanted seam: the "clash".
    d.polygon([(150, 250), (560, 250), (470, 774), (150, 774)], fill=PANEL)
    d.polygon([(600, 250), (874, 250), (874, 774), (510, 774)], fill=VOLT)
    # Bolt-shaped seam cut through the middle.
    d.polygon([(560, 170), (420, 540), (530, 540), (450, 860), (640, 470), (528, 470), (612, 170)], fill=INK)
    # Four answer ticks on the panel side.
    for i in range(4):
        y = 330 + i * 110
        d.rounded_rectangle([210, y, 210 + 210 - i * 22, y + 50], radius=16, fill=(60, 74, 128))
    d.rounded_rectangle([210, 330, 250, 380], radius=12, fill=VOLT)
    out = RES / "Assets.xcassets" / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    img.save(out / "AppIcon.png", "PNG")
    (out / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    cat = RES / "Assets.xcassets"
    (cat / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    accent = cat / "AccentColor.colorset"
    accent.mkdir(exist_ok=True)
    (accent / "Contents.json").write_text(json.dumps({
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.776", "green": "1.000", "blue": "0.239", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    launch = cat / "LaunchBackground.colorset"
    launch.mkdir(exist_ok=True)
    (launch / "Contents.json").write_text(json.dumps({
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.043", "green": "0.063", "blue": "0.125", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


RATE = 44100


def tone(freqs, dur, vol=0.35, attack=0.005, decay=None, wave_type="sine"):
    n = int(RATE * dur)
    out = []
    for i in range(n):
        t = i / RATE
        f = freqs[0] + (freqs[-1] - freqs[0]) * (i / n) if len(freqs) > 1 else freqs[0]
        phase = 2 * math.pi * f * t
        s = math.sin(phase) if wave_type == "sine" else (1 if math.sin(phase) > 0 else -1) * 0.5
        env = min(1.0, t / attack) if attack else 1.0
        env *= math.exp(-t / decay) if decay else max(0.0, 1 - t / dur)
        out.append(s * env * vol)
    return out


def write(name, samples):
    path = RES / "Sounds" / f"{name}.wav"
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))


def seq(*parts):
    out = []
    for p in parts:
        out.extend(p)
    return out


def sounds() -> None:
    write("tick", tone([1400], 0.05, vol=0.25, decay=0.015))
    write("submit", seq(tone([520, 780], 0.08, vol=0.3, decay=0.05)))
    write("correct", seq(tone([660], 0.09, decay=0.08), tone([880], 0.09, decay=0.08), tone([1320], 0.18, decay=0.12)))
    write("wrong", seq(tone([300, 220], 0.28, vol=0.3, decay=0.2, wave_type="square")))
    write("leaderboard", seq(tone([523], 0.07, decay=0.05), tone([659], 0.07, decay=0.05), tone([784], 0.12, decay=0.08)))
    write("start", seq(tone([440, 880], 0.18, vol=0.3, decay=0.12)))
    write("victory", seq(tone([523], 0.12, decay=0.1), tone([659], 0.12, decay=0.1), tone([784], 0.12, decay=0.1),
                         tone([1047], 0.4, decay=0.3)))


if __name__ == "__main__":
    icon()
    sounds()
    print("assets written")

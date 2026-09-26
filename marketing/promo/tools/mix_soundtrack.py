"""Arranges the SafeKey film soundtracks from Apple Loops (the Chill Melody set
from the Chillwave pack) and Final Cut Pro sound effects, both licensed for use
in one's own soundtracks. 100 BPM: a beat is 0.6 s, a bar 2.4 s, and every cut
in the films sits on that grid.

    python tools/mix_soundtrack.py full      # 75 s film  -> tools/build/mix_raw-full.wav
    python tools/mix_soundtrack.py trailer   # 20 s cut   -> tools/build/mix_raw-trailer.wav

tools/master.sh runs this and normalises the result. Needs numpy and scipy
(python3 -m venv .venv && .venv/bin/pip install numpy scipy) and
tools/build/loops.json from tools/catalog_loops.py."""
import json, os, subprocess, sys, wave
import numpy as np
from scipy.signal import butter, fftconvolve, lfilter, sosfilt

BUILD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build")
SR = 48000
BEAT, BAR = 0.6, 2.4
ROWS = {r["name"]: r for r in json.load(open(os.path.join(BUILD, "loops.json")))}


def db(v):
    return 10 ** (v / 20)


def t(bar, beat=0.0):
    return bar * BAR + beat * BEAT


_cache = {}


def load(name):
    if name not in _cache:
        raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", ROWS[name]["path"], "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
                             capture_output=True, check=True).stdout
        _cache[name] = np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)
    return _cache[name]


def loop(name):
    x = load(name)
    n = int(round(ROWS[name]["beats"] * BEAT * SR))
    if len(x) < n:
        x = np.vstack([x, np.zeros((n - len(x), 2))])
    return x[:n]


class Mix:
    def __init__(self, seconds):
        self.end = seconds
        self.n = int(seconds * SR)
        self.bus = {k: np.zeros((self.n, 2)) for k in ("music", "drums", "sfx", "verb")}

    def place(self, bus, x, start, gain_db=0.0, fade_in=0.004, fade_out=0.004, length=None):
        x = x.copy()
        if length is not None:
            x = x[: int(length * SR)]
        fi, fo = int(fade_in * SR), int(fade_out * SR)
        if fi:
            x[:fi] *= np.linspace(0, 1, fi)[:, None]
        if fo:
            x[-fo:] *= np.linspace(1, 0, fo)[:, None]
        s = int(round(start * SR))
        if s < 0:
            x, s = x[-s:], 0
        e = min(self.n, s + len(x))
        if e > s:
            self.bus[bus][s:e] += x[: e - s] * db(gain_db)

    def peak(self, bus, name, at, peak_offset, gain_db=0.0, **kw):
        self.place(bus, load(name), at - peak_offset, gain_db, **kw)

    def phrases(self, x, starts, stop, gain_db, bus="music"):
        for p in starts:
            self.place(bus, x, t(p), gain_db, length=min(len(x) / SR, t(stop) - t(p)))

    def gap(self, bus, start, stop, ramp=0.012):
        s, e, r = int(start * SR), int(stop * SR), int(ramp * SR)
        env = np.ones(self.n)
        env[s:e] = 0
        env[s - r:s] = np.linspace(1, 0, r)
        env[e:e + r] = np.linspace(0, 1, r)
        self.bus[bus] *= env[:, None]

    def automate(self, bus, points):
        times = np.array([p[0] for p in points]) * SR
        gains = np.array([p[1] for p in points])
        self.bus[bus] *= db(np.interp(np.arange(self.n), times, gains))[:, None]

    def riser(self, start, stop, gain_db, top=7000):
        n = int((stop - start) * SR)
        tt = np.linspace(0, 1, n)
        noise = np.random.default_rng(7).standard_normal((n, 2))
        out = np.zeros_like(noise)
        zi = [np.zeros(4), np.zeros(4)]
        for s in range(0, n, 256):
            fc = 250 * (top / 250) ** (tt[s] ** 1.6)
            b, a = butter(2, [fc * 0.7 / (SR / 2), min(0.99, fc * 1.4 / (SR / 2))], btype="band")
            for ch in range(2):
                out[s:s + 256, ch], zi[ch] = lfilter(b, a, noise[s:s + 256, ch], zi=zi[ch])
        out *= (tt ** 2.2)[:, None]
        out /= np.max(np.abs(out)) + 1e-9
        self.place("sfx", out, start, gain_db, fade_in=0.2, fade_out=0.03)
        self.place("verb", out, start, gain_db - 6, fade_in=0.2, fade_out=0.03)

    def synth_bed(self, syn, phrase_starts, stop, gain_db, open_bars, fade_bars=1.0):
        """The synth under everything, opening from a low-pass over the first bars."""
        track = np.zeros((self.n, 2))
        for p in phrase_starts:
            s = int(t(p) * SR)
            e = min(self.n, s + len(syn), int(t(stop) * SR))
            track[s:e] += syn[: e - s]
        out = track.copy()
        end = int(t(open_bars) * SR)
        zi = np.zeros((2, 2))
        for s in range(0, end, 256):
            fc = 350 * (3500 / 350) ** ((s / end) ** 1.3)
            b, a = butter(2, fc / (SR / 2))
            for ch in range(2):
                out[s:s + 256, ch], zi[ch] = lfilter(b, a, track[s:s + 256, ch], zi=zi[ch])
        fade = int(t(fade_bars) * SR)
        out[:fade] *= np.linspace(0, 1, fade)[:, None] ** 1.5
        self.bus["music"] += out * db(gain_db)
        self.bus["verb"] += out * db(gain_db - 10)

    def render(self, path, tail_fade=0.8):
        n = int(2.6 * SR)
        env = np.exp(-6.9 * np.linspace(0, 1, n))
        ir = np.random.default_rng(3).standard_normal((n, 2)) * env[:, None]
        ir = sosfilt(butter(2, 6000 / (SR / 2), output="sos"), ir, axis=0) / np.sqrt(n) * 3
        wet = np.stack([fftconvolve(self.bus["verb"][:, c], ir[:, c])[: self.n] for c in range(2)], axis=1)
        mix = self.bus["music"] + self.bus["drums"] + self.bus["sfx"] + wet * 0.6
        mix = sosfilt(butter(2, 30 / (SR / 2), btype="high", output="sos"), mix, axis=0)
        mix = mix / np.max(np.abs(mix)) * 0.9
        mix = np.tanh(mix * 1.3) / np.tanh(1.3)
        fade = int(tail_fade * SR)
        mix[-fade:] *= np.linspace(1, 0, fade)[:, None]
        pcm = (np.clip(mix, -1, 1) * 32767).astype("<i2")
        with wave.open(path, "wb") as w:
            w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())


G = dict(syn=-3.0, gtr=-5.0, bas=-4.0, lead=-2.5, drm=-1.0, drm_top=-8.0)


def parts():
    return dict(syn=loop("Chill Melody Synth 01"), gtr=loop("Chill Melody Guitar Chords"), bas=loop("Chill Melody Bass 01"),
                lead=loop("Chill Melody Lead Guitar"), drm=loop("Matchbox Beat 01"), drm_light=loop("Matchbox Beat 02"),
                drm_top=loop("Crunchy Beat 01"))


def ending(m, L, at, tail=3.0):
    """The phrase's opening bar (E) struck again and left to ring."""
    for key, g in (("syn", G["syn"]), ("gtr", G["gtr"]), ("bas", G["bas"] - 2)):
        m.place("music", L[key], at, g, fade_out=tail - 0.2, length=tail)
    m.place("verb", L["syn"], at, G["syn"] - 4, fade_out=tail - 0.2, length=tail)


def arrange_full():
    """75 s: intro, logo, iPhone, screenshot stop, security drop, Mac, sync, outro, end card."""
    m, L = Mix(75.0), parts()
    m.synth_bed(L["syn"], range(0, 30, 4), 30, G["syn"], open_bars=4)
    m.phrases(L["gtr"], range(4, 30, 4), 30, G["gtr"])
    m.phrases(L["bas"], range(4, 30, 4), 30, G["bas"])
    for p in (16, 20):  # lead only over the E-major bars, never over A / A minor
        m.place("music", L["lead"], t(p), G["lead"]); m.place("verb", L["lead"], t(p), G["lead"] - 8)
    for b in range(8, 15, 2):
        m.place("drums", L["drm"], t(b), G["drm"], length=min(4.8, t(15) - t(b)))
    for b in range(16, 24, 2):
        m.place("drums", L["drm"], t(b), G["drm"]); m.place("drums", L["drm_top"], t(b), G["drm_top"])
    m.place("drums", L["drm_light"], t(24), G["drm"] + 1)
    ending(m, L, t(30))
    stop, resume = t(13, 2), t(14)
    for bus in ("music", "drums"):
        m.gap(bus, stop, resume)

    m.place("sfx", load("Drone Low Tranquil")[int(2.0 * SR): int(12.5 * SR)], 0.0, -9.0, fade_in=2.0, fade_out=2.5)
    m.riser(t(2, 2), t(4), -16)
    m.peak("sfx", "Ascending", t(4), 2.85, -10)
    m.peak("sfx", "Impact Hit Reverb 02", t(4), 0.55, -6)
    m.peak("sfx", "LFE Hit Impact 06", t(4), 0.35, -9)
    m.place("sfx", load("Lock 1"), t(3, 3) - 0.15, -4)
    for at in (t(0, 0.66), t(1), t(2), t(2, 1), t(2, 2)):
        m.place("sfx", load("Click Off FX"), at, -8)
    m.peak("sfx", "Whoosh 14", t(6), 0.25, -12)
    m.place("sfx", load("Electronic Hit FX 23"), t(8, 2) - 0.2, -12)
    m.peak("sfx", "Whoosh 12", t(10), 0.2, -16)
    m.place("sfx", load("Click Off FX"), t(11, 1), -10)
    m.place("sfx", load("Click Off FX"), t(12, 1), -10)
    m.place("sfx", load("Camera 2"), stop - 0.15, +6)
    m.peak("sfx", "Impact Hit Reverb 03", resume, 0.9, -14)
    m.riser(t(15), t(16), -14)
    m.peak("sfx", "Whoosh 13", t(16), 0.95, -9)
    m.peak("sfx", "Impact Hit Reverb 01", t(16), 0.5, -7)
    m.peak("sfx", "LFE Hit Impact 05", t(16), 0.6, -12)
    for i in range(8):
        m.place("sfx", load("Electronic Hit FX 09" if i % 2 else "Electronic Hit FX 06"), t(17) + i * BEAT, -9)
    m.peak("sfx", "Whoosh 14", t(20), 0.25, -12)
    m.place("sfx", load("Title Crystal Sweep 01"), t(23) - 0.3, -16, fade_out=1.5, length=3.2)
    m.peak("sfx", "Whoosh 12", t(25), 0.2, -15)
    for at in (t(26), t(26, 2), t(27)):
        m.place("sfx", load("Low Frequency Hit FX"), at, -14)
    m.peak("sfx", "Impact Hit Reverb 03", t(28), 0.9, -10)

    m.automate("music", [(0, 0), (t(4) - 0.05, 0), (t(4), -3.0), (t(8) - 0.3, -3.0), (t(8), 0), (t(16) - 0.05, 0),
                         (t(16), 1.5), (t(24), 1.5), (t(24) + 1.2, 0), (t(26), 0), (t(26) + 2.4, -2.5), (m.end, -2.5)])
    m.automate("drums", [(0, 0), (t(16) - 0.05, 0), (t(16), 1.5), (t(24), 1.5), (t(24) + 1.2, -1.0), (m.end, -1.0)])
    return m


def arrange_trailer():
    """20.4 s: encryption, logo, Face ID, reveal, screenshot stop, the vault line, devices, end card.
    Phrases start at bars 0 and 4 (E E A Am); the end strikes E again at bar 8."""
    m, L = Mix(20.4), parts()
    m.synth_bed(L["syn"], (0, 4), 8, G["syn"], open_bars=1, fade_bars=0.5)
    m.place("music", L["gtr"], t(1), G["gtr"], length=t(4) - t(1))   # joins with the logo
    m.place("music", L["bas"], t(1), G["bas"], length=t(4) - t(1))
    m.phrases(L["gtr"], (4,), 8, G["gtr"])
    m.phrases(L["bas"], (4,), 8, G["bas"])
    m.place("music", L["lead"], t(5), G["lead"], length=BAR)          # the vault line, an E bar
    m.place("verb", L["lead"], t(5), G["lead"] - 8, length=BAR)
    m.place("drums", L["drm"], t(2), G["drm"])
    m.place("drums", L["drm"], t(4), G["drm"], length=BAR)
    m.place("drums", L["drm"], t(5), G["drm"], length=BAR * 2)
    m.place("drums", L["drm_top"], t(5), G["drm_top"], length=BAR * 2)
    ending(m, L, t(8), tail=2.4)
    stop, resume = t(4), t(4, 2)
    for bus in ("music", "drums"):
        m.gap(bus, stop, resume)

    m.riser(t(0, 1), t(1), -15)
    m.peak("sfx", "Ascending", t(1), 2.85, -12)
    m.peak("sfx", "Impact Hit Reverb 02", t(1), 0.55, -6)
    m.peak("sfx", "LFE Hit Impact 06", t(1), 0.35, -9)
    m.place("sfx", load("Lock 1"), t(0, 3) - 0.15, -4)
    m.peak("sfx", "Whoosh 14", t(2), 0.25, -12)
    m.place("sfx", load("Electronic Hit FX 23"), t(2, 1.67) - 0.2, -12)
    m.place("sfx", load("Click Off FX"), t(3, 1), -10)
    m.place("sfx", load("Camera 2"), stop - 0.15, +6)
    m.peak("sfx", "Impact Hit Reverb 03", resume, 0.9, -14)
    m.peak("sfx", "Whoosh 13", t(5), 0.95, -9)
    m.peak("sfx", "Impact Hit Reverb 01", t(5), 0.5, -7)
    m.peak("sfx", "LFE Hit Impact 05", t(5), 0.6, -12)
    m.peak("sfx", "Whoosh 12", t(6), 0.2, -15)
    m.peak("sfx", "Impact Hit Reverb 03", t(7), 0.9, -10)

    m.automate("music", [(0, 0), (t(1) - 0.05, 0), (t(1), -3.0), (t(2) - 0.3, -3.0), (t(2), 0), (t(5) - 0.05, 0),
                         (t(5), 1.5), (t(6) + 1.2, 1.5), (t(7), -1.5), (m.end, -2.5)])
    return m


if __name__ == "__main__":
    cut = sys.argv[1] if len(sys.argv) > 1 else "full"
    m = arrange_full() if cut == "full" else arrange_trailer()
    out = os.path.join(BUILD, f"mix_raw-{cut}.wav")
    m.render(out, tail_fade=0.8 if cut == "full" else 0.6)
    print("wrote", out, m.end, "s")

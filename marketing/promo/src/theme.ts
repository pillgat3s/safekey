import { Easing, interpolate } from "remotion";
import { loadFont } from "@remotion/google-fonts/Inter";

export const { fontFamily } = loadFont("normal", {
  weights: ["400", "500", "600", "700", "800"],
  subsets: ["latin"],
});

export const FPS = 60;
/** Seconds to frames. */
export const sec = (s: number) => Math.round(s * FPS);
/** The soundtrack runs at 100 BPM: a beat is 0.6 s, a bar 2.4 s. */
export const BEAT = 0.6;
export const BAR = 2.4;

export const C = {
  text: "#F5F5F7",
  dim: "#8E8E93",
  faint: "#48484A",
  blue: "#0A84FF",
  cyan: "#64D2FF",
  green: "#30D158",
  red: "#FF453A",
  card: "#111113",
  hairline: "rgba(255,255,255,0.09)",
};

export const expo = Easing.bezier(0.16, 1, 0.3, 1);
export const smooth = Easing.bezier(0.65, 0, 0.35, 1);
export const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** 0→1 between two frames, eased. */
export const ramp = (f: number, a: number, b: number, easing = expo) =>
  interpolate(f, [a, b], [0, 1], { ...clamp, easing });

/** Appear at `start`, disappear at `end` (frames), with a blur-and-rise entrance. */
export const reveal = (f: number, start: number, end = Infinity, dur = 26, outDur = 14) => {
  const i = ramp(f, start, start + dur);
  const o = end === Infinity ? 0 : ramp(f, end - outDur, end, smooth);
  return {
    opacity: i * (1 - o),
    transform: `translateY(${(1 - i) * 26 - o * 10}px)`,
    filter: `blur(${(1 - i) * 14 + o * 8}px)`,
  } as const;
};

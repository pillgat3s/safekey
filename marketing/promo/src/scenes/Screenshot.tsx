import React from "react";
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { C, clamp, expo, fontFamily, ramp, reveal, sec, smooth } from "../theme";
import { PHONE_ASPECT, Phone, fillMedia } from "../components/Devices";
import { Glow } from "../components/Overlays";
import { PHONE_HEIGHT, PHONE_LEFT, PHONE_TOP } from "./PhoneTour";

type Rect = { x: number; y: number; w: number; h: number };
const mix = (a: Rect, b: Rect, t: number): Rect => ({
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
  w: a.w + (b.w - a.w) * t,
  h: a.h + (b.h - a.h) * t,
});

// The key row in the recorded screen, as fractions of the screen.
const ROW = { top: 0.487, bottom: 0.623, left: 0.04, right: 0.96 };

/** 32.4–36.0 s: the shutter fires, and the screenshot comes back blank. */
export const Screenshot: React.FC = () => {
  const f = useCurrentFrame();
  const bezel = PHONE_HEIGHT * 0.017;
  const screenH = PHONE_HEIGHT - 2 * bezel;
  const screenW = screenH * PHONE_ASPECT;
  const screen: Rect = { x: PHONE_LEFT + bezel, y: PHONE_TOP + bezel, w: screenW, h: screenH };

  // The live phone moves right and shrinks as the comparison forms.
  const split = interpolate(f, [sec(1.2), sec(1.8)], [0, 1], { ...clamp, easing: expo });
  const finalH = 700;
  const s = 1 - (1 - finalH / PHONE_HEIGHT) * split;
  const phoneW = screenW + 2 * bezel;
  const dx = (1330 - phoneW * (finalH / PHONE_HEIGHT) / 2 - PHONE_LEFT) * split;
  const dy = (262 - PHONE_TOP) * split;

  // The screenshot: full screen, then the corner thumbnail, then its own card on the left.
  const shrink = interpolate(f, [4, 30], [0, 1], { ...clamp, easing: expo });
  const thumb: Rect = { x: screen.x + 16, y: screen.y + screenH * 0.7, w: screenW * 0.3, h: screenH * 0.3 - 22 };
  const cardH = finalH - 2 * bezel * (finalH / PHONE_HEIGHT);
  const card: Rect = { x: 590 - (cardH * PHONE_ASPECT) / 2, y: 262 + bezel * (finalH / PHONE_HEIGHT), w: cardH * PHONE_ASPECT, h: cardH };
  const rect = f < sec(1.2) ? mix(screen, thumb, shrink) : mix(thumb, card, split);
  const shotOpacity = interpolate(f, [2, 4], [0, 1], clamp);

  const flash = interpolate(f, [0, 16], [1, 0], { ...clamp, easing: smooth });
  const rings = ramp(f, sec(1.85), sec(2.15));
  const out = ramp(f, sec(3.3), sec(3.6), smooth);

  const ring = (r: Rect, color: string, dashed: boolean) => (
    <div
      style={{
        position: "absolute",
        left: r.x + r.w * ROW.left - 8,
        top: r.y + r.h * ROW.top - 6,
        width: r.w * (ROW.right - ROW.left) + 16,
        height: r.h * (ROW.bottom - ROW.top) + 12,
        borderRadius: 16,
        border: `3px ${dashed ? "dashed" : "solid"} ${color}`,
        boxShadow: `0 0 24px ${color}`,
        opacity: rings,
        transform: `scale(${1.06 - 0.06 * rings})`,
      }}
    />
  );
  const liveScreen: Rect = { x: PHONE_LEFT + dx + bezel * s, y: PHONE_TOP + dy + bezel * s, w: screenW * s, h: screenH * s };

  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out, filter: `blur(${out * 10}px)` }}>
      <Glow x={1250 + 80 * split} y={560} size={1000} opacity={0.55} />
      <Glow x={590} y={600} size={900} color="rgba(255,69,58,0.18)" opacity={split} />

      <div style={{ position: "absolute", inset: 0, transformOrigin: `${PHONE_LEFT}px ${PHONE_TOP}px`, transform: `translate(${dx}px, ${dy}px) scale(${s})` }}>
        <div style={{ position: "absolute", left: PHONE_LEFT, top: PHONE_TOP }}>
          <Phone height={PHONE_HEIGHT} style={{ left: 0, top: 0 }}>
            {/* A still: the recording hides the key again before this scene ends. */}
            <Img src={staticFile("footage/iphone-revealed.png")} style={fillMedia} />
            <div style={{ position: "absolute", inset: 0, background: "#fff", opacity: flash }} />
          </Phone>
        </div>
      </div>

      <div
        style={{
          position: "absolute",
          left: rect.x,
          top: rect.y,
          width: rect.w,
          height: rect.h,
          borderRadius: 14 + 40 * split,
          overflow: "hidden",
          opacity: shotOpacity,
          boxShadow: `0 20px 60px rgba(0,0,0,0.6), 0 0 0 ${3 - split}px rgba(255,255,255,0.9)`,
        }}
      >
        <Img src={staticFile("footage/iphone-screenshot-protected.png")} style={fillMedia} />
      </div>

      {ring(card, C.red, true)}
      {ring(liveScreen, C.green, false)}

      <div style={{ position: "absolute", left: 590 - 260, width: 520, top: 985, textAlign: "center", fontSize: 30, fontWeight: 600, color: C.dim, ...reveal(f, sec(1.6)) }}>
        In a screenshot
      </div>
      <div style={{ position: "absolute", left: 1330 - 260, width: 520, top: 985, textAlign: "center", fontSize: 30, fontWeight: 600, color: C.dim, ...reveal(f, sec(1.6)) }}>
        On your screen
      </div>

      <div style={{ position: "absolute", width: "100%", top: 72, textAlign: "center" }}>
        <div style={{ fontSize: 76, fontWeight: 700, letterSpacing: "-0.035em", ...reveal(f, sec(1.3)) }}>Screenshots see nothing.</div>
        <div style={{ marginTop: 14, fontSize: 28, fontWeight: 500, color: C.dim, ...reveal(f, sec(1.45)) }}>
          A revealed key never shows up in a screenshot or a screen recording.
        </div>
      </div>

      <AbsoluteFill style={{ background: "#fff", opacity: flash * 0.18, pointerEvents: "none" }} />
    </AbsoluteFill>
  );
};

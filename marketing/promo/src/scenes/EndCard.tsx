import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { C, clamp, expo, fontFamily, ramp, reveal, sec, smooth } from "../theme";
import { AppIcon, Glow } from "../components/Overlays";

/** 67.2–75.0 s: the name to remember, then black. */
export const EndCard: React.FC = () => {
  const f = useCurrentFrame();
  const icon = interpolate(f, [0, 44], [0, 1], { ...clamp, easing: expo });
  const pulse = 0.85 + 0.15 * Math.sin(f / 40);
  const fade = ramp(f, sec(6.6), sec(7.8), smooth);
  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - fade }}>
      <Glow x={960} y={360} size={820} opacity={0.85 * icon * pulse} />
      <div style={{ position: "absolute", left: 960 - 105, top: 250, opacity: icon, transform: `scale(${0.8 + 0.2 * icon})`, filter: `blur(${(1 - icon) * 16}px)` }}>
        <AppIcon size={210} />
      </div>
      <div style={{ position: "absolute", width: "100%", top: 492, textAlign: "center" }}>
        <div style={{ fontSize: 128, fontWeight: 800, letterSpacing: "-0.04em", ...reveal(f, 12, Infinity, 32) }}>SafeKey</div>
      </div>
      <div style={{ position: "absolute", width: "100%", top: 668, textAlign: "center" }}>
        <div style={{ fontSize: 46, fontWeight: 600, color: C.dim, letterSpacing: "-0.02em", ...reveal(f, sec(1.2)) }}>Your keys. Nobody else's.</div>
      </div>
      <div style={{ position: "absolute", width: "100%", top: 790, textAlign: "center" }}>
        <div style={{ fontSize: 24, fontWeight: 600, color: C.dim, letterSpacing: "0.26em", textTransform: "uppercase", ...reveal(f, sec(2.4)) }}>
          iPhone · iPad · Mac
        </div>
      </div>
    </AbsoluteFill>
  );
};

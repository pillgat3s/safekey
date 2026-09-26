import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { C, clamp, expo, fontFamily, ramp, reveal, smooth } from "../theme";
import { AppIcon, Glow } from "../components/Overlays";

/** 9.6–14.4 s: the icon, the name, the promise. */
export const Logo: React.FC<{ taglineAt?: number }> = ({ taglineAt = 144 }) => {
  const f = useCurrentFrame();
  const icon = ramp(f, 0, 40);
  const flash = interpolate(f, [0, 18], [0.85, 0], clamp);
  const out = ramp(f, 262, 288, smooth);
  const spacing = interpolate(f, [10, 60], [0.12, -0.035], { ...clamp, easing: expo });
  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out, transform: `scale(${1 - 0.03 * out})` }}>
      <Glow x={960} y={430} size={900} opacity={0.9 * icon} />
      <div style={{ position: "absolute", left: 960 - 125, top: 290, filter: `blur(${(1 - icon) * 22}px)`, opacity: icon, transform: `scale(${0.72 + 0.28 * icon})` }}>
        <AppIcon size={250} />
      </div>
      <div style={{ position: "absolute", width: "100%", top: 578, textAlign: "center" }}>
        <div style={{ fontSize: 136, fontWeight: 800, letterSpacing: `${spacing}em`, ...reveal(f, 10, Infinity, 34) }}>SafeKey</div>
      </div>
      <div style={{ position: "absolute", width: "100%", top: 770, textAlign: "center" }}>
        <div style={{ fontSize: 40, fontWeight: 500, color: C.dim, letterSpacing: "-0.01em", ...reveal(f, taglineAt) }}>
          The vault for your seed phrases and private keys.
        </div>
      </div>
      <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 42%, rgba(255,255,255,1), rgba(120,180,255,0.4) 40%, rgba(0,0,0,0) 70%)", opacity: flash }} />
    </AbsoluteFill>
  );
};

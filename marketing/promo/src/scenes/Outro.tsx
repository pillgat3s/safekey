import React from "react";
import { AbsoluteFill, useCurrentFrame } from "remotion";
import { C, fontFamily, ramp, reveal, sec, smooth } from "../theme";
import { Glow } from "../components/Overlays";

const LINES = ["No accounts.", "No servers.", "No tracking."];

/** 62.4–67.2 s: what SafeKey never asks of you. */
export const Outro: React.FC = () => {
  const f = useCurrentFrame();
  const out = ramp(f, sec(4.3), sec(4.8), smooth);
  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out, filter: `blur(${out * 10}px)` }}>
      <Glow x={960} y={540} size={1100} opacity={0.35} />
      {LINES.map((line, i) => (
        <div key={line} style={{ position: "absolute", width: "100%", top: 300 + i * 150, textAlign: "center" }}>
          <div
            style={{
              fontSize: 110,
              fontWeight: 750,
              letterSpacing: "-0.04em",
              ...(i === 2
                ? { background: `linear-gradient(90deg, ${C.blue}, ${C.cyan})`, WebkitBackgroundClip: "text", color: "transparent" }
                : {}),
              ...reveal(f, i * sec(1.2), Infinity, 24),
            }}
          >
            {line}
          </div>
        </div>
      ))}
    </AbsoluteFill>
  );
};

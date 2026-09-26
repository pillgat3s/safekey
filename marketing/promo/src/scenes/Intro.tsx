import React from "react";
import { AbsoluteFill, interpolate, random, useCurrentFrame } from "remotion";
import { LockKeyhole } from "lucide-react";
import { C, clamp, expo, fontFamily, ramp, reveal, smooth } from "../theme";
import { Glow } from "../components/Overlays";

const WORDS = "bridge silent canyon zebra kingdom saddle timber jungle frost jaguar hover yellow".split(" ");
const HEX = "0123456789abcdef";
const RISKS = ["On a sticky note.", "In your Notes app.", "In your camera roll."];

/** 0–9.6 s: what a seed phrase is, where people keep it, and the vault closing on it. */
export const Intro: React.FC = () => {
  const f = useCurrentFrame();
  const lift = ramp(f, 144, 176);

  const chip = (word: string, i: number) => {
    const col = i % 4, row = Math.floor(i / 4);
    const w = 250, h = 76, gap = 18;
    const x0 = (1920 - (4 * w + 3 * gap)) / 2, y0 = 540 - (3 * h + 2 * gap) / 2;
    const x = x0 + col * (w + gap), y = y0 + row * (h + gap);
    const enter = ramp(f, 432 + i * 2, 452 + i * 2);
    const collapse = interpolate(f, [526, 552], [0, 1], { ...clamp, easing: expo });
    let text = word;
    if (f >= 468 && f < 510) {
      const step = Math.floor(f / 3);
      text = word.split("").map((_, k) => HEX[Math.floor(random(`h${i}-${k}-${step}`) * 16)]).join("");
    } else if (f >= 510) {
      text = "•••••";
    }
    const cx = x + w / 2, cy = y + h / 2;
    return (
      <div
        key={i}
        style={{
          position: "absolute",
          left: x,
          top: y,
          width: w,
          height: h,
          borderRadius: 18,
          background: "rgba(255,255,255,0.055)",
          boxShadow: `inset 0 0 0 1px ${C.hairline}`,
          display: "flex",
          alignItems: "center",
          gap: 14,
          padding: "0 22px",
          boxSizing: "border-box",
          opacity: enter * (1 - collapse),
          transform: `translate(${(960 - cx) * collapse}px, ${(540 - cy) * collapse}px) scale(${(0.92 + 0.08 * enter) * (1 - 0.8 * collapse)})`,
        }}
      >
        <span style={{ fontSize: 20, fontWeight: 600, color: C.faint, width: 26, textAlign: "right", fontVariantNumeric: "tabular-nums" }}>
          {i + 1}
        </span>
        <span
          style={{
            fontSize: 32,
            fontWeight: 600,
            letterSpacing: f >= 468 && f < 510 ? "0.04em" : "-0.01em",
            color: f >= 468 && f < 510 ? C.cyan : C.text,
          }}
        >
          {text}
        </span>
      </div>
    );
  };

  const lockIn = ramp(f, 540, 562);
  const lockOut = ramp(f, 566, 576, smooth);

  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text }}>
      <Glow x={960} y={560} size={1100} opacity={0.35 + 0.4 * ramp(f, 432, 560)} />

      <div style={{ position: "absolute", width: "100%", top: 452 - 58 * lift, textAlign: "center" }}>
        <div style={{ fontSize: 112, fontWeight: 700, letterSpacing: "-0.04em", ...reveal(f, 24, 288) }}>Twelve words.</div>
      </div>
      <div style={{ position: "absolute", width: "100%", top: 520, textAlign: "center" }}>
        <div style={{ fontSize: 112, fontWeight: 700, letterSpacing: "-0.04em", color: C.dim, ...reveal(f, 144, 288) }}>
          Your whole wallet.
        </div>
      </div>

      {RISKS.map((text, i) => {
        const strike = ramp(f, 396 + i * 6, 412 + i * 6);
        return (
          <div key={text} style={{ position: "absolute", width: "100%", top: 360 + i * 110, textAlign: "center" }}>
            <span style={{ position: "relative", display: "inline-block", fontSize: 72, fontWeight: 650, letterSpacing: "-0.03em", ...reveal(f, 288 + i * 36, 436, 22, 10) }}>
              <span style={{ opacity: 1 - 0.55 * strike }}>{text}</span>
              <span
                style={{
                  position: "absolute",
                  left: -8,
                  top: "52%",
                  height: 6,
                  width: `calc((100% + 16px) * ${strike})`,
                  opacity: strike > 0 ? 1 : 0,
                  background: C.red,
                  borderRadius: 3,
                  boxShadow: "0 0 18px rgba(255,69,58,0.6)",
                }}
              />
            </span>
          </div>
        );
      })}

      {f >= 430 && WORDS.map(chip)}

      {f >= 536 && (
        <div
          style={{
            position: "absolute",
            left: 960 - 95,
            top: 540 - 95,
            width: 190,
            height: 190,
            borderRadius: "50%",
            background: "radial-gradient(circle at 35% 30%, #3aa0ff, #0a60d8 60%, #06357a)",
            boxShadow: "0 0 80px rgba(10,132,255,0.7), inset 0 0 0 1px rgba(255,255,255,0.25)",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            opacity: lockIn * (1 - lockOut),
            transform: `scale(${0.55 + 0.45 * lockIn + 0.6 * lockOut})`,
          }}
        >
          <LockKeyhole size={92} color="#fff" strokeWidth={2.2} />
        </div>
      )}
    </AbsoluteFill>
  );
};

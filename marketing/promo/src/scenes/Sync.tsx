import React from "react";
import { AbsoluteFill, Img, interpolate, random, staticFile, useCurrentFrame } from "remotion";
import { Cloud, Lock } from "lucide-react";
import { C, clamp, expo, fontFamily, ramp, sec, smooth } from "../theme";
import { MacWindow, Phone, fillMedia } from "../components/Devices";
import { Caption, Glow } from "../components/Overlays";

type P = { x: number; y: number };
const bez = (a: P, c: P, b: P, t: number): P => ({
  x: (1 - t) ** 2 * a.x + 2 * (1 - t) * t * c.x + t ** 2 * b.x,
  y: (1 - t) ** 2 * a.y + 2 * (1 - t) * t * c.y + t ** 2 * b.y,
});

const CLOUD: P = { x: 930, y: 175 };
const LEFT = { a: { x: 590, y: 170 }, c: { x: 700, y: 110 }, b: { x: 862, y: 176 } };
const RIGHT = { a: { x: 998, y: 176 }, c: { x: 1140, y: 110 }, b: { x: 1250, y: 262 } };

const Packet: React.FC<{ at: P; seed: string; opacity: number }> = ({ at, seed, opacity }) => {
  const hex = Array.from({ length: 4 }, (_, i) => "0123456789abcdef"[Math.floor(random(`${seed}${i}`) * 16)]).join("");
  return (
    <div
      style={{
        position: "absolute",
        left: at.x - 44,
        top: at.y - 15,
        height: 30,
        padding: "0 12px",
        borderRadius: 15,
        display: "flex",
        alignItems: "center",
        gap: 6,
        background: "rgba(10,132,255,0.2)",
        boxShadow: "inset 0 0 0 1px rgba(100,210,255,0.55), 0 0 18px rgba(10,132,255,0.45)",
        fontSize: 15,
        fontWeight: 600,
        color: C.cyan,
        fontVariantNumeric: "tabular-nums",
        opacity,
      }}
    >
      <Lock size={13} color={C.cyan} strokeWidth={2.4} />
      {hex}…
    </div>
  );
};

/** 55.2–60.0 s: phone and Mac in step, and only ciphertext in between. */
export const Sync: React.FC = () => {
  const f = useCurrentFrame();
  const enter = interpolate(f, [0, 40], [0, 1], { ...clamp, easing: expo });
  const arcs = ramp(f, 18, 50);
  const out = ramp(f, sec(4.6), sec(4.8), smooth);

  const packets = (arc: typeof LEFT, reverse: boolean, key: string) =>
    Array.from({ length: 3 }, (_, i) => {
      const speed = 1 / 70;
      const tRaw = ((f - 40) * speed + i / 3) % 1;
      if (f < 40) return null;
      const t = reverse ? 1 - tRaw : tRaw;
      const fade = Math.min(1, tRaw * 6, (1 - tRaw) * 6);
      return <Packet key={`${key}${i}`} at={bez(arc.a, arc.c, arc.b, t)} seed={`${key}${i}${Math.floor((f - 40) * speed + i / 3)}`} opacity={fade * arcs} />;
    });

  const path = (arc: typeof LEFT) => `M ${arc.a.x} ${arc.a.y} Q ${arc.c.x} ${arc.c.y} ${arc.b.x} ${arc.b.y}`;

  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out }}>
      <Glow x={CLOUD.x} y={CLOUD.y + 40} size={700} opacity={0.8 * arcs} />
      <Glow x={960} y={620} size={1400} color="rgba(94,92,230,0.18)" />

      <Phone height={600} style={{ left: 320, top: 150, opacity: enter, transform: `translateX(${(1 - enter) * -120}px)` }} glow={0.6}>
        <Img src={staticFile("footage/iphone-home.png")} style={fillMedia} />
      </Phone>
      <MacWindow width={780} style={{ left: 1060, top: 262, opacity: enter, transform: `translateX(${(1 - enter) * 120}px)` }}>
        <Img src={staticFile("footage/mac-main.png")} style={fillMedia} />
      </MacWindow>

      <svg width={1920} height={1080} style={{ position: "absolute", opacity: arcs }}>
        <path d={path(LEFT)} fill="none" stroke="rgba(100,210,255,0.5)" strokeWidth={2.5} strokeDasharray="3 10" strokeLinecap="round" />
        <path d={path(RIGHT)} fill="none" stroke="rgba(100,210,255,0.5)" strokeWidth={2.5} strokeDasharray="3 10" strokeLinecap="round" />
      </svg>
      {packets(LEFT, false, "l")}
      {packets(RIGHT, true, "r")}

      <div
        style={{
          position: "absolute",
          left: CLOUD.x - 70,
          top: CLOUD.y - 62,
          width: 140,
          height: 124,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          opacity: arcs,
          transform: `scale(${0.8 + 0.2 * arcs})`,
        }}
      >
        <Cloud size={140} color="#fff" strokeWidth={1.4} fill="rgba(255,255,255,0.06)" />
        <div style={{ position: "absolute", top: 52 }}>
          <Lock size={34} color={C.cyan} strokeWidth={2.4} />
        </div>
      </div>

      <Caption
        title="In sync. Still private."
        sub="End-to-end encrypted through your own iCloud. Only ciphertext ever leaves your devices."
        from={24}
        to={sec(4.8)}
        x={960}
        y={820}
        width={1300}
        size={62}
        align="center"
      />
    </AbsoluteFill>
  );
};

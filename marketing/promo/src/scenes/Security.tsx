import React from "react";
import { AbsoluteFill, interpolate, useCurrentFrame } from "remotion";
import { EyeOff, Flame, Keyboard, Lock, LockKeyhole, LogOut, ScanFace, ShieldAlert, Usb } from "lucide-react";
import { C, clamp, expo, fontFamily, ramp, reveal, sec, smooth } from "../theme";
import { Glow } from "../components/Overlays";

const CARDS = [
  { Icon: Lock, title: "AES-256 encryption", body: "Every wallet is sealed on your device before it is saved." },
  { Icon: ScanFace, title: "Face ID & Touch ID", body: "Opens for your face or your finger. Nobody else's." },
  { Icon: EyeOff, title: "Invisible to screenshots", body: "Revealed keys stay out of screenshots and recordings." },
  { Icon: LogOut, title: "Locks when you leave", body: "Step away from the app and the vault seals itself." },
  { Icon: Flame, title: "Self-destruct", body: "Too many wrong passwords and it erases itself." },
  { Icon: Usb, title: "USB security key", body: "Add a physical second key on your Mac." },
  { Icon: ShieldAlert, title: "Tamper detection", body: "Warns you if the vault file was changed." },
  { Icon: Keyboard, title: "Native keyboard only", body: "Third-party keyboards never see a thing." },
];

/**
 * 36.0–48.0 s: the build, the line, and eight reasons to trust it. The
 * trailer plays it from the slam with the cards arriving much faster.
 */
export const Security: React.FC<{ riseAt?: number; cardsAt?: number; cardStep?: number }> = ({
  riseAt = 4.8,
  cardsAt = 4.8,
  cardStep = 0.6,
}) => {
  const f = useCurrentFrame();
  const build = ramp(f, 0, sec(2.4), smooth);
  const dialOut = ramp(f, sec(2.4), sec(2.85));
  const hit = ramp(f, sec(2.4), sec(2.4) + 26);
  const flash = interpolate(f, [sec(2.4), sec(2.4) + 16], [0.55, 0], clamp);
  const rise = interpolate(f, [sec(riseAt), sec(riseAt + 0.5)], [0, 1], { ...clamp, easing: expo });
  const out = ramp(f, sec(11.55), sec(12.0), smooth);

  const spin = (speed: number) => f * speed * (1 + 2.2 * build);
  const ticks = (r: number, count: number, len: number, width: number, opacity: number) =>
    Array.from({ length: count }, (_, i) => {
      const a = (i / count) * Math.PI * 2;
      return (
        <line
          key={i}
          x1={Math.cos(a) * r}
          y1={Math.sin(a) * r}
          x2={Math.cos(a) * (r - len)}
          y2={Math.sin(a) * (r - len)}
          stroke={i % 5 === 0 ? C.cyan : "rgba(255,255,255,0.5)"}
          strokeWidth={width}
          opacity={opacity}
        />
      );
    });

  const col = 4, w = 392, h = 232, gap = 22;
  const x0 = (1920 - (col * w + (col - 1) * gap)) / 2;

  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out, filter: `blur(${out * 12}px)` }}>
      <Glow x={960} y={540} size={1200} opacity={0.3 + 0.6 * build * (1 - dialOut * 0.5)} />

      <svg
        width={1920}
        height={1080}
        style={{ position: "absolute", opacity: (0.25 + 0.75 * ramp(f, 0, 20)) * (1 - dialOut), transform: `scale(${1 + 0.5 * dialOut})`, transformOrigin: "960px 540px" }}
      >
        <g transform="translate(960 540)">
          <g transform={`rotate(${spin(0.35)})`}>{ticks(300, 120, 16, 2, 0.55)}</g>
          <g transform={`rotate(${-spin(0.6)})`}>{ticks(250, 60, 26, 3, 0.8)}</g>
          <circle r={196} fill="none" stroke="rgba(100,210,255,0.35)" strokeWidth={2} strokeDasharray="4 14" transform={`rotate(${spin(1.1)})`} />
          <circle r={150} fill="rgba(10,132,255,0.10)" stroke="rgba(100,210,255,0.55)" strokeWidth={2} />
        </g>
      </svg>
      <div
        style={{
          position: "absolute",
          left: 960 - 60,
          top: 540 - 60,
          opacity: 1 - dialOut,
          transform: `scale(${0.9 + 0.2 * build})`,
          filter: `drop-shadow(0 0 ${20 + 30 * build}px rgba(10,132,255,0.9))`,
        }}
      >
        <LockKeyhole size={120} color="#fff" strokeWidth={1.8} />
      </div>

      <div
        style={{
          position: "absolute",
          width: "100%",
          top: 470 - 330 * rise,
          textAlign: "center",
          opacity: hit,
          filter: `blur(${(1 - hit) * 18}px)`,
          transform: `scale(${(1.12 - 0.12 * hit) * (1 - 0.4 * rise)})`,
        }}
      >
        <div style={{ fontSize: 150, fontWeight: 800, letterSpacing: "-0.045em" }}>Built like a vault.</div>
      </div>

      {CARDS.map(({ Icon, title, body }, i) => {
        const x = x0 + (i % col) * (w + gap);
        const y = 330 + Math.floor(i / col) * (h + gap);
        const start = sec(cardsAt + i * cardStep);
        const style = reveal(f, start, Infinity, 24);
        const pop = ramp(f, start, start + 18);
        return (
          <div
            key={title}
            style={{
              position: "absolute",
              left: x,
              top: y,
              width: w,
              height: h,
              borderRadius: 28,
              background: "linear-gradient(180deg, rgba(255,255,255,0.075), rgba(255,255,255,0.03))",
              boxShadow: `inset 0 0 0 1px ${C.hairline}, 0 30px 60px rgba(0,0,0,0.45)`,
              padding: "30px 30px",
              boxSizing: "border-box",
              ...style,
            }}
          >
            <div
              style={{
                width: 60,
                height: 60,
                borderRadius: 18,
                background: "rgba(10,132,255,0.16)",
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                transform: `scale(${0.7 + 0.3 * pop})`,
              }}
            >
              <Icon size={32} color={C.blue} strokeWidth={2} />
            </div>
            <div style={{ marginTop: 22, fontSize: 30, fontWeight: 650, letterSpacing: "-0.02em" }}>{title}</div>
            <div style={{ marginTop: 8, fontSize: 20, fontWeight: 500, lineHeight: 1.35, color: C.dim }}>{body}</div>
          </div>
        );
      })}

      <AbsoluteFill style={{ background: "radial-gradient(circle at 50% 50%, rgba(255,255,255,0.9), rgba(10,132,255,0.3) 45%, rgba(0,0,0,0) 75%)", opacity: flash }} />
    </AbsoluteFill>
  );
};

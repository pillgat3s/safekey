import React from "react";
import { AbsoluteFill, Img, random, staticFile, useCurrentFrame } from "remotion";
import { C, fontFamily, reveal } from "../theme";

/** Moving film grain, very faint, over everything. */
export const Grain: React.FC = () => {
  const frame = useCurrentFrame();
  const x = Math.floor(random(`gx${Math.floor(frame / 2)}`) * 256);
  const y = Math.floor(random(`gy${Math.floor(frame / 2)}`) * 256);
  return (
    <AbsoluteFill
      style={{
        backgroundImage: `url(${staticFile("grain.png")})`,
        backgroundPosition: `${x}px ${y}px`,
        opacity: 0.045,
        mixBlendMode: "overlay",
        pointerEvents: "none",
      }}
    />
  );
};

export const Vignette: React.FC = () => (
  <AbsoluteFill
    style={{ background: "radial-gradient(ellipse at center, rgba(0,0,0,0) 55%, rgba(0,0,0,0.55) 100%)", pointerEvents: "none" }}
  />
);

/** A soft coloured light somewhere behind the action. */
export const Glow: React.FC<{ x: number; y: number; size: number; color?: string; opacity?: number }> = ({
  x,
  y,
  size,
  color = "rgba(10,132,255,0.35)",
  opacity = 1,
}) => (
  <div
    style={{
      position: "absolute",
      left: x - size / 2,
      top: y - size / 2,
      width: size,
      height: size,
      borderRadius: "50%",
      background: `radial-gradient(closest-side, ${color}, rgba(0,0,0,0))`,
      opacity,
      filter: "blur(20px)",
    }}
  />
);

/** Headline plus supporting line, the way Apple sets product copy. */
export const Caption: React.FC<{
  title: string;
  sub?: string;
  from: number;
  to: number;
  x: number;
  y: number;
  width?: number;
  size?: number;
  align?: "left" | "center";
}> = ({ title, sub, from, to, x, y, width = 620, size = 76, align = "left" }) => {
  const frame = useCurrentFrame();
  const lines = title.split("\n");
  return (
    <div
      style={{
        position: "absolute",
        left: align === "center" ? x - width / 2 : x,
        top: y,
        width,
        textAlign: align,
        fontFamily,
        color: C.text,
      }}
    >
      {lines.map((line, i) => (
        <div
          key={i}
          style={{
            fontSize: size,
            fontWeight: 700,
            letterSpacing: "-0.035em",
            lineHeight: 1.04,
            ...reveal(frame, from + i * 5, to),
          }}
        >
          {line}
        </div>
      ))}
      {sub && (
        <div
          style={{
            marginTop: size * 0.36,
            fontSize: size * 0.34,
            fontWeight: 500,
            lineHeight: 1.38,
            color: C.dim,
            letterSpacing: "-0.01em",
            ...reveal(frame, from + 10, to),
          }}
        >
          {sub}
        </div>
      )}
    </div>
  );
};

export const AppIcon: React.FC<{ size: number; style?: React.CSSProperties }> = ({ size, style }) => (
  <Img
    src={staticFile("footage/app-icon.png")}
    style={{
      width: size,
      height: size,
      borderRadius: size * 0.2237,
      boxShadow: "0 30px 80px rgba(0,0,0,0.6), inset 0 0 0 1px rgba(255,255,255,0.12)",
      ...style,
    }}
  />
);

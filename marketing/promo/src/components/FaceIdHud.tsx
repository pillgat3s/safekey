import React from "react";
import { interpolate } from "remotion";
import { clamp, expo, ramp, smooth } from "../theme";

/**
 * A face-scan glyph in a dark rounded square: brackets breathe while it
 * "looks", then the face gives way to a check mark. `frame` is local.
 */
export const FaceIdHud: React.FC<{ frame: number; size: number; matchAt: number; outAt: number }> = ({
  frame,
  size,
  matchAt,
  outAt,
}) => {
  const enter = ramp(frame, 0, 16);
  const exit = ramp(frame, outAt, outAt + 10, smooth);
  const breathe = frame < matchAt ? 1 - 0.06 * Math.sin((frame / 18) * Math.PI) ** 2 : 1;
  const faceOut = ramp(frame, matchAt, matchAt + 8, smooth);
  const check = interpolate(frame, [matchAt + 4, matchAt + 20], [0, 1], { ...clamp, easing: expo });
  const stroke = "#F5F5F7";
  return (
    <div
      style={{
        width: size,
        height: size,
        borderRadius: size * 0.24,
        background: "rgba(38,38,40,0.92)",
        boxShadow: "0 20px 60px rgba(0,0,0,0.5)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        opacity: enter * (1 - exit),
        transform: `scale(${0.86 + 0.14 * enter - 0.08 * exit})`,
      }}
    >
      <svg width={size * 0.56} height={size * 0.56} viewBox="0 0 100 100" fill="none">
        <g stroke={stroke} strokeWidth={6} strokeLinecap="round" style={{ transformOrigin: "50px 50px", transform: `scale(${breathe})` }}>
          {/* corner brackets */}
          <path d="M8 30 V14 a6 6 0 0 1 6-6 H30" opacity={1 - faceOut} />
          <path d="M70 8 H86 a6 6 0 0 1 6 6 V30" opacity={1 - faceOut} />
          <path d="M92 70 V86 a6 6 0 0 1-6 6 H70" opacity={1 - faceOut} />
          <path d="M30 92 H14 a6 6 0 0 1-6-6 V70" opacity={1 - faceOut} />
          {/* face */}
          <g opacity={1 - faceOut}>
            <path d="M34 36 V42" />
            <path d="M66 36 V42" />
            <path d="M51 36 V56 H46" />
            <path d="M36 67 Q50 77 64 67" />
          </g>
        </g>
        <path
          d="M26 52 L43 68 L75 34"
          stroke={stroke}
          strokeWidth={7}
          strokeLinecap="round"
          strokeLinejoin="round"
          pathLength={1}
          strokeDasharray={1}
          strokeDashoffset={1 - check}
        />
      </svg>
    </div>
  );
};

import React from "react";
import { AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { C, clamp, expo, fontFamily, ramp, reveal, sec, smooth } from "../theme";
import { IPad, MacWindow, Phone, fillMedia } from "../components/Devices";
import { Glow } from "../components/Overlays";

/** 60.0–62.4 s: one vault, three devices. */
export const Devices: React.FC = () => {
  const f = useCurrentFrame();
  const e = (delay: number) => interpolate(f, [delay, delay + 34], [0, 1], { ...clamp, easing: expo });
  const out = ramp(f, sec(2.2), sec(2.4), smooth);
  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out }}>
      <Glow x={960} y={520} size={1500} opacity={0.5} />
      <IPad width={900} style={{ left: 510, top: 110, opacity: e(0), transform: `translateY(${(1 - e(0)) * 90}px)` }}>
        <Img src={staticFile("footage/ipad-list.png")} style={fillMedia} />
      </IPad>
      <MacWindow width={700} style={{ left: 1170, top: 330, opacity: e(8), transform: `translateY(${(1 - e(8)) * 90}px)` }}>
        <Img src={staticFile("footage/mac-seed-revealed.png")} style={fillMedia} />
      </MacWindow>
      <Phone height={560} glow={0} style={{ left: 330, top: 330, opacity: e(4), transform: `translateY(${(1 - e(4)) * 90}px)` }}>
        <Img src={staticFile("footage/iphone-home.png")} style={fillMedia} />
      </Phone>
      <div style={{ position: "absolute", width: "100%", top: 930, textAlign: "center" }}>
        <div style={{ fontSize: 60, fontWeight: 700, letterSpacing: "-0.03em", ...reveal(f, 16) }}>iPhone. iPad. Mac.</div>
      </div>
    </AbsoluteFill>
  );
};

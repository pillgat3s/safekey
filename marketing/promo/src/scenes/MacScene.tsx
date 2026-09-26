import React from "react";
import { AbsoluteFill, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame } from "remotion";
import { C, clamp, expo, fontFamily, ramp, sec, smooth } from "../theme";
import { Fill, MacWindow, fillMedia } from "../components/Devices";
import { Caption, Glow } from "../components/Overlays";

const MAC = staticFile("footage/mac-tour.mp4");

const Segment: React.FC<{ at: number; len: number; src: number; fade?: boolean }> = ({ at, len, src, fade }) => (
  <Sequence from={sec(at)} durationInFrames={sec(len)} layout="none">
    <FadeIn enabled={!!fade}>
      <OffthreadVideo src={MAC} trimBefore={sec(src)} style={fillMedia} muted />
    </FadeIn>
  </Sequence>
);

const FadeIn: React.FC<{ enabled: boolean; children: React.ReactNode }> = ({ enabled, children }) => {
  const f = useCurrentFrame();
  return <Fill style={{ opacity: enabled ? ramp(f, 0, 10, smooth) : 1 }}>{children}</Fill>;
};

/** 48.0–55.2 s: the same vault on the Mac. */
export const MacScene: React.FC = () => {
  const f = useCurrentFrame();
  const enter = interpolate(f, [0, 46], [0, 1], { ...clamp, easing: expo });
  const drift = interpolate(f, [0, sec(7.2)], [0, 1], clamp);
  const out = ramp(f, sec(6.95), sec(7.2), smooth);
  const width = 1180;
  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text, opacity: 1 - out }}>
      <Glow x={1300} y={520} size={1300} color="rgba(94,92,230,0.30)" />
      <Glow x={1500} y={760} size={900} color="rgba(10,132,255,0.28)" />
      <div style={{ position: "absolute", inset: 0, perspective: 1800 }}>
        <MacWindow
          width={width}
          style={{
            left: 660,
            top: 170,
            opacity: enter,
            transformOrigin: "50% 100%",
            transform: `translateY(${(1 - enter) * 150}px) rotateX(${(1 - enter) * 18}deg) scale(${(0.92 + 0.08 * enter) * (1 + 0.04 * drift)})`,
          }}
        >
          <Segment at={0} len={4.8} src={3.2} />
          <Segment at={4.8} len={2.4} src={11.9} fade />
        </MacWindow>
      </div>
      <Caption
        title={"On your Mac,\ntoo."}
        sub="The same vault, with Touch ID and an optional USB security key."
        from={22}
        to={sec(7.1)}
        x={120}
        y={360}
        width={500}
        size={72}
      />
    </AbsoluteFill>
  );
};

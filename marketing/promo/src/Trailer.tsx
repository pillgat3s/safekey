import React from "react";
import { AbsoluteFill, Audio, Sequence, interpolate, staticFile, useCurrentFrame } from "remotion";
import { clamp, sec, smooth } from "./theme";
import { Grain, Vignette } from "./components/Overlays";
import { Intro } from "./scenes/Intro";
import { Logo } from "./scenes/Logo";
import { PhoneTour } from "./scenes/PhoneTour";
import { Screenshot } from "./scenes/Screenshot";
import { Security } from "./scenes/Security";
import { Devices } from "./scenes/Devices";
import { EndCard } from "./scenes/EndCard";

export const TRAILER_FRAMES = sec(20.4);

/** Plays `children` from its own second `from`, at trailer second `at`, for `len` seconds. */
const Cut: React.FC<{ at: number; len: number; from: number; children: React.ReactNode }> = ({ at, len, from, children }) => (
  <Sequence from={sec(at)} durationInFrames={sec(len)}>
    <Sequence from={-sec(from)} layout="none">
      {children}
    </Sequence>
  </Sequence>
);

/** The 20-second cut: one bar of the 100 BPM soundtrack per shot. */
export const Trailer: React.FC = () => {
  const frame = useCurrentFrame();
  const fadeOut = interpolate(frame, [sec(19.4), sec(20.4)], [0, 1], { ...clamp, easing: smooth });
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <Cut at={0} len={2.4} from={7.2}><Intro /></Cut>
      <Cut at={2.4} len={2.4} from={0}><Logo taglineAt={62} /></Cut>
      <Cut at={4.8} len={2.4} from={4.8}><PhoneTour /></Cut>
      <Cut at={7.2} len={2.4} from={12.0}><PhoneTour /></Cut>
      <Cut at={9.6} len={2.4} from={0}><Screenshot /></Cut>
      <Cut at={12.0} len={2.4} from={2.4}><Security riseAt={3.2} cardsAt={3.35} cardStep={0.1} /></Cut>
      <Cut at={14.4} len={2.4} from={0}><Devices /></Cut>
      <Cut at={16.8} len={3.6} from={0}><EndCard /></Cut>
      <Vignette />
      <Grain />
      <AbsoluteFill style={{ background: "#000", opacity: Math.max(interpolate(frame, [0, 10], [1, 0], clamp), fadeOut), pointerEvents: "none" }} />
      <Audio src={staticFile("audio/soundtrack-trailer.wav")} />
    </AbsoluteFill>
  );
};

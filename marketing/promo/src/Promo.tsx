import React from "react";
import { AbsoluteFill, Audio, Sequence, interpolate, staticFile, useCurrentFrame } from "remotion";
import { clamp, sec } from "./theme";
import { Grain, Vignette } from "./components/Overlays";
import { Intro } from "./scenes/Intro";
import { Logo } from "./scenes/Logo";
import { PhoneTour } from "./scenes/PhoneTour";
import { Screenshot } from "./scenes/Screenshot";
import { Security } from "./scenes/Security";
import { MacScene } from "./scenes/MacScene";
import { Sync } from "./scenes/Sync";
import { Devices } from "./scenes/Devices";
import { Outro } from "./scenes/Outro";
import { EndCard } from "./scenes/EndCard";

export const PROMO_FRAMES = sec(75);

/** Scene boundaries in seconds; every one falls on a bar of the 100 BPM soundtrack. */
const SCENES: [number, number, React.FC][] = [
  [0, 9.6, Intro],
  [9.6, 14.4, Logo],
  [14.4, 32.4, PhoneTour],
  [32.4, 36.0, Screenshot],
  [36.0, 48.0, Security],
  [48.0, 55.2, MacScene],
  [55.2, 60.0, Sync],
  [60.0, 62.4, Devices],
  [62.4, 67.2, Outro],
  [67.2, 75.0, EndCard],
];

export const Promo: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      {SCENES.map(([from, to, Scene]) => (
        <Sequence key={from} from={sec(from)} durationInFrames={sec(to) - sec(from)}>
          <Scene />
        </Sequence>
      ))}
      <Vignette />
      <Grain />
      <AbsoluteFill style={{ background: "#000", opacity: interpolate(frame, [0, 12], [1, 0], clamp), pointerEvents: "none" }} />
      <Audio src={staticFile("audio/soundtrack.wav")} />
    </AbsoluteFill>
  );
};

import React from "react";
import { AbsoluteFill, Img, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame } from "remotion";
import { C, clamp, expo, fontFamily, ramp, sec, smooth } from "../theme";
import { Fill, Phone, fillMedia } from "../components/Devices";
import { Caption, Glow } from "../components/Overlays";
import { FaceIdHud } from "../components/FaceIdHud";

const TOUR = staticFile("footage/iphone-tour.mp4");
const UNLOCK = staticFile("footage/iphone-unlock.mp4");

/** Where the phone stands for the whole tour (and where the next scene picks it up). */
export const PHONE_HEIGHT = 880;
export const PHONE_LEFT = 1040;
export const PHONE_TOP = 100;

/** One stretch of screen recording: `at` and `len` in scene seconds, `src` in recording seconds. */
const Clip: React.FC<{ at: number; len: number; src: number; video?: string; fade?: boolean }> = ({
  at,
  len,
  src,
  video = TOUR,
  fade = false,
}) => (
  <Sequence from={sec(at)} durationInFrames={sec(len)} layout="none">
    <FadeIn enabled={fade}>
      <OffthreadVideo src={video} trimBefore={sec(src)} style={fillMedia} muted />
    </FadeIn>
  </Sequence>
);

const FadeIn: React.FC<{ enabled: boolean; children: React.ReactNode }> = ({ enabled, children }) => {
  const f = useCurrentFrame();
  return <Fill style={{ opacity: enabled ? ramp(f, 0, 9, smooth) : 1 }}>{children}</Fill>;
};

const LockAndScan: React.FC = () => {
  const f = useCurrentFrame();
  return (
    <Fill>
      <Img src={staticFile("footage/iphone-lock.png")} style={fillMedia} />
      {/* Up in the empty band above the lock icon, clear of the title. */}
      <Fill style={{ display: "flex", justifyContent: "center", paddingTop: "15%" }}>
        {f >= 10 && <FaceIdHud frame={f - 10} size={124} matchAt={50} outAt={72} />}
      </Fill>
    </Fill>
  );
};

/** 14.4–32.4 s: the iPhone, from the vault's home to a revealed key. */
export const PhoneTour: React.FC = () => {
  const f = useCurrentFrame();
  const enter = ramp(f, 0, 50);
  // Push in on the key row while it is revealed, then settle back.
  const push = interpolate(f, [sec(12.2), sec(12.9), sec(14.2), sec(14.7)], [0, 1, 1, 0], { ...clamp, easing: expo });
  const scale = 1 + 0.3 * push;
  const originY = PHONE_TOP + PHONE_HEIGHT * 0.54;
  return (
    <AbsoluteFill style={{ background: "#000", fontFamily, color: C.text }}>
      <Glow x={1250} y={560} size={1000} opacity={0.55} />
      <div
        style={{
          position: "absolute",
          inset: 0,
          transformOrigin: `1250px ${originY}px`,
          transform: `translateY(${(1 - enter) * 820}px) rotate(${(1 - enter) * 6}deg) scale(${scale})`,
        }}
      >
        <Phone height={PHONE_HEIGHT} style={{ left: PHONE_LEFT, top: PHONE_TOP }}>
          <Clip at={0} len={4.8} src={16.45} />
          <Sequence from={sec(4.8)} durationInFrames={sec(1.5)} layout="none">
            <LockAndScan />
          </Sequence>
          <Clip at={6.3} len={1.7} src={0.75} video={UNLOCK} />
          <Clip at={8.0} len={2.8} src={24.1} />
          <Clip at={10.8} len={1.2} src={28.85} />
          <Clip at={12.0} len={2.4} src={32.6} />
          <Clip at={14.4} len={2.4} src={44.0} fade />
          <Clip at={16.8} len={1.2} src={34.2} fade />
        </Phone>
      </div>

      <Caption title={"Every key.\nOne vault."} sub="Seed phrases and private keys for every chain, encrypted on your device." from={30} to={276} x={150} y={340} />
      <Caption title={"Opens with\na glance."} sub="Face ID on iPhone and iPad. Touch ID on the Mac." from={sec(5.0)} to={sec(9.35)} x={150} y={360} />
      <Caption title={"Hidden until\nyou ask."} sub="Keys stay masked. Tap to reveal, tap again to hide." from={sec(9.8)} to={sec(14.15)} x={150} y={360} />
      <Caption title={"Every word,\nin order."} sub="12 or 24 words, numbered the way you wrote them down." from={sec(14.6)} to={sec(16.8)} x={150} y={360} />
      <Caption title={"Now take a\nscreenshot."} from={sec(16.9)} to={sec(18.4)} x={150} y={400} />
    </AbsoluteFill>
  );
};

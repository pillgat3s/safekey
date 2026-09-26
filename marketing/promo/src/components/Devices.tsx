import React from "react";

/** Screen aspect of the recorded iPhone (1206 × 2622). */
export const PHONE_ASPECT = 1206 / 2622;

/** An iPhone in titanium, drawn around whatever fills its screen. */
export const Phone: React.FC<{
  height: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
  glow?: number;
}> = ({ height, children, style, glow = 1 }) => {
  const bezel = height * 0.017;
  const screenH = height - 2 * bezel;
  const screenW = screenH * PHONE_ASPECT;
  const width = screenW + 2 * bezel;
  const rScreen = screenW * 0.14;
  const rOuter = rScreen + bezel;
  const button = (side: "left" | "right", top: number, h: number) => (
    <div
      style={{
        position: "absolute",
        [side]: -height * 0.0045,
        top: height * top,
        width: height * 0.006,
        height: height * h,
        borderRadius: 3,
        background: "linear-gradient(90deg,#2a2a2c,#58585c,#2a2a2c)",
      }}
    />
  );
  return (
    <div style={{ position: "absolute", width, height, ...style }}>
      {glow > 0 && (
        <div
          style={{
            position: "absolute",
            inset: -height * 0.22,
            background: "radial-gradient(closest-side, rgba(10,132,255,0.32), rgba(10,132,255,0) 70%)",
            opacity: glow,
            filter: "blur(30px)",
          }}
        />
      )}
      {button("left", 0.19, 0.045)}
      {button("left", 0.265, 0.075)}
      {button("left", 0.355, 0.075)}
      {button("right", 0.29, 0.115)}
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: rOuter,
          padding: 2.5,
          boxSizing: "border-box",
          background: "linear-gradient(150deg,#7c7c81 0%,#3a3a3d 18%,#1d1d1f 50%,#2f2f32 78%,#6a6a6f 100%)",
          boxShadow: "0 70px 140px rgba(0,0,0,0.65), 0 24px 48px rgba(0,0,0,0.5)",
        }}
      >
        <div
          style={{
            width: "100%",
            height: "100%",
            borderRadius: rOuter - 2.5,
            background: "#050505",
            padding: bezel - 2.5,
            boxSizing: "border-box",
          }}
        >
          <div
            style={{
              position: "relative",
              width: screenW,
              height: screenH,
              borderRadius: rScreen,
              overflow: "hidden",
              background: "#000",
            }}
          >
            {children}
            <div
              style={{
                position: "absolute",
                left: "50%",
                top: screenH * 0.0126,
                width: screenW * 0.313,
                height: screenH * 0.0423,
                transform: "translateX(-50%)",
                borderRadius: 999,
                background: "#000",
              }}
            />
          </div>
        </div>
      </div>
    </div>
  );
};

/** Fills a device screen edge to edge. */
export const Fill: React.FC<{ children: React.ReactNode; style?: React.CSSProperties }> = ({ children, style }) => (
  <div style={{ position: "absolute", inset: 0, ...style }}>{children}</div>
);

export const fillMedia: React.CSSProperties = { width: "100%", height: "100%", objectFit: "cover", display: "block" };

/** A Mac window floating with its shadow; the capture already carries the chrome. */
export const MacWindow: React.FC<{
  width: number;
  aspect?: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ width, aspect = 1.6, children, style }) => (
  <div
    style={{
      position: "absolute",
      width,
      height: width / aspect,
      borderRadius: width * 0.015,
      overflow: "hidden",
      background: "#1e1e1e",
      boxShadow: "0 60px 140px rgba(0,0,0,0.7), 0 20px 50px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.12)",
      ...style,
    }}
  >
    {children}
  </div>
);

/** A landscape iPad around its screen (2752 × 2064). */
export const IPad: React.FC<{ width: number; children: React.ReactNode; style?: React.CSSProperties }> = ({
  width,
  children,
  style,
}) => {
  const bezel = width * 0.022;
  const screenW = width - 2 * bezel;
  const screenH = screenW * (2064 / 2752);
  const r = width * 0.035;
  return (
    <div
      style={{
        position: "absolute",
        width,
        height: screenH + 2 * bezel,
        borderRadius: r,
        padding: 2.5,
        boxSizing: "border-box",
        background: "linear-gradient(150deg,#7c7c81 0%,#3a3a3d 20%,#1d1d1f 55%,#5a5a5e 100%)",
        boxShadow: "0 60px 130px rgba(0,0,0,0.65)",
        ...style,
      }}
    >
      <div
        style={{
          width: "100%",
          height: "100%",
          borderRadius: r - 2.5,
          background: "#050505",
          padding: bezel - 2.5,
          boxSizing: "border-box",
        }}
      >
        <div style={{ position: "relative", width: screenW, height: screenH, borderRadius: r * 0.55, overflow: "hidden" }}>
          {children}
        </div>
      </div>
    </div>
  );
};

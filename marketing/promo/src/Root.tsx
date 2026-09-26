import { Composition } from "remotion";
import { Promo, PROMO_FRAMES } from "./Promo";
import { Trailer, TRAILER_FRAMES } from "./Trailer";
import { FPS } from "./theme";

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="SafeKeyPromo" component={Promo} durationInFrames={PROMO_FRAMES} fps={FPS} width={1920} height={1080} />
    <Composition id="SafeKeyTrailer" component={Trailer} durationInFrames={TRAILER_FRAMES} fps={FPS} width={1920} height={1080} />
  </>
);

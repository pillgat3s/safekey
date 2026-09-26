// Renders stills of the film at the given seconds, from one bundle.
// node tools/stills.mjs <out-dir> <sec> [sec...]
import path from "node:path";
import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";

// COMPOSITION=SafeKeyTrailer picks the trailer instead of the full film.
const [outDir, ...times] = process.argv.slice(2);
const serveUrl = await bundle({ entryPoint: path.resolve("src/index.ts") });
const composition = await selectComposition({ serveUrl, id: process.env.COMPOSITION ?? "SafeKeyPromo" });
for (const t of times) {
  const frame = Math.min(composition.durationInFrames - 1, Math.round(Number(t) * composition.fps));
  const output = path.join(outDir, `still-${String(t).padStart(5, "0")}.jpeg`);
  await renderStill({ serveUrl, composition, frame, output, imageFormat: "jpeg", jpegQuality: 85, scale: 0.5 });
  console.log("rendered", t, "->", output);
}

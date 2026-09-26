# SafeKey promotional film

Two cuts, composed as code with [Remotion](https://www.remotion.dev) at
1920 × 1080, 60 fps:

| Composition | Length | Output |
|---|---|---|
| `SafeKeyPromo` | 75 s | the full film |
| `SafeKeyTrailer` | 20.4 s | one bar of music per shot |

Everything on screen is the real app running a demo vault of invented
wallets (`Sources/SafeKeyShared/PromoContent.swift`, debug builds only). The
music is arranged from Apple Loops and Final Cut Pro sound effects, which
Apple licenses for use in your own soundtracks; the loops themselves are
read from `/Library/Audio/Apple Loops` and are never copied into the repo.

## Pipeline

Footage, audio and `node_modules` are not committed; each step rebuilds them.

1. **Music** — needs Logic Pro's or GarageBand's loop library and Final Cut
   Pro's sound effects installed.
   ```bash
   python3 -m venv .venv && .venv/bin/pip install numpy scipy
   python3 tools/catalog_loops.py
   tools/master.sh full && tools/master.sh trailer
   ```
2. **iPhone and iPad** — the `PromoTourUITests` walk through a seeded demo
   vault; they skip themselves unless asked for. Set the simulator up first:
   dark mode, `xcrun simctl status_bar <udid> override --time 9:41 …`, Face ID
   enrolled, and `scripts/simulator_faceid_match.sh <udid> 400` running.
   ```bash
   tools/record_ios.sh <iphone-udid> raw/iphone-tour SafeKeyiOSUITests/PromoTourUITests/testTour
   tools/record_ios.sh <iphone-udid> raw/iphone-faceid SafeKeyiOSUITests/PromoTourUITests/testFaceIDShot
   tools/record_ios.sh <iphone-udid> raw/iphone-protected SafeKeyiOSUITests/PromoTourUITests/testProtectedScreenshot
   tools/record_ios.sh <ipad-udid> raw/ipad-tour SafeKeyiOSUITests/PromoTourUITests/testTouriPad
   ```
3. **Mac** — `PromoDirector` records the app's own window, which needs no
   screen-recording permission. A demo window appears for about 25 seconds.
   ```bash
   tools/film_mac.sh raw/mac
   ```
4. **Footage** — `tools/prepare_footage.sh raw`. The source times in
   `src/scenes` belong to one recording; after re-recording, re-find the taps.
5. **Render**
   ```bash
   npm install
   npx remotion render SafeKeyPromo out/safekey-promo.mp4
   npx remotion render SafeKeyTrailer out/safekey-trailer.mp4
   ```
   `npm run studio` previews both; `node tools/stills.mjs <dir> <seconds…>`
   renders review stills (`COMPOSITION=SafeKeyTrailer` for the trailer).

## Credits

Type is [Inter](https://rsms.me/inter/) (SIL Open Font License), icons are
[Lucide](https://lucide.dev) (ISC). Remotion is free for individuals and
companies of up to three people; larger teams need a company licence.

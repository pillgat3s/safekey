# Capturing the demo vault

Tools for recording the real app running the demo vault of invented burner
wallets (`Sources/SafeKeyShared/PromoContent.swift`, debug builds only). The
website's screenshots come from here.

- `record_ios.sh <udid> <out> <test>` records the simulator while one
  `PromoTourUITests` test walks the app. Set the simulator up first: dark
  mode, `xcrun simctl status_bar <udid> override --time 9:41 …`, and for the
  Face ID shot `scripts/simulator_faceid_match.sh <udid> 400` running.
- `film_mac.sh <out-dir>` runs a copy of the debug Mac build under
  `PromoDirector`, which captures the app's own window (no screen-recording
  permission needed) and writes `mac-main.png`, `mac-detail-revealed.png`,
  `mac-seed-revealed.png`, `mac-chain.png`, `mac-lock.png` and a tour movie.
  Build first with `xcodebuild … -scheme SafeKey -derivedDataPath build/mac
  -allowProvisioningUpdates build`.

For still images on the iPhone, `SiteStillsUITests` is simpler than a
recording: `TEST_RUNNER_SAFEKEY_SITE_STILLS=1 xcodebuild … -only-testing:SafeKeyiOSUITests/SiteStillsUITests test-without-building`
writes PNGs into the test runner's container.

Recordings, stills and build products stay out of git.

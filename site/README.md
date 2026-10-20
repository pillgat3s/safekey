# SafeKey website

Static site for https://safekey.tws.sh — the product page, the privacy policy
(`/privacy`) and support (`/support`). No build step: edit the files in
`dist/` directly. Hosted on Cloudflare Workers Static Assets as the worker
`safekey-site`, with `safekey.tws.sh` as its custom domain, next to the
`tws-website` worker that serves tws.sh.

Publish:

```sh
cd site
npm ci
npm run deploy
```

`npx wrangler login` only if the Cloudflare session has expired.

Screenshots in `dist/assets/` come from the demo vault:
`Tests/SafeKeyiOSUITests/SiteStillsUITests.swift` for the iPhone
(`TEST_RUNNER_SAFEKEY_SITE_STILLS=1 xcodebuild … test-without-building`) and
`marketing/promo/tools/film_mac.sh` for the Mac. The copy follows
`marketing/launch/` and the positioning in `marketing/launch/copy-audit.md`.

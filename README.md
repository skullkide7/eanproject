# EAN Shopper — Meta Ray-Ban Display hackathon prototype

iOS app: scan a product EAN (or ask by name/voice) and get the real price at
the nearest store, plus nearby competitors — PAK'nSAVE + New World, all NZ.

- Fullscreen camera scan, GPS nearest-store left + ≤5 km alternatives right.
- Name/voice search with on-device query understanding (no price ever comes
  from AI — always from the database).
- Voice + UI in the device language (EN ES ZH PT DE JA IT FR HI, EN default).
- Meta glasses support via the Wearables DAT SDK (camera, display, inputs,
  speech); works with the iPhone camera when no glasses are around.

## Run it (judges)

Requirements: a Mac with Xcode 26, a physical iPhone, a free Apple developer
team (for signing). No backend setup — prices come from a live Supabase DB.

1. Open `ios/EANShopper.xcodeproj` in Xcode
   (generated with `xcodegen generate` from `ios/project.yml` — rerun it if
   you add files under `ios/Sources` or `ios/Tests`).
2. Set your own Team in Signing & Capabilities.
3. Press ⌘R with your iPhone connected. Grant camera, location and
   microphone/speech permissions when asked.
4. Point at any NZ supermarket barcode, or menu → Search by name and ask
   (e.g. “how much is pasta?”). Prices + spoken answer follow.

Tests: the `EANShopper` scheme has a test action — ⌘U on device.

## Branches

- `main` — stable snapshot.
- `busqueda-por-nombre` — latest (name/voice search, glasses action button,
  enhancedVoice guidance).

## Notes

- Backend: live Supabase (São Paulo region), public read-only. Daily price
  refresh runs separately with the marketplace scraper (needs an NZ IP).
- Real glasses are optional: DEBUG builds include mock simulation
  (Simulate / Test display / Test button / Test dictation in the menu).
  Real glasses need Meta AI app registration + the MWDAT block from the
  Developer Center in `ios/Sources/Info.plist`.
- No secrets in this repo: the Supabase key is the public publishable key,
  the Meta token is the public client token (both ship inside the app).

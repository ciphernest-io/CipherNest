# CipherNest — App UI Kit

Interactive, mostly-cosmetic React recreation of the CipherNest Android app. Built on the
shared design foundation (`../../styles.css` — the 7-theme system — plus self-hosted Material
Symbols). Set `data-theme` + `data-mode` on `<html>` to theme it.

## Run it
Open `index.html`. It boots a click-through prototype:

**Lock → unlock (tap the fingerprint) → Your Vault → tap "Photos & Videos" → Gallery →
tap any photo → immersive Viewer.** The **+** FAB opens the upload bottom sheet; the
**Settings** tab includes a live accent-color picker that re-themes the whole app.

## Files
- `index.html` — shell + app-specific composite CSS (vault card, account chip, storage meter) + React/Babel bootstrap.
- `components.jsx` — reusable primitives, exported to `window`:
  `StatusBar`, `PhoneShell`, `IconBtn`, `AppBar`, `TabBar`, `Row`, `Pill`, `Btn`, `Sheet`, `VaultCard`.
- `app.jsx` — screen components (`Lock`, `Home`, `Gallery`, `Viewer`, `Settings`, `UploadSheet`) + the `App` router/state.

## Notes
- These are simplified visual recreations, not production code — no real crypto, auth, or storage.
- Photos are `picsum.photos` placeholders. Swap for real encrypted thumbnails in production.
- Icons use the self-hosted Phosphor font (thin = default, fill = active/selected).
- The kit is the canonical reference for how primitives compose into real screens; the
  full set of 24 static screens lives in `../../screens/` and is browsable via `../../Screens.html`.

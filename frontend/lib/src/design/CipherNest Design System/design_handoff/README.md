# Handoff: CipherNest Design Language + 7-Theme System

## Overview
This bundle is the **CipherNest design system** — a 7-theme token architecture (Binary, Burrow,
Corporate, Alien, Paper, Garnet, Hackerman), each with a **dark and light mode**, plus a
component library, motion system, self-hosted fonts, self-hosted Material Symbols icons, brand
logo (accent-tinted), and per-theme imagery. Your task: **adopt this design language across your
existing app**, mapping it onto your real components/screens.

## About the design files
The files here are **design references created in HTML/CSS** — the *intended look, tokens, and
behavior*, not production components to paste in. Recreate them in **your codebase's existing
environment** (React/Vue/SwiftUI/etc.) using your established patterns. The **CSS token layer
(`themes.css`), `app.css`, `motion.css`, the fonts, the icons, and the assets are directly
portable** — copy them as-is. The HTML screens are the visual spec to match.

## Fidelity
**High-fidelity.** Exact colors, typography, radii, spacing, and icon axes are all defined as
tokens in `themes.css`. Match them precisely.

---

## How to adopt this without breaking your app (the safe path)

Do it **additively and incrementally**, never big-bang:

1. **Drop in the token + font layer first (zero visual change yet).**
   Copy these into your project (e.g. under `src/design/ciphernest/`):
   `themes.css`, `app.css`, `motion.css`, `fonts/` (all woff2 + `material.css`),
   `assets/` (logos + card art + textures), `theme-switch.js`, `cipher-fx.js`.
   Import `themes.css` once at the app root. Set `data-theme="binary" data-mode="dark"` on
   `<html>`. Nothing of yours changes yet — these are new CSS custom properties on `:root`.

2. **Adopt the tokens in your own components — don't replace your components.**
   The win is that your existing buttons/cards/inputs keep their structure; you only swap
   **hardcoded values → CSS variables**. Example:
   `background:#1E1E1E` → `background:var(--surface)`; `color:#fff` → `color:var(--fg)`;
   `border-radius:8px` → `border-radius:var(--r-card)`; brand blue → `var(--accent)`.
   Because every theme defines the same variable names, your components instantly support all
   7 themes × 2 modes once they read tokens.

3. **Migrate screen-by-screen, behind your existing tests.**
   Convert one screen, verify it in 2–3 themes + light/dark, commit, move on. Keep a visual
   diff / Storybook page per component. The token names never change between themes, so a
   component that reads tokens can't "break per theme" — it just recolors.

4. **Icons:** replace your icon usage with Material Symbols `<span class="mi">name</span>`
   (`fill` class for active). The cut (Outlined/Rounded/Sharp) + weight/grade are theme tokens,
   so don't hardcode them. `fonts/_icon_map.json` lists the names already in use.

5. **Logo + imagery per theme:** the logo mark is tinted with `var(--accent)` via CSS mask
   (see below) — one asset, every theme color, both modes. Card imagery is chosen by the
   `--card-art` token per theme/mode (dark + light variants).

**What can break, and how to avoid it:**
- *Global CSS collisions* — scope this system under a wrapper class or layer if your app has
  aggressive global selectors. `app.css` class names are generic (`.row`, `.card`, `.btn`); if
  those collide, prefix them (e.g. `.cn-row`) during import.
- *Hardcoded colors left behind* — grep for hex codes after each screen; any literal that
  should theme must become a `var(--…)`.
- *Fonts/icons not loading* — they are **self-hosted on purpose** (the Google Fonts CDN was
  unreliable). Keep them self-hosted; copy the whole `fonts/` folder.
- *Transition stick on theme switch* — when you flip `data-theme`/`data-mode`, add a
  `.switching` class for one frame (see `theme-switch.js`) so `var()`-backed transitions snap
  instead of animating from the old value (a Chrome quirk).

---

## The token contract (what every theme guarantees)
Set `<html data-theme="<pack>" data-mode="<dark|light>">`. Each theme defines, per mode:

- **Surfaces:** `--bg --panel --surface --surface-2 --hairline --scrim`
- **Text:** `--fg --fg-2 --fg-muted --fg-faint --on-accent`
- **Accent:** `--accent --accent-press --accent-soft --accent-faint`
- **Semantics:** `--success --warning --danger --info`
- **Radii:** `--r-input --r-card --r-card-lg --r-sheet --r-pill --r-ic`
- **Density:** `--pad --row-h`
- **Motion:** `--ease --ease-out --dur-fast --dur --dur-slow`
- **Type:** `--font --title-font --font-mono` (+ constant `--font-wm` = Bungee Hairline wordmark)
- **Icons:** `--icon-font --icon-fill --icon-wght --icon-wght-fill --icon-grad`
- **Flair (optional):** `--card-art` (Photos-card bg), `--app-tex` / `--app-tex-op` (app-wide texture)

Themes: `binary` (default, monochrome) · `burrow` (earthy) · `corporate` (steel) ·
`alien` (obsidian+lime) · `paper` (vellum+gold) · `garnet` (charcoal+crimson) ·
`hackerman` (neon). Full per-theme value table is in the top-level `README.md`.

## Accent-tinted logo (one asset, every theme)
```html
<span class="logo-mark"></span>
```
```css
.logo-mark{ width:28px; height:26px; background:var(--accent);
  -webkit-mask:url(assets/logo_mark_white.png) center/contain no-repeat;
  mask:url(assets/logo_mark_white.png) center/contain no-repeat; }
```
Wordmark "Cipher**Nest**" is always **Bungee Hairline weight 800**, with "Nest" in `var(--accent)`.

## Per-theme imagery (light + dark)
Each theme's hero/Photos imagery has a **dark** and a **light** variant, selected by the
`--card-art` token (e.g. `assets/card-earth-{dark,light}.png` for Burrow). They were produced by
processing source photos (dim/wash/mask) so text stays legible. Your originals live in your
project at `assets/images/` — see "Assets" below for how to regenerate or reuse.

---

## Assets (and the question about your webp files)
**You have two options — either works:**

- **Easiest — reuse the processed art in this bundle.** `assets/card-*-dark.png` /
  `card-*-light.png` are the finished, dimmed/tinted versions wired to `--card-art`. Copy the
  `assets/` folder as-is and you're done. You do **not** need to re-supply the original webps.
- **Regenerate from your originals.** If you'd rather your app own the originals in
  `assets/images/`, give your coding agent those files and the recipe: scale to cover the card,
  apply the per-theme dim/tint overlay (dark: ~30–60% dark wash; light: ~30–45% light wash;
  Alien adds a green color pass; Binary desaturates), export `-dark` and `-light` PNGs, and
  point `--card-art` at them. Theme→source mapping:
  Binary→binary digits · Burrow→soil+sprout · Corporate→glass towers · Alien→UFO ·
  Paper→handwritten letter · Garnet→red marble · Hackerman→Matrix code-rain.

Logos: `assets/logo_mark_{white,black,brass,violet}.png` (use `white` as the mask source; it
tints to any accent). Fonts: everything in `fonts/` is self-hosted and license-clean
(Material Symbols + Google Fonts OFL faces; Carattere from Google Fonts).

---

## Files in this bundle
- `themes.css` — the 7-theme × 2-mode token source (+ self-hosted `@font-face`s + `.mi` helper).
- `app.css` — component library (shell, app bar, rows, cards, pills, sheets, buttons, inputs,
  gallery grid, FAB, `.t-*` type scale, card-art / app-tex layers).
- `motion.css` — token-driven, screenshot/print-safe motion.
- `theme-switch.js` — floating theme/mode switcher (localStorage + `?t=&m=` params + `.switching` guard).
- `cipher-fx.js` — signature scramble/decrypt text effect.
- `fonts/` — Material Symbols (3 cuts) + every theme font, self-hosted.
- `assets/` — logos + per-theme card art (dark+light) + textures.
- `screens/` — the 24 reference screens (visual spec to match).
- `ui_kits/app/` — interactive React recreation showing how components compose.
- `README.md` (top level) — full system documentation incl. the per-theme value table.

## How to hand this to your coding agent
1. **Download** this project (button in chat) and unzip the design-system files into your repo
   (e.g. `src/design/ciphernest/`). You reference files by **path in the repo** — you do *not*
   paste them into the prompt.
2. Open your coding agent in your repo and use a prompt like the one in `AGENT_PROMPT.md` (next
   to this file).

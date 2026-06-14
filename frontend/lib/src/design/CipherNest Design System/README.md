# CipherNest — Design System

> **Private cloud, on your terms.**
> Zero-knowledge encrypted cloud storage for Android. CipherNest layers AES-256 encryption
> over the user's *own* Google Drive or OneDrive — files are encrypted on-device before they
> leave the phone, so the cloud provider only ever sees opaque ciphertext.

This repository is a self-contained design system: brand assets, a **7-theme token
architecture**, a component library, 24 product screens, an interactive UI kit, and a motion
system. Any design agent can produce on-brand CipherNest interfaces in any of the seven themes.

---

## Product context

- **What it is:** A consumer photo/file vault. Comfort of iCloud Photos, with cryptographic
  guarantees. The user brings their own cloud; CipherNest manages encryption, gallery, sharing,
  and recovery.
- **Audience:** Privacy-conscious individuals — students, journalists, creators — who want
  serious security without a hacker aesthetic.
- **Tone:** Trustworthy, calm, premium, technically credible. Never preachy or fear-mongering.
- **Design ancestor:** Samsung Gallery (One UI) — edge-to-edge photo grids, draggable
  filmstrips, immersive gesture-rich viewers.

### Sources provided
- `assets/logo_mark_{white,black,brass,violet}.png` — the woven-nest mark (interlaced orbital
  rings cradling a small "egg" — Cipher + Nest).
- `fonts/Inter-*.ttf` — original brand typeface (retained; superseded per-theme, see below).
- A detailed written brief. No codebase or Figma — all visuals are built from the brief.

---

## ★ Theme architecture (the heart of the system)

CipherNest ships **seven complete themes ("packs"), each with a dark and a light mode**. A pack
is a token bundle that swaps **color + fonts + corner radius + density + motion + icon style**
together — layout and components never change, they only read tokens. Set two attributes on
`<html>`:

```html
<html data-theme="binary" data-mode="dark">
```

`data-theme` ∈ `binary · burrow · corporate · alien · paper · garnet · hackerman`
`data-mode`  ∈ `dark · light`  · default (no attrs) = **Binary / dark**.

The **CipherNest wordmark is always Bungee Hairline (weight 800)** — the one fixed brand anchor
across every theme. The logo mark is tinted to `var(--accent)` via CSS mask.

| Theme | Identity | Accent | Font (UI + titles) | Icon cut | Photos-card art |
|---|---|---|---|---|---|
| **Binary** *(default)* | Pure monochrome black/white/grey | near-white / near-black | Hanken Grotesk | Outlined · wght 100 | binary digits |
| **Burrow** | Earthy soil, very round | clay-amber `#BC8645` | IM Fell English | Rounded · fill · grade 200 | soil + sprout |
| **Corporate** | Cool steel slate, dense, sharp | blue `#5E92F5` | Google Sans Flex | Sharp · wght 300 | glass towers |
| **Alien** | Obsidian + gooey lime | lime `#93E03C` | Snowburst One | Rounded · fill · wght 700 | UFO silhouette |
| **Paper** | Black vellum + gold ink | gold `#CBA15A` | Carattere (script) | Outlined · wght 200 | handwritten letter |
| **Garnet** | Charcoal + crimson | crimson `#C8324C` (danger→amber) | Chakra Petch | Sharp · wght 400 | red marble |
| **Hackerman** | Midnight + neon, square, code-rain bg | neon `#2BFF55` | VT323 | Sharp · wght 400 | Matrix rain |

Every theme defines, per mode, the full token set: `--bg --panel --surface --surface-2
--hairline`, text `--fg --fg-2 --fg-muted --fg-faint`, `--accent --accent-press --accent-soft
--accent-faint --on-accent`, semantics `--success --warning --danger --info`, radii `--r-input
--r-card --r-card-lg --r-sheet --r-pill --r-ic`, density `--pad --row-h`, motion `--ease
--ease-out --dur-fast --dur --dur-slow`, fonts `--font --title-font --font-mono`, and icon axes
`--icon-font --icon-fill --icon-wght --icon-wght-fill --icon-grad`. Optional `--card-art`
(themed Photos-card background) and `--app-tex` (app-wide texture, e.g. Hackerman code-rain).

**Live switching:** every screen includes `theme-switch.js` — a floating ◐ control (bottom-left)
that swaps theme/mode, persists to `localStorage`, and honors `?t=<theme>&m=<mode>` URL params.
A `.switching` guard suspends transitions for one frame on switch (works around a Chrome bug
where `var()`-backed transitions stick at their pre-switch value).

---

## Content fundamentals (voice & copy)

- **Second person, warm and direct.** "Your files. Your keys." / "your vault." "We" is used
  sparingly and only to reassure about what we *can't* do ("We never see it and can't reset it").
- **Calm authority, not fear.** Security is framed as control and ownership.
- **Sentence case** everywhere; the only uppercase is the tracked overline (date headers /
  section labels: "MAY 2026", "VAULT").
- **Plain-language crypto** as quiet credibility in captions/pills ("AES-256-GCM", "Argon2id",
  "Zero-knowledge"), never the headline.
- **No emoji.** Numbers are real and specific ("2,431 photos", "~12 min", "0.4s").

---

## Visual foundations

- **Dark-first**, but every theme also ships a light mode. Surfaces are layered (bg → panel →
  surface → surface-2) with 1px hairline borders and modest radii; shadows are reserved for
  floating elements (FAB, sheets, web preview).
- **Density:** the gallery is the one tight surface (1.5px grid gaps, zero outer padding,
  Samsung-tight); everything else gets iOS-Settings breathing room (per-theme `--pad`).
- **Motion (`motion.css`):** token-driven and **screenshot/print-safe** — base states are always
  visible; entrance animations are gated behind `html.cn-ready` (added by JS) and only animate
  *from* hidden *to* the visible base. Press feedback, tab icon fill-morph, sheet rise, and a
  signature **cipher decrypt** effect (`cipher-fx.js` — text scrambles through glyphs then
  resolves; used on the recipient web viewer). All respect `prefers-reduced-motion`.
- **Explicitly avoided:** padlock clichés, fingerprint hero art, neon/cyberpunk (except the
  opt-in Hackerman theme), blockchain iconography, glassmorphism, dramatic gradients, emoji.

---

## Iconography

- **Material Symbols** is the icon system, **self-hosted and subset** to the exact ~80 glyphs
  used (`fonts/material.css` + `fonts/material-symbols-{outlined,rounded,sharp}.woff2`, ~23–31 KB
  each). The cut (Outlined / Rounded / Sharp) is a **theme token** (`--icon-font`), and the
  **FILL / weight / grade** axes are driven per theme — so icons restyle with the theme.
- Use `<span class="mi">name</span>`; add `fill` for active/selected (`<span class="mi fill">`).
  `fonts/_icon_map.json` records the Phosphor→Material name mapping used in the migration.
- **No emoji, no unicode-as-icon.** File types use Material glyphs (`picture_as_pdf`,
  `description`, `folder_zip`, `code`, `database`, …) on a tinted rounded square.

---

## Repository index

| Path | What |
|---|---|
| `styles.css` | **DS entry point** — `@import`s themes + components + motion + icons. Link this one file. |
| `themes.css` | **Source of truth** — 7 packs × 2 modes, every token, self-hosted `@font-face`s, `.mi` helper. |
| `app.css` | Component library — shell, app bar, tab bar, rows, cards, pills, sheets, buttons, inputs, gallery grid, FAB, empty states, `.t-*` type scale, card-art / app-tex. |
| `motion.css` | Token-driven, screenshot/print-safe motion. |
| `theme-switch.js` | Floating ◐ theme/mode switcher (localStorage + `?t=&m=` params). |
| `cipher-fx.js` | Signature scramble/decrypt text effect. |
| `fonts/` | Self-hosted Material Symbols (3 cuts) + every theme's display font (Bungee Hairline, Hanken Grotesk, IM Fell English, Google Sans Flex, Snowburst One, Carattere, Chakra Petch, VT323, …). Inter `.ttf` retained as legacy. |
| `assets/` | Logo marks + per-theme Photos-card art + Hackerman rain + paper grain. |
| `screens/` | All 24 product screens (themed, Material Symbols). |
| `Screens.html` | Browsable pan/zoom canvas of every screen + a 7-theme showcase row. **Start here.** |
| `theme_proof.html` | Side-by-side Home / Viewer / Recovery across all 7 themes with a switcher. |
| `ui_kits/app/` | Interactive React UI kit (unlock → vault → gallery → viewer), themed. |
| `color_type_reference.html`, `component_library.html` | Reference frames. |
| `preview/` | Design-System-tab cards (7 theme cards + component/type/spacing specimens). |
| `SKILL.md` | Agent-Skills manifest. |

### Screens (`screens/`)
01 splash · 02 onboarding · 03 cloud-selection · 04a signup-password · 04 mnemonic · 05 login ·
06 restore · 07 home · 08 upload-sheet · 09 gallery · 10 albums · 11 stories · 12 image-viewer ·
13 video-player · 14 documents · 15 audio · 16 other-files · 17 share-dialog · 18 active-shares ·
19 settings · 20 migration · 21 paywall · 22 recipient-web (desktop) · 23 empty-states ·
24 error-states. Every screen is themeable live via the ◐ control.

---

## Caveats / substitutions
- **No source code or Figma** was provided — all screens interpret the written brief.
- **Material Symbols** replaced the original Phosphor set so the icon cut could become a theme
  token (Phosphor lacks rounded/sharp geometry variants).
- Some theme fonts (Snowburst One, Carattere, VT323, Tangerine) are **display/script faces** —
  characterful at headings but a decorative read for dense UI text.
- Photo content uses `picsum.photos` placeholders; per-theme card art is user-supplied or
  procedurally generated (Binary digits, soil, towers, UFO, letter, marble, code-rain).

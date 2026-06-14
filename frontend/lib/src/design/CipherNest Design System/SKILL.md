---
name: ciphernest-design
description: Use this skill to generate well-branded interfaces and assets for CipherNest, either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, a 7-theme token system, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files.

CipherNest is a zero-knowledge encrypted cloud-storage vault for Android (Samsung Gallery DNA;
calm/premium/technically-credible tone). Its defining feature is a **7-theme token
architecture**: Binary (default, monochrome), Burrow (earthy), Corporate (steel), Alien
(obsidian+lime), Paper (vellum+gold), Garnet (charcoal+crimson), Hackerman (neon). Each theme
has a dark and light mode and swaps color + fonts + radius + density + motion + icon style
together.

**Link one stylesheet and set two attributes:**
```html
<html data-theme="binary" data-mode="dark">
  <link rel="stylesheet" href="styles.css">
```
`styles.css` pulls in `themes.css` (all tokens + self-hosted fonts + the `.mi` icon helper),
`app.css` (component library + `.t-*` type scale), `motion.css`, and `fonts/material.css`
(self-hosted Material Symbols, 3 cuts). Compose screens from the existing component classes
(`.phone`, `.appbar`, `.row`, `.card`, `.pill`, `.tabbar`, `.fab`, `.sheet`, `.btn`, `.input`,
`.grid3`, …) — they read theme tokens automatically. Icons: `<span class="mi">name</span>`
(add `fill` for active). The CipherNest wordmark is always Bungee Hairline (weight 800); tint
the logo mark with `var(--accent)`.

Drop `<script src="theme-switch.js"></script>` on any page for the live ◐ theme/mode switcher
(also reads `?t=<theme>&m=<mode>`). Use `cipher-fx.js` for the signature scramble/decrypt text
effect.

Key references: `Screens.html` (every screen + theme showcase), `theme_proof.html` (3 screens ×
7 themes), `ui_kits/app/` (interactive recreation), `preview/theme-*.html` (per-theme cards).

If creating visual artifacts (slides, mocks, throwaway prototypes), copy assets out and create
static HTML files for the user to view. If working on production code, copy assets and read the
rules here to become an expert in designing with this brand. If the user invokes this skill
without other guidance, ask what they want to build, ask which theme(s), and act as an expert
designer who outputs HTML artifacts or production code.

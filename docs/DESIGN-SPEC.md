# ZiroEdge Design Spec — "Midnight signal — a precision instrument"

**Status:** Authoritative. Every screen refactor executes this document mechanically.
**Companion code:** `ZiroEdge/Views/DesignSystem.swift` (the only source of truth for tokens and shared components; zero app-internal dependencies, typechecks against SwiftUI alone).
**Applies to:** all views in `ZiroEdge/Views/`. iOS 18+, iPhone portrait + iPad, dark and light first-class, no dependencies.

---

## 1. Direction

ZiroEdge runs an LLM on the user's own hardware with no network. The interface must feel like a **precision instrument with a warm soul**: engineered calm, not a colorful consumer chat app; warm, not cold enterprise gray.

- **Surfaces.** A designed four-level surface system — near-black graphite in dark mode; warm paper-white in light mode. Depth comes from **hairline strokes first, soft restrained shadows second**. One shadow language, tokenized.
- **Accent.** One vivid blue signal (the `AccentColor` asset: `#2E6BFF` in every appearance): primary actions, focus rings, active states, the streaming cursor, progress. Used with discipline — if accent is on screen for something that is not actionable, load-bearing, or alive, remove it.
- **Semantics.** Complete status palette (positive / warning / danger / info) as AA-verified token pairs with pre-composited tinted containers. Raw `.red`, `.orange`, `.green`, `.blue`, `.purple`, `.indigo` are banned in views.
- **Type.** SF Pro via system text styles (Dynamic Type free), plus a **technical voice** — monospaced design — for model IDs, quantization tiers, token counts, byte sizes, SHA fragments. This is an engineering tool; technical data looks technical.
- **Rhythm.** One spacing scale (2/4/8/12/16/24/40), one radius scale (6/10/14/20/28), one measure system (360/520/680/760).
- **Motion.** Small, springy, purposeful. Three standard curves. Always Reduce-Motion aware.
- **The brand moment.** The chat empty state: brand mark, wordmark, privacy statement, guided starting points. Never blank.

**Decision record — accent asset:** the `AccentColor`/`AccentForeground` colorsets are vivid blue `#2E6BFF` in every appearance with a white foreground. Verified: white on `#2E6BFF` = 4.50:1; both assets carry Increased Contrast variants. The asset is unchanged.

**Decision record — dark surface retune (vision batch):** the dark appearance is neutral graphite, not navy, because the vision screenshots contain no blue surfaces at all — elevation is gray-on-black. `pageBackground` `#0B0B0D` · `raisedBackground`/`wellBackground` `#1C1C1E` (deliberately one value: the vision's assistant bubble and composer well are the same fill) · `overlayBackground` `#25252A` · `hairline` `#2E2E32` · `hairlineStrong` `#3F4249`. The user's own bubble is the one saturated surface left: light keeps accent blue `#2E6BFF`, dark uses deep navy `#1E2A6B` (new token `userBubble`). Vivid `#2E6BFF` remains the *signal* — focus rings, cursor, primary buttons, active icons. Light-mode tokens are untouched by this retune.

---

## 2. Rules of engagement (read first)

1. **Never** use raw system colors (`.red`, `.orange`, `.green`, `.blue`, `.purple`, `.indigo`, `.systemBackground`, `.secondarySystemBackground`, `.tertiarySystemBackground`) or ad-hoc `.opacity(...)` fills for status/badges in a view. Resolve everything through `ZiroTheme` / `ZiroTone`.
2. **Never** hand-roll `.shadow(...)`, `.animation(...)`, font point sizes, or width caps. Use `ziroShadow`, `ziroAnimation`, `ZiroType`, `ZiroMeasure`.
3. **Never** break the UI-test contract (§10). When in doubt about an identifier, label, symbol, or spoken phrase, the contract wins over this spec.
4. **44×44pt minimum** for every interactive element; prefer `@ScaledMetric`-scaled frames so targets grow with Dynamic Type (existing pattern in `ChatView`, `MessageBubble`, `ModelsView`, `SettingsPage`).
5. **Dynamic Type:** text only via `ZiroType` roles. Bundled faces scale because every role is a `Font.custom(_:size:relativeTo:)` anchored to a system text style — a bare `Font.custom(_:size:)` or a fixed `.font(.system(size:))` breaks scaling and is never correct for text. Decorative fixed sizes (icons, rings, mark) via `@ScaledMetric(relativeTo:)`.
6. **No behavior/flow/IA changes.** This is a visual system: palette, shape, type, and placement only. The send flow, model picker phases, and every identifier in §10 stay exactly as they are.
7. `accessibilityReduceMotion` gates every animation; state changes still apply, just without motion.
8. Legacy aliases (`ZiroTheme.elevatedBackground`, `.subtleBorder`, `.inputBackground`) still compile — **do not use them in new code**; use the elevation/hairline names. Migrate call sites opportunistically.

---

## 3. Color tokens

All tokens are fixed sRGB values per appearance (implemented as dynamic `UIColor` closures — not opacity blends), so every ratio below is exact regardless of what sits beneath.

### 3.1 Surfaces (`ZiroTheme`)

| Token | Light | Dark | Role |
| --- | --- | --- | --- |
| `pageBackground` | `#F7F3EC` warm paper | `#0B0B0D` near-black | Base canvas: page bodies, chat transcript, List/Form pages |
| `raisedBackground` | `#FFFFFF` | `#1C1C1E` dark charcoal | Cards, assistant bubbles, banner fills resting on the page |
| `wellBackground` (= `inputBackground`) | `#EFE9DF` | `#1C1C1E` | Input wells: the chat composer, search fields |
| `overlayBackground` | `#FFFFFF` | `#25252A` | Custom floating layers (menus, popovers, custom sheets) |
| `userBubble` | `#2E6BFF` accent blue | `#1E2A6B` deep navy | The user's own message bubble (`accentForeground` white on it) |

Elevation order (light): page < well < raised = overlay. Elevation order (dark): page < raised = well < overlay — wells and raised surfaces share one gray (the vision's composer and assistant bubble are the same fill); the overlay step keeps menus above both.

`userBubble` is a *content* fill, not a surface: it is the only saturated fill on the transcript. White on it is 4.50:1 (light) / 13.14:1 (dark).

### 3.2 Hairlines

| Token | Light | Dark | Role |
| --- | --- | --- | --- |
| `hairline` (= legacy `subtleBorder`) | `#DCD2C2` | `#2E2E32` charcoal hairline | The default 1pt stroke on cards, bubbles, banners, chips, rings |
| `hairlineStrong` | `#C9BCA6` | `#3F4249` | Focused/selected outlines, brand-mark tile edge |

Hairlines are decorative (no contrast floor). Depth rule: **hairline always, shadow optionally** — a surface with a shadow but no hairline is wrong.

### 3.3 Text hierarchy

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `primaryText` | `#1C1814` | `#EDF1F7` | Titles, message text, primary copy |
| `secondaryText` | `#5C544A` | `#9AA3B8` | Descriptions, banner messages, footers |
| `tertiaryText` | `#6E6659` | `#8B93A7` | Timestamps, SHA fragments, locked parameters |

Cool-tinted near-black / near-white — pure `#000`/`#FFF` reads clinical against the tinted surfaces and is reserved for on-accent fills (`accentForeground`).

### 3.4 Accent (the signal)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `accent` (=`Color.accentColor`, asset) | `#2E6BFF` | `#2E6BFF` | Primary fills, focus rings, cursor, progress, active icons |
| `accentForeground` (asset) | `#FFFFFF` | `#FFFFFF` | Text/icons **on** accent fills (4.50:1 on `#2E6BFF`) |
| `accentContainer` | `#E6EDFF` | `#16265A` | Tinted fill for secondary buttons, accent badges, pressed chips/cards |

Raw accent `#2E6BFF` on its own containers is 3.84:1 (light) / 3.20:1 (dark) — it clears the 3:1 large-text/icon floor (semibold body labels qualify) but not the 4.5:1 caption floor; keep accent-on-container copy at semibold body or larger, or pair it with an icon.

### 3.5 Semantic status pairs (text + pre-composited container)

| Tone (`ZiroTone`) | Text light | Text dark | Container light | Container dark |
| --- | --- | --- | --- | --- |
| `.positive` → `positiveText` / `positiveContainer` | `#166E2B` | `#34C759` (system green) | `#E3EEE6` | `#22301E` |
| `.warning` → `warningText` / `warningContainer` | `#A64B00` | `#FF9500` (system orange) | `#F4E9E0` | `#3B2A13` |
| `.danger` → `dangerText` / `dangerContainer` | `#C40013` | `#FF554A` | `#F8E0E3` | `#3B221C` |
| `.info` → `infoText` / `infoContainer` | `#0062CC` | `#3D9BFF` | `#E0ECF9` | `#232A32` |
| `.neutral` → `secondaryText` / `neutralContainer` (= well) | `#5C544A` | `#9AA3B8` | `#EFE9DF` | `#1C1C1E` |

### 3.6 Data hues (categorical, NOT status)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `accentPurpleText` / `purpleContainer` | `#8236B8` / `#F0E7F6` | `#C973F5` / `#342631` | VISION capability badge, Q5 quant tier |
| `accentIndigoText` / `indigoContainer` | `#4F48D6` / `#EAE9FA` | `#8686FF` / `#2C2832` | Q6 quant tier |

Data hues never appear in banners, buttons, or status contexts. Quant tiers: Q8/F16 → `.info`, Q6 → `.indigo`, Q5 → `.purple`, Q4 → `.positive`, Q3/Q2 → `.warning` (existing mapping, now rendered via `ZiroBadge`).

---

## 4. Verified contrast ratios (WCAG, both appearances)

Floors: **4.5:1** text (any size the app renders), **3:1** icons/large text. Computed with the WCAG relative-luminance formula; script reproduced ratios, zero failures.

**Text hierarchy (≥4.5 required):**

| Token | Light `#F7F3EC`/`#FFFFFF`/`#EFE9DF` page/raised/well | Dark `#0B0B0D`/`#1C1C1E`/`#1C1C1E` page/raised/well |
| --- | --- | --- |
| `primaryText` | 15.95 / 17.65 / 14.61 | 17.35 / 15.01 / 15.01 |
| `secondaryText` | 6.73 / 7.44 / 6.16 | 7.78 / 6.73 / 6.73 |
| `tertiaryText` | 5.12 / 5.66 / 4.69 | 6.40 / 5.53 / 5.53 |

**Accent & semantics on page / raised / well (light, then dark):**

| Token | Light (page/raised/well) | Dark (page/raised/well) |
| --- | --- | --- |
| accent `#2E6BFF` (both) | 4.07 / 4.50 / 3.73 | 4.37 / 3.78 / 3.78 |
| positive | 5.75 / 6.36 / 5.27 | 8.86 / 7.66 / 7.66 |
| warning | 5.23 / 5.79 / 4.79 | 8.94 / 7.74 / 7.74 |
| danger | 5.66 / 6.26 / 5.18 | 6.23 / 5.39 / 5.39 |
| info | 5.25 / 5.80 / 4.81 | 6.86 / 5.94 / 5.94 |
| purple | 5.99 / 6.63 / 5.49 | 6.79 / 5.88 / 5.88 |
| indigo | 5.88 / 6.50 / 5.38 | 6.43 / 5.56 / 5.56 |

**Text on its own tinted container (≥4.5 required):**

| Pair | Light | Dark |
| --- | --- | --- |
| accent on `accentContainer` | 3.84 | 3.20 |
| positive on `positiveContainer` | 5.35 | 6.27 |
| warning on `warningContainer` | 4.85 | 6.26 |
| danger on `dangerContainer` | 4.99 | 4.65 |
| info on `infoContainer` | 4.85 | 5.06 |
| purple on `purpleContainer` | 5.51 | 4.94 |
| indigo on `indigoContainer` | 5.43 | 4.71 |
| neutral (`secondaryText` on well) | 6.16 | 6.73 |

Raw accent `#2E6BFF` on its own container (3.84 / 3.20) is the one pairing below the 4.5:1 text floor: it clears only the 3:1 large-text/icon floor, so accent-on-container copy stays at **bold ≥14pt** (see §3.4) — which is why `ZiroSecondaryButtonStyle` renders via `ZiroType.bodyStrong` (Satoshi 700 at 16pt) rather than a semibold or regular face. Every other tinted-container pairing clears 4.5:1.

**On-accent (fills):** white on `#2E6BFF` = **4.50**. User-bubble labels, primary buttons, send glyph all clear AA.

**Accent as ink on a surface** (not on a container) is the other below-floor family, and the dark retune does not change it: `#2E6BFF` on page / raised / well / overlay = 4.07 / 4.50 / 3.73 / 4.50 (light) and 4.37 / 3.78 / 3.78 / 3.39 (dark). `Scripts/verify-design-tokens.py` therefore still exits non-zero on those eight pairings (baseline before the retune: nine). They clear the 3:1 icon/large-glyph floor, which is the floor accent ink is actually used at — glyphs, rings, borders — so accent stays out of sentence copy. Lifting them would mean lightening the accent asset, which is out of scope for a surface retune.

Dark-mode notes (why tokens differ from system hues): system blue `#0A84FF` = 4.11:1 and system purple `#BF5AF2` = 4.19:1 on their 12% tinted containers — below floor — so dark `infoText`/`accentPurpleText` are lightened (`#3D9BFF`/`#C973F5`), matching the established indigo `#8686FF` precedent. Increased Contrast: text tokens sit ≥4.65 everywhere at defaults and the accent asset ships HC variants; iOS Increase Contrast needs no separate token set here.

---

## 5. Typography (`ZiroType`)

The scale is three bundled typefaces (`app/ZiroEdge/Resources/Fonts/`, registered
in `Config/Info.plist` `UIAppFonts`, both wired from `project.yml`), each role
anchored to a **system text style** via `Font.custom(_:size:relativeTo:)` — so
Dynamic Type is inherited exactly as it was on the system ramp. Never fixed
point sizes for text.

| Face | Weights | Owns |
| --- | --- | --- |
| **Orbitron** | SemiBold 600, Bold 700 | The brand voice. `display`, `wordmark`. Never body copy. |
| **Satoshi** | Regular 400, Medium 500, Bold 700 | Every text role: chat, chrome, hero copy. |
| **Space Mono** | Regular 400, Bold 700 | The technical voice: model IDs, quant tiers, token counts, byte sizes, SHA fragments, timestamps. |

| Role | Face @ style | Use |
| --- | --- | --- |
| `ZiroType.display` | Orbitron Bold @ `.title` | Onboarding page titles |
| `ZiroType.wordmark` | Orbitron SemiBold @ `.caption` | The `ZIROEDGE` header wordmark |
| `ZiroType.title` | Satoshi Bold @ `.title3` | Empty-state hero title, outcome heroes |
| `ZiroType.heading` | Satoshi Medium @ `.headline` | Card headers, model-detail identity, sheet titles |
| `ZiroType.rowTitle` | Satoshi Medium @ `.subheadline` | List row titles, banner titles, header-pill label |
| `ZiroType.body` | Satoshi Regular @ `.callout` | Message text, primary copy |
| `ZiroType.bodyMedium` | Satoshi Medium @ `.callout` | The user's own message bubble |
| `ZiroType.bodyStrong` | Satoshi Bold @ `.callout` | Button labels + accent-on-container copy (§4) |
| `ZiroType.supporting` | Satoshi Regular @ `.footnote` | Descriptions, banner messages, subtitles |
| `ZiroType.footnote` | Satoshi Regular @ `.caption` | Inline support text, dense button labels |
| `ZiroType.caption` | Satoshi Regular @ `.caption` | Metadata, banner actions |
| `ZiroType.micro` | Satoshi Regular @ `.caption2` | Badges, micro-meta, percentages |
| `ZiroType.technical(style, weight)` | Space Mono @ style | **Technical voice** — model IDs, quant tiers, token counts, byte sizes, SHA fragments, pinned revisions |
| `ZiroType.meta` | Space Mono @ `.caption2` | Timestamps, day dividers |

The anchors in `ZiroType.baseSize(for:)` are the point sizes those system styles
resolve to at the default content size, so each role keeps the optical size its
system counterpart had at every Dynamic Type setting. `TypographyContractTests`
asserts the anchors against UIKit and asserts every face resolves in the built
bundle — a font that fails to register falls back to the system face silently,
which is the failure mode those tests exist to catch.

**Weights go through the face table, not `.weight(_:)`.** SwiftUI resolves a
weight on a custom face by descriptor, which can land back on the system font;
where a weight is load-bearing (`bodyMedium`, `bodyStrong`) or the face is a
separate registered family (Satoshi Medium), pick the face. `technical(_:_:)`
maps any weight below medium to Regular and medium-or-heavier to Bold, since
Space Mono ships only two.

Technical voice defaults: `.footnote/.regular`; `.caption2` for SHA fragments;
`.caption2/.semibold` inside badges; `.body` for model IDs in detail headers.
Digits in streaming/technical contexts may use `.monospacedDigit()` as today.

This table sits one step smaller than earlier revisions of this document
claimed. The smaller scale is intended; do not "correct" the tokens back up.

The three licenses are recorded in `Resources/THIRD_PARTY_NOTICES.md` — Satoshi
is ITF Free Font License (commercial use allowed, **not** OFL); Inter is the
drop-in OFL substitute.

---

## 6. Rhythm, measure, shadow, motion

### 6.1 Spacing (`ZiroTheme.Spacing`) — unchanged rhythm

`micro 2` · `xSmall 4` · `small 8` · `medium 12` · `large 16` · `xLarge 24` · `xxLarge 40`; half-step `badge 6` (capsule h-padding). Screen-level h-padding is `large` (16) inside bubbles/rows and `xLarge` (24) on full-page scroll content. (`heroTop` was removed with the chat empty-state rewrite — see §8.1.)

### 6.2 Radius (`ZiroTheme.Radius`)

`badge 6` badges/chips · `small 10` thumbnails, mini wells · `control 14` buttons, banners, text fields, `ziroComposerField` · `bubble 20` message bubbles + thinking indicator · `card 20` cards · `composer 28` the chat composer's floating well (§8.1). Capsules for pills/primary buttons. All corners `style: .continuous` on cards/bubbles/fields.

### 6.3 Measure (`ZiroMeasure`)

`narrow 360` focused recoveries · `standard 520` heroes, onboarding copy, empty state, single-column forms · `wide 680` message bubbles · `full 760` transcript column. Always applied as `frame(maxWidth: cap)` centered by a full-width frame — never fixed widths.

### 6.4 Shadow language (`ziroShadow(_:)`)

| Level | Light | Dark | Used on |
| --- | --- | --- | --- |
| `.raised` | black 14%, r12, y3 | black 50%, r10, y3 | Primary buttons, floating cards |
| `.floating` | black 20%, r24, y8 | black 55%, r28, y8 | Overlays, hero CTAs, jump-to-bottom |
`nil` = no shadow. Shadows only ever accompany a hairline. List/Form chrome, banner fills, and cards inside scroll forms take **no** shadow.

### 6.5 Motion (`ZiroMotion` + `.ziroAnimation(_:value:)`)

| Token | Curve | Use |
| --- | --- | --- |
| `ZiroMotion.press` | `.snappy(duration: 0.18)` | Presses, focus ring, micro toggles (scale 0.97–0.98) |
| `ZiroMotion.appear` | `.spring(response: 0.35, dampingFraction: 0.8)` | Elements entering: streaming bubble, banners, chip reveal, jump-to-bottom |
| `ZiroMotion.stream` | `.easeOut(duration: 0.22)` | Debounced streaming scroll, ring progress |
| `ZiroMotion.cursorPeriod` | `0.6s` | Streaming cursor blink cadence |

`.ziroAnimation(anim, value:)` = `.animation` that drops the animation under Reduce Motion. ButtonStyles check `accessibilityReduceMotion` themselves. Message transitions keep the existing pattern: `reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)`.

---

## 7. Component specs (all implemented in `DesignSystem.swift`)

### 7.1 `ZiroPrimaryButtonStyle` — primary action

Capsule, accent fill, `accentForeground` label, `.body.weight(.semibold)`, `maxWidth: .infinity`, `minHeight: 44`, h-padding 24 / v-padding 12, `.ziroShadow(.raised)`. Press: fill 0.82 + scale 0.98 (`press` curve). Disabled: fill 0.3, label 0.6. **One per screen-section.**

### 7.2 `ZiroSecondaryButtonStyle` — secondary action

Capsule, `accentContainer` fill, accent label, same metrics, `hairline` stroke. Press: accent 0.12 overlay + scale. Replaces `.borderedProminent`/`.bordered` for meaningful non-primary choices.

### 7.3 `ZiroDestructiveButtonStyle` — destructive action

Capsule, `dangerContainer` fill, `dangerText` label, same metrics, `hairline` stroke. For Delete/Forget/Cancel-destructive confirmations that render in-page.

Tertiary/system contexts (toolbar buttons, list rows, dialog actions) keep system styles; tint them with tokens only.

### 7.4 `ZiroStatusBanner` — status banner

Anatomy: leading SF Symbol (`.body.weight(.semibold)`, `tone.tint`, 22pt column, a11y-hidden) → title (`.subheadline.weight(.semibold)`, `primaryText`) over message (`.subheadline`, `secondaryText`, wraps) → trailing/stacked actions (`.footnote.weight(.semibold)`, `minHeight: 44`). Surface: `RoundedRectangle(cornerRadius: control, style: .continuous)`, `tone.container` fill, `hairline` stroke.

- **Canonical init:** `ZiroStatusBanner(icon:title:message:tone:actions:)` with a `ZiroTone` — use for all migrated call sites.
- **Legacy init** (`tint:`) retained: 10% fill + 3pt leading rail. Migrate call sites to `tone:` and pass `ZiroTheme.dangerText` where raw `.red` was passed.
- Banner actions are plain `Button`s (system styles ok inside); every banner keeps its a11y identifier and announcement (§10).
- Tone mapping: model-load failure/eviction, repair → `.warning` (symbols `exclamationmark.octagon.fill`, `memorychip`, `wrench.and.screwdriver` per contract); startup/runtime errors → `.danger` (`exclamationmark.triangle.fill`); truncation/vision warnings, model unavailable, persistence recovery → `.warning`; the persistence banner keeps its neutral-informative voice with `.warning`.

### 7.5 `ZiroCard` — card

`raisedBackground` fill, `hairline` stroke, `Radius.card` continuous, padding 16 default, `maxWidth: .infinity, alignment: .leading`. `showsShadow: true` only for truly floating cards (transfer status card in wizard). Used outside List/Form contexts.

### 7.6 `ZiroBadge` — the ONE badge system

`HStack(optional icon + text)`, icon `.caption2.weight(.bold)`, text `.caption2.weight(.bold)` (or `technical(.caption2, .semibold)` when `monospaced: true`), `tone.tint` foreground, `tone.container` Capsule fill, h-padding 6 / v-padding 2, `.fixedSize()`, `.accessibilityElement(children: .combine)`. Tones: VISION → `.purple`; PAIR INCOMPLETE → `.warning`; quant tiers per §3.6; INSTALLED/verified → `.positive` (icon `checkmark.circle.fill`); FAILED → `.danger` (icon `exclamationmark.circle.fill`); "Coming soon" → `.neutral`. **Replaces all 0.10/0.12/0.15 hand-tinted capsules.**

### 7.7 `ZiroSuggestionChip` + `ZiroFlowLayout` — interactive chips

Capsule, `wellBackground` fill, `hairline` stroke, `primaryText` label `.subheadline.weight(.medium)`, optional accent leading icon, h-padding 12, **`minHeight: 44`**, `lineLimit(2)`. Press: `accentContainer` fill + accent 1pt stroke + scale 0.97. `ZiroFlowLayout` wraps chips across lines at any Dynamic Type size.

Capability cards (`ZiroCapabilityCard`, reference-style, preferred for chat starters): full-width rows — tinted `ZiroTheme`-token dot + `primaryText` `.subheadline.weight(.medium)` two-line label + `tertiaryText` chevron — on a `raisedBackground` + `hairline` card (`Radius.control`), **`minHeight: 56`**, same pressed treatment. Dots are decorative; the label carries the meaning.

### 7.8 `ZiroEmptyState` — the brand moment (see §8.1)

Brand mark + accent glow + wordmark + title + message + optional capability cards (`ZiroCapabilityCard` rows with per-card tinted dot + chevron) or legacy suggestion chips + optional actions; `maxWidth: standard`, top padding applied by the caller. The **chat** empty state no longer uses this component — it is the mark + one line, centered (§8.1). `ZiroEmptyState` remains for other resting moments and the design-system gallery.

### 7.9 `ZiroBrandMark` — the mark

The `AppLogo` monogram asset rendered as a template glyph in the adaptive `primaryText` color — no baked tile — so it floats on any surface (empty state, onboarding bar, galleries). A logo swap is a single asset replacement. Static; `.accessibilityHidden(true)`. Sizes: 28 (chrome), 48 (cards), 68 (`@ScaledMetric(relativeTo: .largeTitle)`, empty state).

### 7.10 `ZiroSectionHeader` — custom-surface section header

Uppercase `.caption.weight(.semibold)`, tracking 0.8, `secondaryText`, optional accent leading icon. Only outside List/Form (those keep system headers).

### 7.11 `ZiroProgressRing` — progress ring

`hairline` track, accent (or param tint) round-capped arc, trim from −90°, min 0.02, `stream` animation on progress change, `size 26` / `lineWidth 2.5` defaults, `accessibilityHidden(true)` — the scaling percentage label beside it carries the information (existing pattern in `ModelsView`).

### 7.12 `ziroMessageBubble(_:)` — bubble treatment

`user`: `userBubble` fill (accent blue `#2E6BFF` in light, deep navy `#1E2A6B` in dark), `Radius.bubble` (20) continuous, 1pt `hairline`; label `accentForeground`, h-padding 16 / v-padding 12. `assistant`: `raisedBackground` fill (dark charcoal `#1C1C1E` in dark, white in light) with the same radius, hairline, and padding; label `primaryText`. Streaming assistant bubble: assistant treatment + accent caret (attributed `|` in accent, `cursorPeriod` blink, static when Reduce Motion). Timestamps sit **outside** the bubble — `technical(.caption2)` in `tertiaryText`, aligned to the bubble's own edge (trailing for the user, leading for the assistant), rendered only when the row carries a `createdAt`. Row metrics: bubbles centered in a `full`-width column; bubble rows `maxWidth: wide`.

### 7.13 `ziroComposerField(isActive:)` — input well

`wellBackground` fill, `Radius.control` continuous, h-padding 16 / v-padding 12; rest state `hairline` 1pt; focus state **accent 1.5pt ring** (`press` transition) — this is the keyboard focus indicator, never remove it. (The chat composer hand-rolls the same treatment at `Radius.composer` 28 with the same hairline-at-rest — see §8.1.)

### 7.14 `ZiroHero` — symbol hero (kept, refined)

Large hierarchical symbol in tint, `ZiroType.title` headline, `.subheadline` secondary message, `maxWidth: standard`. For outcome pages (import complete, duplicate, store recovery). The chat empty state uses `ZiroEmptyState` instead.

### 7.15 Status symbols (contract-critical)

Semantic tones map: `.positive` → `checkmark.circle.fill`, `.danger` → `exclamationmark.circle.fill`, `.warning` → `exclamationmark.triangle.fill`, `.info` → `info.circle.fill` (via `ZiroTone.statusSymbol`). The test-contract symbols (`checkmark.circle.fill`, `exclamationmark.circle.fill`, `wrench.and.screwdriver`) **remain Image-based SF Symbols** wherever they appear; tint with the tone's text token (≥3:1 guaranteed).

---

## 8. Screen-by-screen directives

### 8.1 Chat (ChatView + ChatSurfaceDetails + MessageBubble + ChatOverlayComponents) — the flagship

1. **Empty state (the brand moment).** `ChatView.emptyState` is the mark and the line, and nothing else:
   - Composition (top→bottom, centered, `maxWidth: standard`): `ZiroBrandMark(80)` (≈46pt of visible mark) → `title` "Ask me anything." (`ZiroType.title`, `primaryText`). No glow, no wordmark, no privacy caption, no suggestion cards.
   - The block is **vertically centered in the transcript viewport** (`.containerRelativeFrame(.vertical, alignment: .center)`), not top-padded, so it sits in the space above the floating composer instead of under the navigation bar.
   - When `availableModels.isEmpty`, keep the `browse-models-button` CTA (identifier preserved) as `ZiroPrimaryButtonStyle` "Browse Models" — with nothing installed the composer can do nothing and the catalog is the only way forward.
   - `ZiroEmptyState` / `ZiroCapabilityCard` are no longer used by chat; they stay for other resting moments and the design-system gallery.
2. **Banners** migrate `ZiroStatusBanner(tint:)` → `tone:`: startup + runtime errors and `errorBanner` → `.danger` with `dangerText` (kills the last raw `.red`); persistence recovery, unavailable model, truncation, vision, modelRetry banners → `.warning`. All identifiers/announcements unchanged.
3. **Composer:** one floating well at `Radius.composer` (28) — `wellBackground` fill, 1pt `hairline` at rest, accent 1.5pt ring on focus (the keyboard focus indicator, never removed). Two rows inside it: `TextField("Message...", axis: .vertical)` on top, then the control row — `+` (`PhotosPicker`, `plus` glyph) left, model pill and send right. `ComposerModelPicker` is a capsule on the composer's own fill with a hairline: the sole identity surface, same phases/menu/labels as ever. `statusOrTokenHintRow` is gone — there is no separate status line above the well. Side margins `large`, bottom `medium`.
4. **Message list:** transcript column `frame(maxWidth: ZiroMeasure.full)`; bubbles `ziroMessageBubble(role)` (both roles are bubbles: `userBubble` navy / `raisedBackground` charcoal, 1pt hairline, `Radius.bubble`) with `maxWidth: ZiroMeasure.wide` on the row; assistant text `primaryText`; user label `accentForeground` on the `userBubble` fill. Per-message timestamps: `technical(.caption2)` in `tertiaryText`, outside the bubble, aligned to its edge (§7.12). Thinking indicator: assistant bubble treatment + `secondaryText` "Thinking…" row (`.subheadline`). Message enter transition per §6.5. Jump-to-bottom: accent circle + `accentForeground` glyph + `.ziroShadow(.floating)`.
5. **Header pill:** keeps capsule `wellBackground`; status dot → `positiveText`; failed/evicted tint → `warningText`; title `.headline`. All "Chat model, …" labels unchanged.
6. **Streaming cursor:** caret color → `Color.accentColor` (already), cadence `cursorPeriod`.

### 8.2 Models catalog (ModelsView)

1. Segmented scope picker stays system; section headers system. Introduction row: `lock.shield` label accent, `.subheadline` secondary copy.
2. Import row: leading icon accent in a `Radius.small` `accentContainer` rounded square (44×44 min), title `.headline` accent, caption secondary.
3. `ModelRow`: icon column `accent` hierarchical; title `.headline` + `ZiroBadge` for VISION/PAIR INCOMPLETE (replaces hand-tinted capsules); meta line: runtime eligibility label in its token tint (positive/warning/secondary) + `technical(.caption)` for `formattedSize`/quantization; trailing status: `ZiroProgressRing` for download states, `checkmark.circle.fill` `positiveText` for installed, `exclamationmark.circle.fill` **`dangerText`** (not `.red`) for failed, "Repair" in `warningText` with `wrench.and.screwdriver` imagery on the detail page. All spoken phrases unchanged ("installed", "needs repair", "available to download", "downloading, N percent complete").
4. Empty sections: `ContentUnavailableView` (system) is acceptable; the "all installed" custom one uses `checkmark.seal.fill` `positiveText` + `ZiroType.rowTitle`/`.subheadline`.

### 8.3 Model detail (ModelDetailView + ModelDetailUpdateFlow)

1. Identity: `ZiroType.heading` name, `technical(.subheadline)` for `size · quantization` line.
2. Primary actions: `ZiroPrimaryButtonStyle` (Start Chatting / Download / Text Only) + `ZiroSecondaryButtonStyle` (Add Image Processing / Retry Only Invalid / Retry Download).
3. Repair-needed row: `wrench.and.screwdriver` Image + `warningText` (contract). Failed states: `dangerText` (replaces `.red`/warning misuse for hard failures; keep `warningText` for the repair affordance itself).
4. Runtime strip: eligibility label token-tinted; explanation `.subheadline` secondary. Locked parameters: `technical(.caption)` values, `tertiaryText`.
5. Storage & Provenance: sizes/quant in technical voice where shown as standalone values; destructive section keeps system `role: .destructive` (system red is correct in dialogs) — in-page destructive buttons use `ZiroDestructiveButtonStyle`.

### 8.4 Settings (SettingsPage)

List/Form page — keep system chrome. Version/Engine/Privacy values and storage figures may use `technical` for the value side where they read as engineering data (RAM headroom, storage totals). Identifiers `export-memory-calibration`, `export-download-summary`, `export-download-jsonl` untouched.

### 8.5 Onboarding (OnboardingView)

1. Structure unchanged; `ZiroType.display` titles, `.body` secondary descriptions, `maxWidth: standard`.
2. Hero glyphs keep their per-page hue **as decorative large glyphs** (exempt from text floor) but the eyebrows must keep the verified tokens: `.info`, `.positive`, `.purple` (`accentPurpleText`).
3. "Skip" stays quiet (secondary); Continue/Get Started on `ZiroPrimaryButtonStyle`; Back on `ZiroSecondaryButtonStyle`. Page transition animation per `ZiroMotion.appear`, no-ops under Reduce Motion (existing).
4. Add the `ZiroBrandMark` (48) to the top bar before the wordmark for brand presence.

### 8.6 Import wizard (ImportView + ImportWizardSteps)

1. Step header strip: `raisedBackground` surface, `ZiroType.caption` "Step N of M" in `secondaryText`, system `ProgressView` tinted accent.
2. Source step: source-choice cards become `ZiroCard`s with `Radius.small` `accentContainer` icon squares; "Coming soon" chip → `ZiroBadge(tone: .neutral)`; failure card icon/label → `dangerText` (it's a hard rejection); privacy notice → `ZiroSectionHeader` + `.footnote` secondary.
3. Pinned Source section: repository/revision values in `technical` voice.
4. Transfer card: `ZiroCard(showsShadow: true)`; progress rows keep system `ProgressView(value:)` + technical percentage; success label `positiveText`, failure `dangerText`, cancelled `secondaryText`.
5. Done step: `ZiroHero` (positive tint) + `ZiroCard` summary (values in technical voice where numeric) + primary/secondary buttons.
6. `ConfidenceBadge`/variant capsules → `ZiroBadge` (high `.positive` w/ `checkmark.shield.fill`, medium `.warning` w/ `shield`, low `.danger` w/ `exclamationmark.shield`; quant tiers per §3.6 with `monospaced: true`).

### 8.7 Sidebar / drawer (SidebarView) + AppShell

System sidebar list — keep chrome. "New Conversation" row: accent label + `square.and.pencil`, `.body.weight(.semibold)` (unchanged). Error row: `warningText` + announcement (unchanged). Conversation rows: title `.body` `primaryText`, meta `.caption` `secondaryText` with technical count/date acceptable. The debug `memory-diagnostic-state` overlay stays as-is.

### 8.8 StoreRecoveryView

`ZiroHero` pages with `pageBackground`; action buttons: Retry Save → `ZiroPrimaryButtonStyle`, Export/Share → `ZiroSecondaryButtonStyle`, Discard → `ZiroDestructiveButtonStyle`; content `maxWidth: standard` (the 360 cap only inside the compact confirmation cluster → `ZiroMeasure.narrow`).

### 8.9 Launch screen (branded, simple)

1. New colorset **`LaunchBackground`** in `Assets.xcassets`: universal `#F7F3EC`, dark `#0B0B0D` (same as `pageBackground`).
2. In `Config/Info.plist` add:

   ```xml
   <key>UILaunchScreen</key>
   <dict>
       <key>UIColorName</key>
       <string>LaunchBackground</string>
   </dict>
   ```

   and remove `INFOPLIST_KEY_UILaunchScreen_Generation: YES` from `project.yml` (the explicit plist dict wins; generated-keys mode merges the file). Then run `xcodegen` once (implementation phase — not during this spec's delivery).
3. Optional second step (only if a raster mark is wanted at launch): export `ZiroBrandMark` art as a single-scale PDF `LaunchMark` in the asset catalog and add `UIImageName: LaunchMark` + `UIImageRespectsSafeAreaInsets: true` to the same dict. The color-only launch is acceptable; do **not** fake the mark with text.

---

## 9. Accessibility floors (non-negotiable)

- 4.5:1 text everywhere (verified §4 — includes badges and banner copy), 3:1 icons/large glyphs.
- 44×44pt hit targets: banner actions (already `minHeight: 44`), chips (built-in), buttons (`minHeight: 44`), glyph buttons keep `@ScaledMetric` 44pt frames + `contentShape`.
- Dynamic Type: text styles only; fixed decorative sizes via `@ScaledMetric`; allow multi-line hints (`lineLimit(1...2)` patterns stay).
- Reduce Motion: `ziroAnimation`, ButtonStyle checks, existing `reduceMotion` branches; no new ambient animation (cursor/ thinking dots keep their existing TimelineView pattern, which Reduce Motion already gates).
- VoiceOver: contract labels/announcements (§10); decorative icons `.accessibilityHidden(true)`; banners `.accessibilityElement(children: .contain)`; badges combined.

## 10. UI-test contract (must survive verbatim)

- **Identifiers:** `chatInput`, `sidebar-button`, `browse-models-button`, `modelRetryBanner`, `modelRetryButton`, `retryStartupButton`, `errorBanner`, `persistenceRecoveryBanner`, `unavailableConversationModelBanner`, `export-memory-calibration`, `export-download-summary`, `export-download-jsonl`, `memory-diagnostic-state`.
- **Labels/values:** "Chat model, …", "No model yet", "Assistant said: ", "You said: ", "Send message", "Stop generating", "Message...", "Conversations", "New Conversation", "Settings", "Models", "Manage Models", "Active Model", "Available", "Installed", "Import from Hugging Face", "Inspect Repository", "Pinned Source", "owner/repository or URL", "Skip", "Continue", "Get Started".
- **Symbols:** `checkmark.circle.fill`, `exclamationmark.circle.fill`, `wrench.and.screwdriver` remain Image-based with those symbol names.
- **Spoken phrases:** "installed", "needs repair", "available to download", "downloading, N percent complete".
- **Announcements:** "Assistant response complete" / "Response stopped".
- **Streaming:** stable label "Assistant is responding".

## 11. Migration map (mechanical replacements)

| Before (in views) | After |
| --- | --- |
| `Color(uiColor: .systemBackground)` / `ZiroTheme.pageBackground` old value | `ZiroTheme.pageBackground` (new token — no code change needed where already tokenized) |
| `.secondarySystemBackground` / `.tertiarySystemBackground` | `raisedBackground` / `wellBackground` by elevation role |
| `Color.red` / `tint: .red` in banners | `ZiroTheme.dangerText` / `tone: .danger` |
| `Color.orange` | `ZiroTheme.warningText` |
| `Color.purple.opacity(0.1)`-style capsules | `ZiroBadge(tone: .purple)` (or `.warning` for PAIR INCOMPLETE) |
| `.opacity(0.10/0.12/0.15)` badge fills | `ZiroTone.container` via `ZiroBadge` |
| `.borderedProminent` (in-page) | `ZiroPrimaryButtonStyle` |
| `.bordered` (in-page secondary) | `ZiroSecondaryButtonStyle` |
| `frame(maxWidth: 360/520/680/760)` | `ZiroMeasure.narrow/standard/wide/full` |
| `.font(.caption.monospaced())` etc. | `ZiroType.technical(...)` |
| Hand-rolled `.shadow(...)` | `.ziroShadow(.raised/.floating)` or none |
| `withAnimation(.snappy)` / ad-hoc springs | `ZiroMotion.press/appear/stream` + `.ziroAnimation` |
| Hand-rolled bubble background/overlay | `.ziroMessageBubble(role)` |
| Hand-rolled composer background/overlay | `.ziroComposerField(isActive:)` |
| Private `DownloadProgressRing` | `ZiroProgressRing` |
| Hand-tinted section eyebrows | `ZiroSectionHeader` |

## 12. Do / Don't

- **Do** keep one accent discipline: actionable, alive, or load-bearing only.
- **Don't** introduce a second shadow direction, a sixth radius, or a new status hue.
- **Don't** put data hues (purple/indigo) on banners, buttons, or status rows.
- **Don't** fix text sizes; don't fix control heights below 44; don't hardcode widths.
- **Don't** animate anything without a Reduce-Motion exit.
- **Do** leave List/Form system chrome alone — the token system shows through content, tint, and type, not by fighting UIKit chrome.

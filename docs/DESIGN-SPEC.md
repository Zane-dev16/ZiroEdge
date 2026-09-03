# ZiroEdge Design Spec — "Ember on graphite — a precision instrument"

**Status:** Authoritative. Every screen refactor executes this document mechanically.
**Companion code:** `ZiroEdge/Views/DesignSystem.swift` (the only source of truth for tokens and shared components; zero app-internal dependencies, typechecks against SwiftUI alone).
**Applies to:** all views in `ZiroEdge/Views/`. iOS 18+, iPhone portrait + iPad, dark and light first-class, no dependencies.

---

## 1. Direction

ZiroEdge runs an LLM on the user's own hardware with no network. The interface must feel like a **precision instrument with a warm soul**: engineered calm, not a colorful consumer chat app; warm, not cold enterprise gray.

- **Surfaces.** A designed four-level surface system — deep, subtly warm-tinted graphite in dark mode; warm paper-white in light mode. Depth comes from **hairline strokes first, soft restrained shadows second**. One shadow language, tokenized.
- **Accent.** One warm amber/gold ember (the existing `AccentColor` asset, kept): primary actions, focus rings, active states, the streaming cursor, progress. Used with discipline — if amber is on screen for something that is not actionable, load-bearing, or alive, remove it.
- **Semantics.** Complete status palette (positive / warning / danger / info) as AA-verified token pairs with pre-composited tinted containers. Raw `.red`, `.orange`, `.green`, `.blue`, `.purple`, `.indigo` are banned in views.
- **Type.** SF Pro via system text styles (Dynamic Type free), plus a **technical voice** — monospaced design — for model IDs, quantization tiers, token counts, byte sizes, SHA fragments. This is an engineering tool; technical data looks technical.
- **Rhythm.** One spacing scale (2/4/8/12/16/24/40), one radius scale (6/10/14/18/20), one measure system (360/520/680/760).
- **Motion.** Small, springy, purposeful. Three standard curves. Always Reduce-Motion aware.
- **The brand moment.** The chat empty state: brand mark, wordmark, privacy statement, guided starting points. Never blank.

**Decision record — accent asset:** the existing `AccentColor`/`AccentForeground` colorsets are **kept unchanged**. Verified: white on light accent `#8A5A00` = 5.93:1; black on dark accent `#F2C14E` = 12.51:1; both assets already carry Increased Contrast variants. No refinement required; the identity is correct.

---

## 2. Rules of engagement (read first)

1. **Never** use raw system colors (`.red`, `.orange`, `.green`, `.blue`, `.purple`, `.indigo`, `.systemBackground`, `.secondarySystemBackground`, `.tertiarySystemBackground`) or ad-hoc `.opacity(...)` fills for status/badges in a view. Resolve everything through `ZiroTheme` / `ZiroTone`.
2. **Never** hand-roll `.shadow(...)`, `.animation(...)`, font point sizes, or width caps. Use `ziroShadow`, `ziroAnimation`, `ZiroType`, `ZiroMeasure`.
3. **Never** break the UI-test contract (§10). When in doubt about an identifier, label, symbol, or spoken phrase, the contract wins over this spec.
4. **44×44pt minimum** for every interactive element; prefer `@ScaledMetric`-scaled frames so targets grow with Dynamic Type (existing pattern in `ChatView`, `MessageBubble`, `ModelsView`, `SettingsPage`).
5. **Dynamic Type:** text only via text styles (`ZiroType`) or `.monospaced()` variants; decorative fixed sizes (icons, rings, mark) via `@ScaledMetric(relativeTo:)`.
6. **No behavior/flow/IA changes.** This is a visual system. The only allowed interaction addition is the empty-state sample-prompt chips (§8.1), which must reuse the existing send flow.
7. `accessibilityReduceMotion` gates every animation; state changes still apply, just without motion.
8. Legacy aliases (`ZiroTheme.elevatedBackground`, `.subtleBorder`, `.inputBackground`) still compile — **do not use them in new code**; use the elevation/hairline names. Migrate call sites opportunistically.

---

## 3. Color tokens

All tokens are fixed sRGB values per appearance (implemented as dynamic `UIColor` closures — not opacity blends), so every ratio below is exact regardless of what sits beneath.

### 3.1 Surfaces (`ZiroTheme`)

| Token | Light | Dark | Role |
|---|---|---|---|
| `pageBackground` | `#F7F3EC` warm paper | `#151210` warm graphite | Base canvas: page bodies, chat transcript, List/Form pages |
| `raisedBackground` | `#FFFFFF` | `#201B16` | Cards, assistant bubbles, banner fills resting on the page |
| `wellBackground` (= `inputBackground`) | `#EFE9DF` | `#2A241D` | Recessed input wells: composer field, search fields |
| `overlayBackground` | `#FFFFFF` | `#302920` | Custom floating layers (menus, popovers, custom sheets) |

Elevation order (light): page < well < raised = overlay. Elevation order (dark): page < raised < well < overlay — wells read as "places you type", raised reads as "content that floats".

### 3.2 Hairlines

| Token | Light | Dark | Role |
|---|---|---|---|
| `hairline` (= legacy `subtleBorder`) | `#DCD2C2` | `#3B342B` | The default 1pt stroke on cards, bubbles, banners, chips, rings |
| `hairlineStrong` | `#C9BCA6` | `#4C4437` | Focused/selected outlines, brand-mark tile edge |

Hairlines are decorative (no contrast floor). Depth rule: **hairline always, shadow optionally** — a surface with a shadow but no hairline is wrong.

### 3.3 Text hierarchy

| Token | Light | Dark | Use |
|---|---|---|---|
| `primaryText` | `#1C1814` | `#F2EDE4` | Titles, message text, primary copy |
| `secondaryText` | `#5C544A` | `#A89F92` | Descriptions, banner messages, footers |
| `tertiaryText` | `#6E6659` | `#9A9184` | Timestamps, SHA fragments, locked parameters |

Warm-tinted near-black / warm-white — pure `#000`/`#FFF` reads clinical and is reserved for on-accent fills (`accentForeground`).

### 3.4 Accent (the ember)

| Token | Light | Dark | Use |
|---|---|---|---|
| `accent` (=`Color.accentColor`, asset) | `#8A5A00` | `#F2C14E` | Primary fills, focus rings, cursor, progress, active icons |
| `accentForeground` (asset) | `#FFFFFF` | `#000000` | Text/icons **on** accent fills |
| `accentContainer` | `#F1EBE0` | `#392F1D` | Tinted fill for secondary buttons, accent badges, pressed chips |

### 3.5 Semantic status pairs (text + pre-composited container)

| Tone (`ZiroTone`) | Text light | Text dark | Container light | Container dark |
|---|---|---|---|---|
| `.positive` → `positiveText` / `positiveContainer` | `#166E2B` | `#34C759` (system green) | `#E3EEE6` | `#22301E` |
| `.warning` → `warningText` / `warningContainer` | `#A64B00` | `#FF9500` (system orange) | `#F4E9E0` | `#3B2A13` |
| `.danger` → `dangerText` / `dangerContainer` | `#C40013` | `#FF554A` | `#F8E0E3` | `#3B221C` |
| `.info` → `infoText` / `infoContainer` | `#0062CC` | `#3D9BFF` | `#E0ECF9` | `#232A32` |
| `.neutral` → `secondaryText` / `neutralContainer` (= well) | `#5C544A` | `#A89F92` | `#EFE9DF` | `#2A241D` |

### 3.6 Data hues (categorical, NOT status)

| Token | Light | Dark | Use |
|---|---|---|---|
| `accentPurpleText` / `purpleContainer` | `#8236B8` / `#F0E7F6` | `#C973F5` / `#342631` | VISION capability badge, Q5 quant tier |
| `accentIndigoText` / `indigoContainer` | `#4F48D6` / `#EAE9FA` | `#8686FF` / `#2C2832` | Q6 quant tier |

Data hues never appear in banners, buttons, or status contexts. Quant tiers: Q8/F16 → `.info`, Q6 → `.indigo`, Q5 → `.purple`, Q4 → `.positive`, Q3/Q2 → `.warning` (existing mapping, now rendered via `ZiroBadge`).

---

## 4. Verified contrast ratios (WCAG, both appearances)

Floors: **4.5:1** text (any size the app renders), **3:1** icons/large text. Computed with the WCAG relative-luminance formula; script reproduced ratios, zero failures.

**Text hierarchy (≥4.5 required):**

| Token | Light `#F7F3EC`/`#FFFFFF`/`#EFE9DF` page/raised/well | Dark `#151210`/`#201B16`/`#2A241D` page/raised/well |
|---|---|---|
| `primaryText` | 15.95 / 17.65 / 14.61 | 16.00 / 14.64 / 13.16 |
| `secondaryText` | 6.73 / 7.44 / 6.16 | 7.14 / 6.54 / 5.87 |
| `tertiaryText` | 5.12 / 5.66 / 4.69 | 6.00 / 5.49 / 4.94 |

**Accent & semantics on page / raised / well (light, then dark):**

| Token | Light (page/raised/well) | Dark (page/raised/well) |
|---|---|---|
| accent `#8A5A00` / `#F2C14E` | 5.36 / 5.93 / 4.91 | 11.11 / 10.18 / 9.14 |
| positive | 5.75 / 6.36 / 5.27 | 8.40 / 7.69 / 6.91 |
| warning | 5.23 / 5.79 / 4.79 | 8.48 / 7.77 / 6.98 |
| danger | 5.66 / 6.26 / 5.18 | 5.91 / 5.41 / 4.86 |
| info | 5.25 / 5.80 / 4.81 | 6.51 / 5.96 / 5.36 |
| purple | 5.99 / 6.63 / 5.49 | 6.44 / 5.90 / 5.30 |
| indigo | 5.88 / 6.50 / 5.38 | 6.10 / 5.58 / 5.02 |

**Text on its own tinted container (≥4.5 required):**

| Pair | Light | Dark |
|---|---|---|
| accent on `accentContainer` | 5.00 | 7.83 |
| positive on `positiveContainer` | 5.35 | 6.27 |
| warning on `warningContainer` | 4.85 | 6.26 |
| danger on `dangerContainer` | 4.99 | 4.65 |
| info on `infoContainer` | 4.85 | 5.06 |
| purple on `purpleContainer` | 5.51 | 4.94 |
| indigo on `indigoContainer` | 5.43 | 4.71 |
| neutral (`secondaryText` on well) | 6.16 | 5.87 |

**On-accent (fills):** white on `#8A5A00` = **5.93**; black on `#F2C14E` = **12.51**. User-bubble labels, primary buttons, send glyph all clear AA.

Dark-mode notes (why tokens differ from system hues): system blue `#0A84FF` = 4.11:1 and system purple `#BF5AF2` = 4.19:1 on their 12% tinted containers — below floor — so dark `infoText`/`accentPurpleText` are lightened (`#3D9BFF`/`#C973F5`), matching the established indigo `#8686FF` precedent. Increased Contrast: text tokens sit ≥4.65 everywhere at defaults and the accent asset ships HC variants; iOS Increase Contrast needs no separate token set here.

---

## 5. Typography (`ZiroType`)

All roles are system text styles → Dynamic Type is inherited. Never fixed point sizes for text.

| Role | Font value | Use |
|---|---|---|
| `ZiroType.display` | `.largeTitle.weight(.bold)` | Onboarding page titles |
| `ZiroType.title` | `.title2.weight(.semibold)` | Empty-state hero title, outcome heroes |
| `ZiroType.heading` | `.title3.weight(.semibold)` | Card headers, model-detail identity, sheet titles |
| `ZiroType.rowTitle` | `.headline` | List row titles, banner titles, header-pill label |
| `ZiroType.body` | `.body` | Message text, primary copy |
| `ZiroType.supporting` | `.subheadline` | Descriptions, banner messages, subtitles |
| `ZiroType.footnote` | `.footnote` | Inline support text, dense button labels |
| `ZiroType.caption` | `.caption` | Metadata, banner actions |
| `ZiroType.micro` | `.caption2` | Badges, micro-meta, percentages |
| `ZiroType.technical(style, weight)` | `.system(style, design: .monospaced, weight:)` | **Technical voice** — model IDs, quant tiers, token counts, byte sizes, SHA fragments, pinned revisions |

Technical voice defaults: `.footnote/.regular`; `.caption2` for SHA fragments; `.caption2/.semibold` inside badges; `.body` for model IDs in detail headers. Digits in streaming/technical contexts may use `.monospacedDigit()` as today.

Wordmark treatment: `Text("ZIROEDGE")`, `.caption.weight(.bold)`, `.tracking(1.4)`, `secondaryText` (matches onboarding header).

---

## 6. Rhythm, measure, shadow, motion

### 6.1 Spacing (`ZiroTheme.Spacing`) — unchanged rhythm
`micro 2` · `xSmall 4` · `small 8` · `medium 12` · `large 16` · `xLarge 24` · `xxLarge 40`; half-step `badge 6` (capsule h-padding); `heroTop 96` (empty-state top air). Screen-level h-padding is `large` (16) inside bubbles/rows and `xLarge` (24) on full-page scroll content.

### 6.2 Radius (`ZiroTheme.Radius`)
`badge 6` badges/chips · `small 10` thumbnails, mini wells · `control 14` buttons, banners, composer field, text fields · `bubble 18` message bubbles + thinking indicator · `card 20` cards. Capsules for pills/primary buttons. All corners `style: .continuous` on cards/bubbles/fields.

### 6.3 Measure (`ZiroMeasure`)
`narrow 360` focused recoveries · `standard 520` heroes, onboarding copy, empty state, single-column forms · `wide 680` message bubbles · `full 760` transcript column. Always applied as `frame(maxWidth: cap)` centered by a full-width frame — never fixed widths.

### 6.4 Shadow language (`ziroShadow(_:)`)
| Level | Light | Dark | Used on |
|---|---|---|---|
| `.raised` | black 14%, r12, y3 | black 50%, r10, y3 | Primary buttons, floating cards |
| `.floating` | black 20%, r24, y8 | black 55%, r28, y8 | Overlays, hero CTAs, jump-to-bottom |
`nil` = no shadow. Shadows only ever accompany a hairline. List/Form chrome, banner fills, and cards inside scroll forms take **no** shadow.

### 6.5 Motion (`ZiroMotion` + `.ziroAnimation(_:value:)`)
| Token | Curve | Use |
|---|---|---|
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

### 7.8 `ZiroEmptyState` — the brand moment (see §8.1)
Brand mark + ember glow + wordmark + title + message + optional suggestion chips + optional actions; `maxWidth: standard`, `heroTop` top padding applied by the caller.

### 7.9 `ZiroBrandMark` — the mark
48-unit vector, scaled: graphite tile (continuous corners, radius 26% of size) with raised→well gradient, `hairlineStrong` tile edge, inner `hairline` chip ring, amber shield outline (2.4u stroke), amber node triad (1.5u lines, filled 4.4u nodes). Static; `.accessibilityHidden(true)`. Sizes: 28 (chrome), 48 (cards), 68 (`@ScaledMetric(relativeTo: .largeTitle)`, empty state).

### 7.10 `ZiroSectionHeader` — custom-surface section header
Uppercase `.caption.weight(.semibold)`, tracking 0.8, `secondaryText`, optional accent leading icon. Only outside List/Form (those keep system headers).

### 7.11 `ZiroProgressRing` — progress ring
`hairline` track, accent (or param tint) round-capped arc, trim from −90°, min 0.02, `stream` animation on progress change, `size 26` / `lineWidth 2.5` defaults, `accessibilityHidden(true)` — the scaling percentage label beside it carries the information (existing pattern in `ModelsView`).

### 7.12 `ziroMessageBubble(_:)` — bubble treatment
`user`: accent fill, `Radius.bubble` continuous; label `accentForeground`, h-padding 16 / v-padding 12. `assistant`: `raisedBackground` + `hairline` stroke, same radius/padding. Streaming assistant bubble: assistant treatment + amber caret (attributed `|` in accent, `cursorPeriod` blink, static when Reduce Motion) — unchanged behavior, new token colors. Row metrics: bubbles centered in a `full`-width column; bubble rows `maxWidth: wide`.

### 7.13 `ziroComposerField(isActive:)` — input well
`wellBackground` fill, `Radius.control` continuous, h-padding 16 / v-padding 12; rest state `hairline` 1pt; focus state **accent 1.5pt ring** (`press` transition) — this is the keyboard focus indicator, never remove it.

### 7.14 `ZiroHero` — symbol hero (kept, refined)
Large hierarchical symbol in tint, `ZiroType.title` headline, `.subheadline` secondary message, `maxWidth: standard`. For outcome pages (import complete, duplicate, store recovery). The chat empty state uses `ZiroEmptyState` instead.

### 7.15 Status symbols (contract-critical)
Semantic tones map: `.positive` → `checkmark.circle.fill`, `.danger` → `exclamationmark.circle.fill`, `.warning` → `exclamationmark.triangle.fill`, `.info` → `info.circle.fill` (via `ZiroTone.statusSymbol`). The test-contract symbols (`checkmark.circle.fill`, `exclamationmark.circle.fill`, `wrench.and.screwdriver`) **remain Image-based SF Symbols** wherever they appear; tint with the tone's text token (≥3:1 guaranteed).

---

## 8. Screen-by-screen directives

### 8.1 Chat (ChatView + ChatSurfaceDetails + MessageBubble + ChatOverlayComponents) — the flagship

1. **Empty state (the brand moment).** Replace `emptyState`'s `ZiroHero` with `ZiroEmptyState`:
   - Composition (top→bottom, centered, `maxWidth: standard`, `.padding(.top, heroTop)`): `ZiroBrandMark(68)` over a soft radial ember glow (accent 0.16→0, radius ≈ mark×1.15) → wordmark `ZIROEDGE` → `title` "Start a conversation" (`ZiroType.title`) → privacy message (`.subheadline`, secondary) → suggestion chips → CTA.
   - **Suggestions:** `["Explain a concept simply", "Help me draft a reply", "Summarize my notes"]` rendered by `ZiroEmptyState(suggestions:onSuggestion:)`; chip action writes the prompt into `viewModel.inputText` (append with a trailing space) and focuses the composer (`isInputFocused = true`) — reuses the existing send flow, no new behavior. Chips hidden while `viewModel.messages.isEmpty == false` (they only render in the empty branch anyway).
   - When `availableModels.isEmpty`, keep the `browse-models-button` CTA (identifier preserved) as `ZiroPrimaryButtonStyle` "Browse Models".
2. **Banners** migrate `ZiroStatusBanner(tint:)` → `tone:`: startup + runtime errors and `errorBanner` → `.danger` with `dangerText` (kills the last raw `.red`); persistence recovery, unavailable model, truncation, vision, modelRetry banners → `.warning`. All identifiers/announcements unchanged.
3. **Composer:** TextField gains `.ziroComposerField(isActive: isInputFocused)` (replacing the hand-rolled background/overlay — same metrics). `statusOrTokenHintRow`: token badge becomes `Text(...).font(ZiroType.technical(.caption2)).foregroundStyle(secondaryText)`; the "Download a model…" / "unloaded" hints stay `.caption2` `secondaryText`.
4. **Message list:** transcript column `frame(maxWidth: ZiroMeasure.full)`; bubbles `ziroMessageBubble(role)` with `maxWidth: ZiroMeasure.wide` on the row; assistant text `primaryText`; user label `accentForeground` on accent fill (already token-aligned). Thinking indicator: assistant bubble treatment + `secondaryText` "Thinking…" row (`.subheadline`). Message enter transition per §6.5. Jump-to-bottom: accent circle + `accentForeground` glyph + `.ziroShadow(.floating)`.
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

1. New colorset **`LaunchBackground`** in `Assets.xcassets`: universal `#F7F3EC`, dark `#151210` (same as `pageBackground`).
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
- **Labels/values:** "Chat model, …", "No model yet", "Assistant said: ", "You said: ", "Send message", "Stop generating", "Message ZiroEdge", "Conversations", "New Conversation", "Settings", "Models", "Manage Models", "Active Model", "Available", "Installed", "Import from Hugging Face", "Inspect Repository", "Pinned Source", "owner/repository or URL", "Skip", "Continue", "Get Started".
- **Symbols:** `checkmark.circle.fill`, `exclamationmark.circle.fill`, `wrench.and.screwdriver` remain Image-based with those symbol names.
- **Spoken phrases:** "installed", "needs repair", "available to download", "downloading, N percent complete".
- **Announcements:** "Assistant response complete" / "Response stopped".
- **Streaming:** stable label "Assistant is responding".

## 11. Migration map (mechanical replacements)

| Before (in views) | After |
|---|---|
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

- **Do** keep one amber accent discipline: actionable, alive, or load-bearing only.
- **Don't** introduce a second shadow direction, a sixth radius, or a new status hue.
- **Don't** put data hues (purple/indigo) on banners, buttons, or status rows.
- **Don't** fix text sizes; don't fix control heights below 44; don't hardcode widths.
- **Don't** animate anything without a Reduce-Motion exit.
- **Do** leave List/Form system chrome alone — the token system shows through content, tint, and type, not by fighting UIKit chrome.

# LessMeet visual direction

Version 1 · 2026-09-25 · Human-approved landing-page style.

Purpose: preserve the visual language for a later native SwiftUI refactor, not
authorize that refactor or specify new app behavior. Human accepted the landing
page's appearance; native screens, dark mode and accessibility still need their
own implementation and review. Work status stays in [STATUS.md](STATUS.md).

## Reference and source of truth

- [Landing page](../website/public/index.html) and [CSS](../website/public/style.css)
  are the implemented reference. CSS at approval:
  `3457327eb2088d42702beaf3fc8b3ff86549f72f859a75481737102854224788`.
- This document records intent and token mappings. If an approved design changes,
  update it alongside the implementation; do not maintain a divergent JSON copy.
- The Mac window on the website is a **fictional layout illustration**, not an
  actual app screenshot or a requirements document. Its transcript, timestamps,
  waveform and AI answer are synthetic. Never carry them into live product states.

## Character

Warm, quiet, editorial, native. Ivory surfaces and olive accents; generous spacing,
clear hierarchy and restrained detail. The product should feel like a place to
listen and review, not an analytics dashboard or a chat toy.

- Use one strong focal point, then progressively quieter supporting information.
- Pair clean system sans-serif with occasional italic serif emphasis.
- Separate sections with space and hairlines; avoid wrapping every item in a card.
- Let recording/transcript content dominate. Decoration must not compete with it.
- Prefer descriptive labels and honest states over promotional claims in the app.

Avoid neon gradients, glass-heavy panels, excessive pills, deep nested cards,
large shadows on every control, tiny all-caps body text and decorative motion.

## Light palette — exact web values

Names below are semantic suggestions for future Swift tokens, not existing symbols.
Hex values are sRGB. Preserve foreground/background pairings, not just swatches.

| Role / suggested token | Value | Use |
| --- | --- | --- |
| `background` | `#F7F7F0` | Warm page/workspace canvas (`--paper`) |
| `textPrimary` | `#28362A` | Main headings and body (`--ink`) |
| `textSecondary` | `#626A5D` | Supporting text (`--muted`) |
| `separator` | `#D9DDCF` | Quiet dividers (`--line`); not sufficient as a focus indicator |
| `actionPrimary` | `#354B33` | Primary action background (`--green`) |
| `onActionPrimary` | `#FFFFFF` | Primary action text |
| `actionHover` | `#456341` | Web primary-action hover |
| `accentSoft` | `#D4E3A5` | Emphasis/selection (`--accent`), not body text on ivory |
| `focus` | `#75944D` | Web focus outline; native uses platform focus treatment |
| `surface` | `#FCFCF9` | Content surface in the illustration |
| `surfaceSidebar` | `#F0F2E9` | Quiet sidebar surface |
| `selection` | `#DFE7CE` | Selected library row; pair with a non-color selection cue |
| `surfaceInset` | `#F5F7EE` | Example answer note |
| `highlight` | `#EDF0D7` | Transcript highlight, with normal readable text |
| `surfaceStrong` | `#30452F` | Dark green editorial panel, used sparingly |
| `onSurfaceStrong` | `#F5F7EC` | Heading on dark green |
| `onSurfaceStrongSecondary` | `#D0DBC7` | Body on dark green |
| `illustrationBackdrop` | `#DCE1CF` | Marketing illustration backdrop, not a default app surface |

Measured main text/canvas: 11.82:1; secondary/canvas: 5.22:1;
white/primary action: 9.52:1; secondary text/dark panel: 7.25:1.
These are selected color-pair calculations, not a full accessibility certification.

Dark mode is **not designed yet**: the landing page intentionally uses light mode.
Do not invert these colors or treat the dark editorial panel as a dark-mode palette.
For the future app, retain platform appearance behavior until semantic light/dark
variants have been designed and checked in context.

## Typography

| Role | Web reference | Native translation intent |
| --- | --- | --- |
| Marketing hero | System sans, 44–78 px, weight 500, line-height 1.09, tracking −0.065 em | Marketing only; do not put hero-scale text into a working app toolbar |
| Editorial emphasis | Georgia italic with Times New Roman/serif fallback | Occasional empty-state/onboarding emphasis, not transcripts or controls |
| Section heading | 33–48 px, weight 500, line-height 1.16 | Native title hierarchy at an appropriate window scale |
| Body | System sans, mostly 13–17 px, line-height 1.7–1.9 | System body typography; optimize long transcripts for reading |
| Eyebrow | 10 px, semibold, tracking 0.16 em | Sparse section metadata, not an app-wide label style |
| Time/duration | Tabular digits | Stable-width playback counters; accessible descriptive labels |

Use the Mac system font for app controls, navigation and document content. Website
illustration labels as small as 6–11 px simulate a scaled screenshot: **do not copy
those sizes into SwiftUI**. Native point sizes, text scaling, localization and
window resizing must be evaluated separately. No external font dependency needed.

## Space, shape and depth

The website uses optical spacing, not a rigid token scale. Reference anchors:

- Control/inline gaps: 8–12 px; row/content gaps: 16–24 px.
- Panel padding: roughly 24–40 px; large editorial sections: 70–120 px apart.
- Corner radii: 5 px inset notes/rows, 7 px buttons, 10 px app illustration,
  12 px large panels. Prefer native control/window shapes in the real app.
- Hairline separation rather than heavy outlines. Primary actions have one dark
  fill; secondary actions remain quieter.
- Illustration shadow: `0 25px 45px -18px #3e4e394a` plus
  `0 3px 7px #3e4e3912`. This belongs to the marketing window presentation,
  not every native panel. The OS owns actual window shadows and traffic lights.

Suggested native spacing vocabulary for a future implementation: 4, 8, 12, 16,
24, 32 points, with optical exceptions. This is a starting proposal, not a claim
that the website already implements that scale or a requirement to rewrite layout.

## Component translation to the Mac app

| Element | Carry forward | Do not copy literally |
| --- | --- | --- |
| Library/sidebar | Subtle surface, clear selected row, title before metadata | Fictional recordings; hiding navigation merely because web mobile hides the illustration sidebar |
| Recording controls | One obvious recording action and legible status | Website's decorative play glyph or nonfunctional controls |
| Playback | Calm spacing, readable durations, restrained waveform accents | Decorative waveform as if it represents real audio; preserve real seek/playback behavior |
| Transcript | Readable measure, speaker/time hierarchy, quiet highlights | Invented speakers, citations, timing or an accuracy guarantee |
| Chat | Distinguish question, answer and source/context clearly | Claiming generated text is verified or concealing uncertainty/error states |
| Account/plan/settings | Native controls, concise grouping and secondary text | Turning settings into marketing cards or hiding prices/limits |
| Empty/error/loading | Calm language and an actionable next step | Fake populated results to make a screen look finished |

Preserve recording/library/detail/chat workflows and existing split-view behavior.
Adapt to window space instead of imposing a new vertical-only architecture. A
visual refactor must not change capture, upload confirmation, account isolation,
durable recovery, quotas, purchases, retention, deletion or activation gates.

## Interaction and accessibility

- Real buttons, links and disclosure controls must support keyboard navigation,
  focus, disabled/loading/error states and meaningful accessibility labels.
- Selected, recording, paused and failed states need text/icons as well as color.
  Do not reuse decorative green dots as evidence a backend is connected.
- Use platform recording/destructive/error semantics; do not recolor danger as
  olive merely to fit the palette. Error/warning color tokens are not approved here.
- Web motion is limited to a 0.2 s hover treatment and smooth anchor scrolling;
  reduced-motion disables both. Native should use restrained platform transitions,
  respect reduced motion and never delay recording controls with animation.
- Validate long names, transcripts, localization, narrow windows, keyboard focus,
  text scaling and increased contrast. Do not truncate essential state or hide
  important privacy/error information for visual neatness.

## Future SwiftUI refactor boundary

When that task is authorized, introduce a small shared semantic palette/style layer
in the existing presentation area, not a new UI framework. Keep colors/spacing out
of business models. Migrate one representative library/detail flow first and
review real native screenshots before spreading the style across other screens.

Acceptance should include actual native render/interaction checks plus relevant
existing regression tests: recording start/stop, playback/seek, selection/account
switches, upload confirmation, saved transcript/chat and reopen/recovery. A passing
color or snapshot test alone cannot establish those behaviors.

Current scope is documentation only. No Swift source, app icon, native theme,
public release, privacy-policy approval or provider setting is changed by this guide.

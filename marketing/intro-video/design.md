# meow-ios — Intro Video Design

iOS 26 Liquid Glass language. Deep navy gradient stage, frosted-glass cards
with continuous corners, SF Pro / Inter typography, iOS-system accent colors.
Premium and calm — every motion eases in, nothing snaps.

## Palette

| Token             | Hex                        | Usage                                      |
| ----------------- | -------------------------- | ------------------------------------------ |
| `bg-deep`         | `#06101F`                  | Outer background base                      |
| `bg-mid`          | `#0F1F3D`                  | Gradient mid-stop                          |
| `bg-edge`         | `#1A3566`                  | Gradient highlight edge                    |
| `glass-fill`      | `rgba(255,255,255,0.06)`   | Frosted card body                          |
| `glass-border`    | `rgba(255,255,255,0.14)`   | Glass card hairline                        |
| `glass-highlight` | `rgba(255,255,255,0.24)`   | Top inner-stroke on glass                  |
| `text-primary`    | `#FFFFFF`                  | Headlines, primary value text              |
| `text-secondary`  | `rgba(235,235,245,0.65)`   | Captions, labels                           |
| `text-tertiary`   | `rgba(235,235,245,0.35)`   | De-emphasized hints                        |
| `accent-blue`     | `#0A84FF`                  | Primary action, proxy path                 |
| `accent-cyan`     | `#5AC8FA`                  | Highlight glow, data bars                  |
| `accent-green`    | `#30D158`                  | Direct-route / success state               |
| `accent-purple`   | `#BF5AF2`                  | meow-rs engine accent                       |

## Typography

- Family: `Inter` (built-in, closest in-engine match to SF Pro Display)
- Weights: 800 (display), 700 (headline), 500 (body), 400 (labels)
- `font-feature-settings: 'ss01', 'cv11'` for clean digits
- `tabular-nums` on every number column

## Corners & Spacing

- Cards: `border-radius: 28px` (continuous, iOS 26 squircle approximation)
- Pills: `border-radius: 999px`
- Padding density: 48–96px container insets, 24–32px gap rhythm

## Depth

Layered. Glass cards use:
- `box-shadow: 0 30px 80px -20px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.16)`
- Soft accent glows (cyan/blue) at 18–28% opacity behind hero elements

## Motion

- Entrances: `power3.out` (default), `expo.out` (hero reveals), `back.out(1.4)` (badges)
- Exits: scene-container crossfade only — no per-element exits except final scene
- Stagger: 90–140ms
- First animation offset: 0.25s after scene start
- Scene crossfade: 0.55s overlap

## Scene Plan

| #  | Beat              | Window        | Idea                                                        |
| -- | ----------------- | ------------- | ----------------------------------------------------------- |
| 1  | Logo open         | 0.0–5.0s      | "meow" wordmark + tagline, soft pulse                        |
| 2  | meow-rs engine     | 5.0–11.0s     | Protocol pills cascade around a central engine card         |
| 3  | NE packet tunnel  | 11.0–17.0s    | Phone silhouette, app icons drawn into a tunnel beam         |
| 4  | Smart CN routing  | 17.0–23.0s    | Split path — CN-IP direct (green) vs global proxy (blue)    |
| 5  | Traffic dashboard | 23.0–29.0s    | 7-day bar chart animates up, live throughput counter        |
| 6  | TestFlight CTA    | 29.0–36.0s    | "Join the public beta" + URL + final fade                   |

## What NOT to Do

- No saturated rainbow gradients on dark bg (H.264 banding)
- No drop-shadow on text — use accent glows only on hero elements
- No emoji as design — SF Symbol-style line glyphs only (drawn as SVG/CSS)
- No `text-shadow` for emphasis — use weight + color contrast
- No bouncy / overshoot easing on text (back.out only on small badges/pills)

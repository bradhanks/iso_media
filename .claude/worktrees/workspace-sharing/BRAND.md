# Perfect Paper — Brand

**Voice:** literate, exacting, warm. A serious writing tool with a human touch —
think a well-made fountain pen, not a robot.

## Palette

| Token | Hex | daisyUI role | Use |
|-------|-----|--------------|-----|
| Paper | `#fdfcf8` | `base-100` | primary background |
| Paper 2 | `#f6f3ea` | `base-200` | raised surfaces |
| Ink | `#2b2620` | `base-content` | primary text |
| Ink Soft | `#4a4440` | — | secondary text |
| Rust | `#9b5a3c` | `primary` | primary brand / CTAs |
| Rust Light | `#c47a52` | `accent` | hover / accent |
| Slate | `#5a6b8c` | `secondary` | secondary / links / navigation |
| Gold | `#c9a227` | (use sparingly) | highlights |

The live values are encoded as the `perfectpaper` daisyUI theme in
`assets/css/app.css` (oklch). This table is the human reference; the theme is the
source of truth for the build.

## Type

- **Fraunces** — display / headings (serif, characterful) → `font-display`
- **Newsreader** — long-form reading (serif) → `font-body` / `.prose-reading`
- **Outfit** — UI / labels (sans) → `font-ui` / default `font-sans`

Scale is a 1.250 major third from 1rem. Display helpers: `.text-display-xl/2xl/3xl`.

## Feel

- Warm paper backgrounds, never stark white.
- Generous line-height for reading (1.7).
- Rust for action, slate for navigation, gold used sparingly.
- Rounded but not pill-shaped: radius 0.375–0.75rem.

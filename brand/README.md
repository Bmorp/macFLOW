# Mac Flow — brand kit

Everything here is generated from one definition of the mark, so every file matches:

```bash
swift scripts/make_brand.swift brand      # logos, mark, star, wordmark, avatars (SVG · PDF · PNG)
python3 scripts/make_brand_sheet.py       # the overview sheet (needs Pillow)
```

## The mark

A stadium — the island, **3.156 : 1** — with a four-point star cut through it. The star's vertical points are short
and sharp; its horizontal points stretch into hairlines, like light escaping the island. In fractions of the pill's
height *H*: star half-height 0.3828 *H*, half-width 0.7266 *H*, curve controls 0.0156 *H* (beside the vertical
points) and 0.3203 *H* (along the horizontal axis). The same numbers drive the app (`DesignSystem/Brand.swift`),
the installer art and the app icon.

**The star alone is Flow**, the assistant inside Mac Flow. Use it wherever Flow speaks or acts.

## Files

| Folder | What |
|---|---|
| `svg/` | Vector masters. `macflow-logo-stacked-*` is the primary logo; `-horizontal-*` for tight heights; `mark-*`, `star-*`, `wordmark-*`; `avatar-*` squares; `icon-layer` is the app icon's glass layer. |
| `pdf/` | The same artwork as vector PDF (print, Keynote, Figma import). |
| `png/` | Transparent exports at 2×, 4× and 8× (avatars at 256–1024 px). `-light` = for light backgrounds, `-dark` = for dark. |
| `icon/` | The app icon as macOS renders it (Liquid Glass, compiled from `Resources/AppIcon.icon`). |
| `macflow-brand-sheet.png` | Everything on one page. |

## Colour

| Name | Hex | Use |
|---|---|---|
| Ink | `#0A0A0B` | "Mac", the mark |
| Flow grey | `#636467` | "Flow" on light backgrounds |
| Paper | `#FFFFFF` | Light backgrounds |
| Flow on dark | `#8E8E93` | "Flow" on dark backgrounds |
| Flow violet | `#9E85FF` | The assistant, inside the app only |

Both greys meet 4.5 : 1 contrast on their backgrounds.

## Type

The wordmark is **SF Pro Medium**, outlined. The interface uses SF Pro (the system font). Apple licenses SF Pro for
designing and building apps for its platforms; before registering "Mac Flow" as a trademark or printing it on
merchandise, either confirm that use with Apple's license or regenerate the wordmark in an open font such as
Inter (change the font in `wordmarkOutlines` and rerun).

## Rules

- Clear space: half the mark's height on every side (built into every file).
- Minimum size: the mark 16 px tall on screen (24 px in print); the wordmark 12 px cap height.
- Use the files as they are: never recolour the star, stretch, rotate, outline or add effects to the mark.
- On photos or colour, use the white versions on a dark area, or the black on a light one.

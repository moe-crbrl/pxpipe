# Grok: image-only vs image+factsheet (production contract)

Live run of `factsheet-vs-image.mjs`, 2026-07-09. Model: `grok-4.5`.
Fixture: same precision-critical synthetic session as the density harness
(hex / camelCase / path / port / gist / guard).

## Question

Production Grok keeps **5×8** packing because pure-image exact OCR fails at
that density. Does the shipping **image + factsheet** path clear the Opus
exact bar without giving up density? Is a denser pure-image packing still
worth considering?

## Results

| arm | exact | confab | gist | guard | save≈ | notes |
|-----|------:|-------:|:----:|:-----:|------:|-------|
| `5x8_image_only` | **0/4** | **4** | ok | ok | 76% | confabulates every ID |
| `5x8_image_plus_factsheet` | **4/4** | **0** | ok | ok | **70%** | **shipping contract** |
| `5x8_grid_plus_factsheet` | 4/4 | 0 | ok | ok | 70% | style no worse with sheet |
| `5x8_color_plus_factsheet` | 4/4 | 0 | ok | ok | 70% | style no worse with sheet |
| `d4_c84_image_only` | 4/4 | 0 | ok | ok | **30%** | pure-image Opus bar, half the density win |

### Image-only confabulations (5×8)

- hex `a3f9c1e0b7d2` → `5c5e4e0b9d2`
- camel `tokenLedgerShard` → `tokenEdgeShard`
- path `src/core/anthropic-vision.ts` → `pro/core/anthropic-client.ts`
- port `47821` → `97821`

Factsheet extraction already includes all four probes plus `--max-visual-tokens`
from the same fixture. The Responses transform attaches that sheet next to slab
and history images (`src/core/openai.ts`).

## Verdict

1. **Grok stays opt-in only** (not in `DEFAULT_MODEL_BASES`). Same bar as Opus:
   not good enough as a silent pxpipe default.
2. **Do not change default Grok density when opted in.** 5×8 stays.
3. **Exact IDs are a factsheet problem, not a cell-size problem** at production
   density. Image+factsheet passes 4/4 with ~70% fixture savings; pure-image d4
   also passes but only ~30% savings.
4. Style knobs (grid, colorCycle) at 5×8 do not replace the factsheet for exact
   recall; with the sheet they are fine and optional.
5. Still open only if factsheet **coverage** misses a token class in the wild —
   fix extractors, do not bloat cells.

Enable with `PXPIPE_MODELS=...,grok-4.5` or the dashboard Grok chip.

## How to re-run

```bash
pnpm run build
GROK_DENSITY_LIVE=1 node eval/grok-density/factsheet-vs-image.mjs
```

Receipt: `eval/grok-density/factsheet-vs-image-results.json`.

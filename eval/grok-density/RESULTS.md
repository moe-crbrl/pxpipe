# Grok density / image-recall sweep — results

Live run of `run.mjs`, 2026-07-09. Model: `grok-4.5`. Geometry: default
Responses-path profile (`stripCols=152`, `maxHeightPx=1932`, vision tile
`85/170`). `results.json` is this run.

## Question

Prior recall work covered Fable 5 and Opus 4.8. Grok is already imaging on the
Responses path under the unmatched-model fallback profile. Does it read
production-density images well enough, or does it need a lower-density profile?

## Exact-string recall

| variant | page px | img tok | savings | exact | confab | gist | guard |
|---------|---------|--------:|--------:|:-----:|:------:|:----:|:-----:|
| `5x8` (production) | 768×360 | 425 | 64% | **0/4** | **4** | ok | ok |
| `7x10`            | 764×458 | 425 | 64% | 3/4 | 1 | ok | ok |
| `9x12`            | 764×1064 | 1105 | 5% | **4/4** | **0** | ok | ok |

### Per-probe notes

**5x8 (production density)** — confabulates every exact probe:
- hex `a3f9c1e0b7d2` → `5c5eacb0a2`
- camel `tokenLedgerShard` → `tokenBudget`
- path `src/core/anthropic-vision.ts` → `pro/core/anthropic-client.ts`
- port `47821` → `97821`
- gist and guard still pass (lossy gist + safe abstention)

**7x10** — path/camel/port exact; hex still wrong (`a03c1e0b7d2`, missing one
nibble). Gist + guard ok.

**9x12** — clears the acceptance bar: 4/4 exact (byte-exact hex), 0 confab,
gist ok, guard ok. Savings collapse to ~5% under the current tile cost model
because the taller page bills more vision tokens.

## Verdict

- **Yes, density-dependent.** Production `5x8` is not safe for Grok exact
  recall: 0/4 exact, 4 confabulations on n=1.
- Monotonic with Opus: denser cells confabulate, larger cells recover exact
  strings. Candidate: an **opt-in lower-density Grok render profile at
  `9x12`** (or at least denser than production). **Not** a silent default
  change, and **not** a `DEFAULT_MODEL_BASES` change.
- Current unmatched-model vision profile (`tile 85/170`, 152 cols, 1932 px
  height) is only a cost/geometry fallback. It does not measure Grok
  readability. A real Grok profile should encode both:
  1. render density that clears exact recall (`9x12` candidate)
  2. vision billing numbers once Grok's real image-token formula is known
- n=1 per cell (harness design). Re-run before baking a production profile.

## How this was run

```bash
pnpm run build
GROK_DENSITY_LIVE=1 node eval/grok-density/run.mjs
```

Endpoint: OpenAI-compatible Responses via `OPENAI_BASE_URL` + `OPENAI_API_KEY`.
Harness bypasses pxpipe compression so scores measure raw image reading.

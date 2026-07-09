# Grok density / image-recall sweep

**Question:** prior pxpipe recall work covered Fable 5, Opus 4.8, and GPT notes.
Grok is imaging in production through the OpenAI Responses path, but it has no
measured profile. Does Grok read production-density images well enough, or does
it need a lower-density / different strip geometry profile?

This harness answers that with a measurement. It does **not** change production
defaults. A Grok profile should only be added if the numbers clear the bar
below.

## What it does

For each render **variant** (cell size) it:

1. Renders one synthetic session transcript to PNG(s) with the production
   renderer, using the OpenAI-path page geometry Grok actually sees today
   (strip capped at 768 px wide / 1932 px tall — the default GPT-profile
   geometry that unmatched models, including Grok, currently inherit).
2. Asks the model a fixed battery of questions against the image(s).
3. Scores exact recall, gist, confabulation guard, and refusal.

- **Variants** (cell = 5+wBonus × 8+hBonus px):
  - `5x8` — production density (`{cellWBonus:0, cellHBonus:0}`)
  - `7x10` — `{cellWBonus:2, cellHBonus:2}`
  - `9x12` — `{cellWBonus:4, cellHBonus:4}`
  Cols drop as cells grow so the strip stays ≤ 768 px wide (no provider
  short-side downscale of 5 px glyphs).
- **Default model:** `grok-4.5` (override with `GROK_DENSITY_MODEL`).
- **Tasks:**
  1. exact 12-char hex recall
  2. camelCase identifier recall
  3. file path recall
  4. port number recall
  5. gist recall (retry budget)
  6. confabulation guard (unstated secret → "NOT STATED")

## Acceptance bar (same spirit as opus-density)

A density is "good enough" only if **all** of:

- exact recall ≥ 4/4 on the battery
- 0 confabulations
- gist ok
- guard ok (abstains / "NOT STATED", does not invent)
- image-token savings vs text still positive under the current cost model

If only denser-than-production cells clear the bar, the candidate is an opt-in
lower-density Grok render profile — **not** a silent default change.

## How to run

```bash
pnpm run build

# Dry-run: render + token accounting only (no model calls)
node eval/grok-density/run.mjs

# Live: needs OPENAI_BASE_URL + OPENAI_API_KEY pointing at an OpenAI-compatible
# Responses endpoint that serves the Grok model. Bypass pxpipe so the eval
# measures raw image reading, not compression.
GROK_DENSITY_LIVE=1 node eval/grok-density/run.mjs

# Optional overrides
GROK_DENSITY_MODEL=grok-4.5 GROK_DENSITY_LIVE=1 node eval/grok-density/run.mjs
```

Outputs:

- `eval/grok-density/results.json` — machine-readable
- stdout table — human-readable
- `eval/grok-density/RESULTS.md` — written by hand after a live run (do not
  invent numbers)

## Why a separate harness

`eval/opus-density` talks Anthropic Messages. Grok arrives on the OpenAI
Responses path with different page geometry and vision billing, so it needs
its own client and cost accounting. Shared pieces (fixture, scoring rules)
mirror the Opus harness on purpose so results are comparable.

## Production contract (image + factsheet)

Density sweeps above measure **pure image** reading. Production Grok does not
rely on that for exact IDs: the Responses transform attaches a verbatim
fact-sheet next to the 5×8 images. Live proof that image-only fails and
image+factsheet clears the Opus exact bar:

```bash
GROK_DENSITY_LIVE=1 node eval/grok-density/factsheet-vs-image.mjs
```

See [FACTSHEET_RESULTS.md](./FACTSHEET_RESULTS.md).


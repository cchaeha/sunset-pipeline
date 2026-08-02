# SUNSET data infrastructure — handover

Written 2026-08-01, ahead of a UA → ASU transition. The point of this document
is that SUNSET should keep running whether it stays with Chris Lim, moves to
ASU, or is handed to Pima County DEQ. Nothing below depends on a University of
Arizona account, a specific laptop, or a person.

## What this is

The SUNSET dashboard (https://aq-sensors.shinyapps.io/SUNSET/) shows air quality
from 20 QuantAQ MODULAIR sensors at Pima County schools, deployed under EPA
grant 98T60201 (PDEQ × University of Arizona).

Data collection is decoupled from the dashboard. This repo collects on a
schedule and publishes small artifacts; the dashboard reads those artifacts.
The dashboard does not talk to the sensor API.

```
QuantAQ API ──> GitHub Actions (every 20 min) ──> DuckDB (working, cached)
                                              ├─> archive/*.parquet  (durable, committed)
                                              └─> gh-pages artifacts ──> Shiny dashboard
```

## The three things someone must hold

| Asset | Where | Notes |
|---|---|---|
| **This repo** | GitHub, public | Transfer to another account/org to hand the project over |
| **`QUANTAQ_API_KEY`** | GitHub repo secret | From the QuantAQ account that owns the 20 sensors |
| **shinyapps.io login** | `aq-sensors` account | Standalone account — CONFIRM the email on it is not a UA address |

If all three transfer, the system keeps running. If any one is lost, see
"Failure modes".

## Running it

```bash
export QUANTAQ_API_KEY=...
Rscript 30_run_pipeline.R              # incremental, last 3 days
Rscript 30_run_pipeline.R --days 14    # widen to repair a gap
```

Everything is idempotent. Running twice changes nothing; running after an
outage repairs the gap. In CI it runs every 20 minutes; manual runs are
available from the Actions tab ("Run workflow").

## Storage, and what is actually durable

**`archive/YYYY/YYYY-MM-DD.parquet` is the asset that matters.** One immutable
file per completed day, ~550 KB, ~17 MB/month, ~207 MB/year. Committed to git,
so anyone who clones the repo has the full measurement record. This is the only
copy that survives losing API access.

**`data/sunset.duckdb` is a cache.** Rebuildable from the archive plus the API,
gitignored, and cached between CI runs. If it is lost the next run restores from
Parquet and backfills the tail. Do not treat it as the source of truth.

**`data/export/` is published, not stored.** Force-pushed to the `gh-pages`
branch each run so the frequent refresh leaves no git history:

| Artifact | Size | Purpose |
|---|---|---|
| `latest.csv` | ~2 KB | One row per sensor — the map |
| `status.csv` | ~1 KB | Per-sensor state and the reason for any missing PM |
| `hourly_30d.csv` | ~238 KB (64 KB gz) | 30 days of hourly values |
| `app_feed.csv.gz` | ~1.7 MB | 1-minute records, 8 days, in the dashboard's schema |
| `manifest.json` | <1 KB | Provenance — generation time, span, calibration version |

## Connecting the dashboard

Set `SUNSET_FEED_URL` on the shinyapps.io app to the raw gh-pages URL:

```
https://raw.githubusercontent.com/<owner>/<repo>/gh-pages/app_feed.csv.gz
```

The app prefers that URL, falls back to a bundled copy, and falls back again to
the live API. It **ignores any artifact older than 6 hours** so a stale file is
never silently served.

## Failure modes

**QuantAQ subscription lapses** — the single point of failure no architecture
fixes. Ingestion stops; the archive keeps everything collected so far. This has
happened before and data vanished from the public site. **Owner as of
2026-08-02: Chris Lim handles the renewal**, and it carries across the UA → ASU
move. Whoever inherits the project must take this over explicitly; it is not
attached to any institution's account.

**Actions cache evicted** — self-healing. One slower run. Verified 2026-08-01 by
deleting the working store: the pipeline restored 54,547 rows from 2 Parquet
files, backfilled the tail from the API, and ended with an identical record
count.

**Why CI and not a scheduled job on the laptop.** The laptop is being retained
through the move, so a local `launchd` schedule is possible and is a fine
*secondary* — it is the right place for wide manual backfills (`--days 30`) and
a second copy of the archive. But a laptop sleeps and travels, and every gap
leaves the published artifact stale, which pushes the public dashboard onto its
slow API fallback. CI runs regardless of machine state and transfers with the
repo, so it stays primary.

**Pipeline stops running** — the dashboard keeps serving until artifacts pass
the 6-hour staleness limit, then falls back to the live API (slow but correct).
Check the Actions tab.

**Sensor shows no PM** — usually not a fault. The MODULAIR optical particle
counter stops above ~50 °C and resumes when cooler; `pm_status` distinguishes
`thermal_cutoff` (recovers on its own) from `opc_down` (needs a service call).
See README.

## Known open items

- **MOD-00564 (Flowing Wells)** offline since 2026-03-28; needs a site visit.
- **MOD-00554, MOD-00558** persistently `opc_down`; candidates for service.
- **CO / NO2 / NO are not calibrated.** CO needs a random forest and is
  cool-season only; the nitrogen channels were under review with QuantAQ as of
  July 2026 and should not be published as quantitative values.
- The dashboard source of record is `~/Documents/PROJ/Shiny/` (it has the
  institutional logos). A second, never-deployed copy exists at
  `TASK/SUNSET/` with ~378 lines of extra PurpleAir/EPA layer work.

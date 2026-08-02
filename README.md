# SUNSET ingest pipeline

Decouples data collection from the dashboard. The Shiny app currently makes 21
live QuantAQ calls per page load (~120 s in production) and can only ever hold
about 17 hours of history — which is why its "Last 7 Days" view has never had
the data it advertises. This pipeline collects on a schedule instead, so the
front end can read a file and render immediately.

Deliberately mirrors the AirSMART `code/30*` pattern. One pipeline shape for the
lab, not two.

## Run

```bash
export QUANTAQ_API_KEY=...
Rscript pipeline/30_run_pipeline.R             # incremental, last 3 days
Rscript pipeline/30_run_pipeline.R --days 14   # wider repair window
```

Everything is idempotent (UPSERT on `sn` + `timestamp`), so re-running changes
nothing and a run after an outage repairs the gap by itself. Measured ~1.1 min
for 3 days x 20 sensors; ~0.3 min for 1 day. Suggested schedule: every 15 min.

## Files

| File | Role |
|---|---|
| `30_config.R` | Paths, sensor list, QC thresholds |
| `30a_ingest.R` | Per-day QuantAQ pull → UPSERT into DuckDB |
| `30b_qc.R` | Hourly aggregation + `pm_status` labelling |
| `30c_export.R` | Small dashboard-ready artifacts |
| `30_run_pipeline.R` | Orchestrator; run this |

## Outputs

`data/sunset.duckdb` — append-only store, `sensor_data` (1-min) and
`sensor_hourly` (aggregated + labelled).

`data/export/` — what a front end should read:

| Artifact | Contents |
|---|---|
| `latest.csv` | One row per sensor. What the map needs. ~2 KB |
| `status.csv` | Per-sensor state with an explicit reason for missing PM |
| `hourly_30d.csv` | 30 days of hourly values — the history the app never had |
| `manifest.json` | Generation time, record count, span. Detects a stale artifact |

## `pm_status` — why a value is missing

A missing value always carries a reason. This is the part that matters
operationally, because two very different problems look identical on a map.

| Status | Meaning | Action |
|---|---|---|
| `ok` | PM reported | — |
| `thermal_cutoff` | No PM, enclosure ≥ 47.5 °C, **and the unit produced PM elsewhere the same day** | None. It comes back on its own |
| `opc_down` | No PM anywhere in the day | Service call |
| `no_pm` | Missing but cool and not persistent | Investigate |
| `offline` | No records at all | Site visit |

**Why the same-day recovery test, not just temperature.** The MODULAIR optical
particle counter has a thermal limit near 50 °C: it stops returning counts and
resumes once cooler. Measured at Mission View 2026-07-29..31 — 100% PM
availability below 47 °C, 36% at 49.0 °C, 0% at 50.3 °C, recovered by 18:00.
That is the cause of the white dots partners reported on 2026-07-30, and it is
**not a fault**.

But temperature alone cannot separate that from a genuinely dead sensor:
Lauffer and Marana sat at a *mean* of 38 °C with no PM for 64 hours each, while
Mission View, Ajo, Valdez and Roadrunner lost single hours at 48–50 °C and came
back. Whether the unit recovered within the same day is the signal that
separates "wait" from "dispatch."

## Calibration (applied)

`30d_calibrate.R` writes `pm25_cal` and `o3_cal` into `sensor_hourly`, using the
hold-out-validated models from `Quant/CALIBRATION_FINAL.md`:

| Pollutant | Model | Expected field R² |
|---|---|---|
| PM2.5 | SIZEBINS per-sensor OLS (`pm25`,`pm1`,`pm10`,`rh`,`temp`) | ~0.66 |
| O3 | baseline per-sensor OLS on `o3/1000` | ~0.50 |
| CO, NO2, NO | **not calibrated** — CO needs a random forest and is cool-season only; NO2/NO channels are under review with the vendor |

Exclusions ported from `Quant/apply_calibration.R` and verified in output:
MOD-00549 uses the NETWORK_POOL curve for PM2.5 and gets **no** O3 (no pooled O3
curve exists); MOD-00559 is excluded entirely (faulty OPC).

**Provenance question, settled — do not re-litigate.** The curves were fit on
columns named `pm25_raw`/`pm1_raw`/`pm10_raw`. That "raw" means *before our
calibration*, NOT instrument raw counts. Verified by comparing the archive
against both API endpoints for MOD-00548 on 2025-11-15: archive `pm25_raw`
matches the vendor `pm25` field **exactly** (mean abs diff 0.0000), versus 3.34
for `opc.pm25` and 2.30 for `neph.pm25`. The values this pipeline already stores
are the correct inputs; there is no double-correction.

**Implementation validated.** Pipeline output was compared row-for-row against
`Quant/apply_calibration.R` on identical inputs: 1,106 PM2.5 hours and 1,207 O3
hours, **max difference 0.0000000000**, no rows where one produced a value and
the other did not. Re-run that check if the curves are ever revised.

Calibrated PM2.5 is floored at 0 (a linear model can go slightly negative near
zero); the uncalibrated column is always retained alongside.

## Known gaps

**The app does not read these artifacts yet.** That is the next step and the
point of the exercise. Wiring it up also fixes "Last 7 Days" for free.

## Gotchas

- **Do not** switch ingest to `get_data(sn, start=)`. A date filter triggers
  server-side pagination: ~90 s per sensor versus ~2.6 s for `get_data_by_date`.
- **No parallel workers.** Not needed (nothing waits on this job), and
  `multisession` is what broke the production dashboard on 2026-08-01 — the
  shinyapps.io instance has 1 core and kills extra R processes.
- DuckDB: `now()` is `TIMESTAMPTZ` and stored timestamps are `TIMESTAMP`; use
  `CAST(now() AS TIMESTAMP)`. `hours` is a reserved word — always alias with
  `AS`. `CURRENT_TIMESTAMP` is parsed as a column inside `DO UPDATE SET`; use
  `now()`.
- Timestamps are stored **UTC**. Local is `America/Phoenix` (UTC−7, no DST).
- MOD-00564 (Flowing Wells) is absent from the store: offline since
  2026-03-28, needs a site visit.

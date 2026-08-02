# SUNSET Network — Final Calibration Decisions

**Status:** FINAL (supersedes v9 deployed specs for PM2.5/O3; CO/NO2/NO revised)
**Date:** 2026-06-30
**Basis:** clean within-co-location chronological 70/30 hold-out (no spatial confound),
cross-checked against Mahdi's manuscript v5 and the QuantAQ raw-channel diagnostics below.

## Per-pollutant deployment models

| Pollutant | FINAL model | Held-out R² | Notes |
|---|---|---|---|
| **PM2.5** | **SIZEBINS OLS** (per-sensor): `pm25_epa ~ pm25_raw + pm1_raw + pm10_raw + RH + T` | ~0.66 | OPC-only, no gas dependency. Size bins carry the entire multichannel gain; gas channels add <0.01 → dropped. |
| **O3** | **Baseline OLS** (per-sensor): `o3_epa ~ o3_ppm` | ~0.50 | Parsimony confirmed: extra predictors add only +0.04 and overfit out-of-sample. |
| **CO** | **RF only, cool-season only** | ~0.0–0.48 | OLS catastrophic out-of-sample; RF the only non-broken option; calibration collapses >30.7°C (~5 mo/yr unusable). Report as indicative, flag summer. |
| **NO2** | **DROP** (RF marginal at best, +0.33) | <0 (OLS) | Raw channel broken from ~Apr 2025 (see below). Not a usable quantitative output. |
| **NO** | **DROP — non-quantitative** | n/a | No NCore reference (only 2025-H1 bulk); raw channel runaway (see below). |

## Why PM2.5 = SIZEBINS, not M3-with-gases
Complexity ladder (clean hold-out, network mean): M2 (sensor+met) 0.573 → +pm10 0.612 →
+pm1+pm10 (**SIZEBINS**) 0.658 → +CO 0.663 → +all gases (M3) 0.665.
Size bins add +0.085; all gas channels together add +0.007 (noise). Gases also cost ~9pp
coverage (gas board ~82% vs PM ~91%) and import noise from the broken NO2/CO channels.

## NO2 / NO raw-channel diagnostics (QuantAQ "fix" did NOT resolve)
Monthly RAW sensor-vs-EPA on MOD-00552 (permanent co-location):
- **NO2**: usable early 2024 (r 0.54–0.74), summer collapse, then BROKEN from ~Apr 2025 —
  sensor stuck ~12 ppb while EPA ~4 ppb (r −0.16 to −0.27, bias +8 to +10 ppb).
  Post-2025-09-04 "new model"/API period: **r = −0.14, bias +8.1, RMSE 13.2** — no recovery.
  Degradation began months before the Sep fix → hardware/aging trajectory, fleet-wide.
- **NO**: raw mean diverges from 16 ppb (Jan 2025) to 228 ppb (Jun 2025) vs EPA ~0.4 ppb
  (RMSE → 789); runaway electrochemical baseline. EPA NO reference ends 2025-06-30
  (all pre-fix) → post-fix NO unvalidatable.
**Action:** do not report NO/NO2 as measurements; flag to QuantAQ that the fix did not
restore NO2/NO agreement (evidence: scratchpad `no2_no_timeline.R`).

## Deliverables (canonical)
- `SUNSET_calibration_curves_for_Kylie.csv` — per-sensor PM2.5 (SIZEBINS) + O3 (M1) coefficients + pooled fallback.
- `apply_calibration.R` — `load_curves()` / `apply_calibration(df, curves)` → adds pm25_cal, o3_cal.
- MOD-00559 excluded (faulty OPC); MOD-00549 weak (R²=0.29) → network-pool fallback.

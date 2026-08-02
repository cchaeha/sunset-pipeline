# 30_config.R — shared configuration for the SUNSET ingest pipeline.
# Sourced by 30a/30b/30c and the orchestrator. No side effects beyond constants.
# Mirrors the AirSMART code/30* pattern deliberately: one pipeline shape for the
# lab, not two.

# ---- Paths ------------------------------------------------------------------
PIPE_DIR   <- normalizePath(file.path(dirname(sys.frame(1)$ofile %||% "."), "."),
                            mustWork = FALSE)
if (!dir.exists(PIPE_DIR)) PIPE_DIR <- "."
DB_PATH        <- file.path(PIPE_DIR, "data", "sunset.duckdb")
EXPORT_DIR     <- file.path(PIPE_DIR, "data", "export")
LOG_DIR        <- file.path(PIPE_DIR, "logs")
SITES_CSV      <- "/Users/chrislim/Documents/TASK/SUNSET/figures/sensor_sites_clean.csv"
CURVES_CSV     <- "/Users/chrislim/Documents/TASK/Quant/SUNSET_calibration_curves_for_Kylie.csv"

# ---- Sensors ----------------------------------------------------------------
# The 20 MODULAIR units of the Pima County DEQ x UA school network.
# MOD-00552 is the permanent Children's Park co-location reference.
SUNSET_SENSORS <- sprintf("MOD-%05d", 546:565)
REFERENCE_SN   <- "MOD-00552"
# Excluded from calibrated output (faulty OPC during co-location, see
# Quant/CALIBRATION_FINAL.md). Raw values are still stored.
EXCLUDE_CAL    <- c("MOD-00559")

# ---- Ingest window ----------------------------------------------------------
# get_data_by_date() returns a full sensor-day (~1438 records) in ~2.6 s and is
# idempotent, so re-pulling the last few days each run repairs any gap without
# a backfill job. Do NOT switch to get_data(sn, start=) — a date filter triggers
# server-side pagination and measured ~90 s per sensor.
INGEST_DAYS    <- 3
TZ_LOCAL       <- "America/Phoenix"
EXPECT_PER_DAY <- 1440L

# ---- QC ---------------------------------------------------------------------
# The MODULAIR optical particle counter stops returning counts above roughly
# 50 C enclosure temperature and resumes once it cools. Measured at Mission View
# 2026-07-29..31: 100% PM availability below 47 C, 36% at 49 C, 0% at 50.3 C.
# This is a documented thermal limit, NOT a sensor fault, and it must be labelled
# as such so a gap is never mistaken for a broken site.
# 47.5 not 50: the measured transition BEGINS around 47 C (90% availability at
# 47.3 C, 36% at 49.0 C, 0% at 50.3 C), and hours lost at 48.1-48.8 C are the
# same phenomenon. Safe to set low because pm_status also requires that the
# sensor recovered the same day (see 30b_qc.R) before calling it thermal.
OPC_THERMAL_C    <- 47.5
STALE_HOURS      <- 3      # no record within this window => "offline"
PM_PLAUSIBLE_MAX <- 1000   # ug/m3 guard

`%||%` <- function(a, b) if (is.null(a)) b else a

#!/usr/bin/env Rscript
# 30_run_pipeline.R — orchestrator for the SUNSET ingest pipeline.
#
# USAGE
#   export QUANTAQ_API_KEY=...
#   Rscript pipeline/30_run_pipeline.R            # normal incremental run
#   Rscript pipeline/30_run_pipeline.R --days 14  # wider repair window
#
# Run it on a schedule (every 15 min is plenty; the API is the only cost).
# Everything is idempotent, so a missed run repairs itself on the next one.

suppressMessages({
  library(DBI); library(duckdb); library(QuantAQAPIClient)
})

PIPE_DIR <- dirname(normalizePath(sub("^--file=", "",
              grep("^--file=", commandArgs(FALSE), value = TRUE)[1])))
source(file.path(PIPE_DIR, "30_config.R"))
source(file.path(PIPE_DIR, "30a_ingest.R"))
source(file.path(PIPE_DIR, "30a2_ingest_wind.R"))
source(file.path(PIPE_DIR, "30b_qc.R"))
source(file.path(PIPE_DIR, "30d_calibrate.R"))
source(file.path(PIPE_DIR, "30e_archive.R"))
source(file.path(PIPE_DIR, "30c_export.R"))
source(file.path(PIPE_DIR, "30c2_export_wind.R"))

args <- commandArgs(TRUE)
if ("--days" %in% args) INGEST_DAYS <- as.integer(args[which(args == "--days") + 1])

dir.create(dirname(DB_PATH), showWarnings = FALSE, recursive = TRUE)
dir.create(LOG_DIR,          showWarnings = FALSE, recursive = TRUE)

t0  <- Sys.time()
con <- dbConnect(duckdb(), dbdir = DB_PATH)
on.exit({ dbDisconnect(con, shutdown = TRUE) }, add = TRUE)

message("== SUNSET pipeline ==  ", format(t0, "%Y-%m-%d %H:%M:%S"))

# On a fresh runner the working store is empty; rebuild it from the committed
# Parquet archive so the CI cache is disposable rather than load-bearing.
if (!DBI::dbExistsTable(con, "sensor_data")) {
  message("-- empty store: restoring from archive")
  restore_from_archive(con)
}

message("-- ingest (", INGEST_DAYS, " days x ", length(SUNSET_SENSORS), " sensors)")
ing <- ingest_quantaq(con, days = INGEST_DAYS)
message(sprintf("   rows upserted: %s   failed sensor-days: %d", ing$rows, ing$failures))

# Fail loudly on a total ingest failure. A run that collects nothing but exits 0
# is the worst outcome available: CI goes green, the artifacts quietly go stale,
# and nobody looks. This happened on 2026-08-02 — every sensor-day failed on a
# missing jsonlite and the workflow still reported success.
attempted <- length(SUNSET_SENSORS) * INGEST_DAYS
if (ing$rows == 0 && ing$failures > 0)
  stop(sprintf("ingest collected NOTHING (%d/%d sensor-days failed) - see [FAIL] lines above",
               ing$failures, attempted))
if (ing$failures > attempted / 2)
  warning(sprintf("ingest degraded: %d/%d sensor-days failed", ing$failures, attempted))

message("-- ingest wind (", INGEST_DAYS, " days x ", length(SUNSET_SENSORS), " sensors)")
ing_wind <- ingest_wind(con, days = INGEST_DAYS)
message(sprintf("   wind rows upserted: %s   failed sensor-days: %d",
                ing_wind$rows, ing_wind$failures))

message("-- hourly + QC")
qc <- build_hourly(con)
print(qc)

message("-- calibrate (PM2.5 SIZEBINS, O3 baseline)")
cal <- apply_calibration(con)
message(sprintf("   hours=%d  pm25_cal=%d (%.1f%%)  o3_cal=%d (%.1f%%)",
                cal$n, cal$pm25, 100 * cal$pm25 / max(cal$n, 1),
                cal$o3, 100 * cal$o3 / max(cal$n, 1)))

message("-- archive (durable daily Parquet)")
arc <- write_archive(con)
message(sprintf("   written=%d  already present=%d", arc$written, arc$skipped))

message("-- export")
ex <- export_artifacts(con)
message(sprintf("   latest=%d  status=%d  hourly=%d", ex$latest, ex$status, ex$hourly))
message(sprintf("   store span: %s .. %s  (%s records, %s sensors)",
                ex$span$first_obs, ex$span$last_obs, ex$span$n_records, ex$span$n_sensors))

ex_wind <- export_wind_artifact(con)
message(sprintf("   wind=%d", ex_wind$wind))

el <- round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1)
message("== done in ", el, " min ==")

# Append a one-line run record so silent failures are visible in the log.
cat(sprintf("%s\trows=%s\tfailures=%d\thourly=%d\tmin=%.1f\n",
            format(t0, "%Y-%m-%dT%H:%M:%S"), ing$rows, ing$failures, ex$hourly, el),
    file = file.path(LOG_DIR, "runs.tsv"), append = TRUE)

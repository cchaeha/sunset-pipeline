# 30a2_ingest_wind.R — incremental wind ingest, separate from the main pull.
#
# WHY A SEPARATE STEP, NOT A COLUMN ADDED TO 30a's PULL.
# 30a_ingest.R calls get_data_by_date(..., raw = FALSE), which returns
# QuantAQ's processed fields (r$pm25, r$co, r$no2 ...) — the values every
# calibration and export downstream already assumes. Wind (met.ws, met.wd)
# only exists on the RAW endpoint, and raw=TRUE records are shaped completely
# differently: no top-level pm25/co/no2 at all, only opc.*/gases.*.we/ae/diff.
# Switching 30a itself to raw=TRUE would silently change what "pm25" means
# throughout the calibrated pipeline. Pulling wind as its own step with its
# own table costs one extra API call per sensor-day (measured: raw=TRUE 1.55s
# vs raw=FALSE 1.28s, negligible against the 20-sensor x 3-day budget) and
# touches nothing that already works.
#
# CIRCULAR VARIABLE WARNING, for whoever aggregates this later: wind
# direction cannot be averaged arithmetically. mean(350, 10) = 180, which is
# the compass-opposite of correct. This is exactly why wind is NOT folded
# into sensor_hourly (whose every other column IS a plain avg()) — it stays
# at native 1-minute resolution all the way to the export artifact, and
# direction binning happens once, at plot time, in the dashboard.
#
# Sourced by 30_run_pipeline.R; not run standalone.

ingest_wind <- function(con, days = INGEST_DAYS) {
  stopifnot(nzchar(Sys.getenv("QUANTAQ_API_KEY")))
  QuantAQAPIClient::setup_client(api_key = Sys.getenv("QUANTAQ_API_KEY"))

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sensor_wind (
      sn          VARCHAR,
      timestamp   TIMESTAMP,
      ws          DOUBLE,
      wd          DOUBLE,
      ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (sn, timestamp)
    )")

  records_to_df <- function(records, sensor) {
    if (!length(records)) return(NULL)
    num <- function(x) if (is.null(x)) NA_real_ else as.numeric(x)
    data.frame(
      sn        = vapply(records, function(r) r$sn %||% sensor, character(1)),
      # Raw records use flat dot-separated keys ("met.ws"), NOT a nested
      # r$met$ws — confirmed against a live pull 2026-08-12. The Black Mesa
      # unit (MOD-PM-00586) genuinely nests under r$met with no ws/wd fields
      # at all — an older device/firmware, not an accessor difference — so
      # this schema is SUNSET-fleet-specific and should not be assumed
      # elsewhere without re-checking.
      timestamp = as.POSIXct(vapply(records, function(r) r$timestamp, character(1)),
                             format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
      ws        = vapply(records, function(r) num(r[["met.ws"]]), numeric(1)),
      wd        = vapply(records, function(r) num(r[["met.wd"]]), numeric(1)),
      stringsAsFactors = FALSE
    )
  }

  last_err <- NULL
  pull_day <- function(sensor, date, retries = 3) {
    for (a in seq_len(retries)) {
      res <- tryCatch(
        QuantAQAPIClient::get_data_by_date(sn = sensor, date = as.character(date), raw = TRUE),
        error = function(e) { last_err <<- conditionMessage(e); Sys.sleep(2 * a); NULL })
      if (!is.null(res)) return(res)
    }
    NULL
  }

  dates <- seq(Sys.Date() - (days - 1), Sys.Date(), by = "day")
  n_rows <- 0L; n_fail <- 0L
  for (sn in SUNSET_SENSORS) {
    for (d in as.character(dates)) {
      recs <- pull_day(sn, d)
      if (is.null(recs)) {
        n_fail <- n_fail + 1L
        message(sprintf("  [WIND FAIL] %s %s%s", sn, d,
                        if (!is.null(last_err)) paste0("  <- ", last_err) else ""))
        next
      }
      df <- records_to_df(recs, sn)
      if (is.null(df) || !nrow(df)) next
      df <- df[!is.na(df$timestamp), ]
      # Plausibility guard. WS_PLAUSIBLE_MAX comes from 30_config.R; anything
      # above it is an instrument fault, not weather. wd is left alone here —
      # out-of-range values are rare and easier to spot in the export than
      # silently dropped at ingest.
      df$ws[!is.na(df$ws) & (df$ws < 0 | df$ws > WS_PLAUSIBLE_MAX)] <- NA_real_
      df$wd[!is.na(df$wd) & (df$wd < 0 | df$wd > 360)] <- NA_real_

      DBI::dbWriteTable(con, "stage_wind", df, overwrite = TRUE, temporary = TRUE)
      DBI::dbExecute(con, "
        INSERT INTO sensor_wind (sn, timestamp, ws, wd)
        SELECT sn, timestamp, ws, wd FROM stage_wind
        ON CONFLICT (sn, timestamp) DO UPDATE SET
          ws = excluded.ws, wd = excluded.wd, ingested_at = now()")
      n_rows <- n_rows + nrow(df)
    }
  }
  list(rows = n_rows, failures = n_fail)
}

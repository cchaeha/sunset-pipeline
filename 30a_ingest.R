# 30a_ingest.R — incremental QuantAQ ingest into the SUNSET DuckDB store.
#
# Re-pulls the last INGEST_DAYS days for each of the 20 sensors via the per-day
# endpoint and UPSERTs on (sn, timestamp), so the run is idempotent: running it
# twice changes nothing, and a run after an outage repairs the gap by itself.
#
# ~20 sensors x 3 days x 2.6 s = ~2.5 min per run, sequential. Deliberately no
# parallel workers: this is a background job, nothing is waiting on it, and
# multisession parallelism is what broke the production dashboard on 2026-08-01.
#
# Sourced by 30_run_pipeline.R; not run standalone.

ingest_quantaq <- function(con, days = INGEST_DAYS) {
  stopifnot(nzchar(Sys.getenv("QUANTAQ_API_KEY")))
  QuantAQAPIClient::setup_client(api_key = Sys.getenv("QUANTAQ_API_KEY"))

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sensor_data (
      sn         VARCHAR,
      timestamp  TIMESTAMP,
      geo_lat    DOUBLE,
      geo_lon    DOUBLE,
      pm1        DOUBLE,
      pm25       DOUBLE,
      pm10       DOUBLE,
      co         DOUBLE,
      no         DOUBLE,
      no2        DOUBLE,
      o3         DOUBLE,
      rh         DOUBLE,
      temp       DOUBLE,
      ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (sn, timestamp)
    )")

  records_to_df <- function(records, sensor) {
    if (!length(records)) return(NULL)
    num <- function(x) if (is.null(x)) NA_real_ else as.numeric(x)
    data.frame(
      sn        = vapply(records, function(r) r$sn %||% sensor, character(1)),
      timestamp = as.POSIXct(vapply(records, function(r) r$timestamp, character(1)),
                             format = "%Y-%m-%dT%H:%M:%S", tz = "UTC"),
      geo_lat   = vapply(records, function(r) num(r$geo$lat),  numeric(1)),
      geo_lon   = vapply(records, function(r) num(r$geo$lon),  numeric(1)),
      pm1       = vapply(records, function(r) num(r$pm1),      numeric(1)),
      pm25      = vapply(records, function(r) num(r$pm25),     numeric(1)),
      pm10      = vapply(records, function(r) num(r$pm10),     numeric(1)),
      co        = vapply(records, function(r) num(r$co),       numeric(1)),
      no        = vapply(records, function(r) num(r$no),       numeric(1)),
      no2       = vapply(records, function(r) num(r$no2),      numeric(1)),
      o3        = vapply(records, function(r) num(r$o3),       numeric(1)),
      rh        = vapply(records, function(r) num(r$met$rh),   numeric(1)),
      temp      = vapply(records, function(r) num(r$met$temp), numeric(1)),
      stringsAsFactors = FALSE
    )
  }

  # Report the LAST error rather than swallowing it. The first CI run failed all
  # 60 sensor-days and produced no clue why, because this returned a bare NULL.
  # A retry loop that hides the reason is worse than no retry loop.
  last_err <- NULL
  pull_day <- function(sensor, date, retries = 3) {
    for (a in seq_len(retries)) {
      res <- tryCatch(
        QuantAQAPIClient::get_data_by_date(sn = sensor, date = as.character(date)),
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
        message(sprintf("  [FAIL] %s %s%s", sn, d,
                        if (!is.null(last_err)) paste0("  <- ", last_err) else ""))
        next
      }
      df <- records_to_df(recs, sn)
      if (is.null(df) || !nrow(df)) next
      df <- df[!is.na(df$timestamp), ]
      # Plausibility guard; keep the row, drop only the impossible value.
      for (v in c("pm1", "pm25", "pm10"))
        df[[v]][!is.na(df[[v]]) & (df[[v]] < 0 | df[[v]] > PM_PLAUSIBLE_MAX)] <- NA_real_

      DBI::dbWriteTable(con, "stage_sd", df, overwrite = TRUE, temporary = TRUE)
      # UPSERT: later pulls of the same minute replace earlier ones, which is
      # what makes re-running safe.
      DBI::dbExecute(con, "
        INSERT INTO sensor_data
          (sn,timestamp,geo_lat,geo_lon,pm1,pm25,pm10,co,no,no2,o3,rh,temp)
        SELECT sn,timestamp,geo_lat,geo_lon,pm1,pm25,pm10,co,no,no2,o3,rh,temp
        FROM stage_sd
        ON CONFLICT (sn, timestamp) DO UPDATE SET
          pm1=excluded.pm1, pm25=excluded.pm25, pm10=excluded.pm10,
          co=excluded.co, no=excluded.no, no2=excluded.no2, o3=excluded.o3,
          rh=excluded.rh, temp=excluded.temp, ingested_at=now()")
      n_rows <- n_rows + nrow(df)
    }
    message(sprintf("  %s done", sn))
  }
  list(rows = n_rows, failures = n_fail)
}

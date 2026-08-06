# 30c_export.R — write small, dashboard-ready artifacts.
#
# The whole point of the pipeline: the front end should read these files and do
# no fetching or computation at request time. Today the Shiny app makes 21 live
# API calls per page load (~120 s in production) and can only ever hold ~17 h of
# history, which is why its "Last 7 Days" option has never had the data it
# advertises. These artifacts fix both.
#
# Sourced by 30_run_pipeline.R; not run standalone.

export_artifacts <- function(con) {
  dir.create(EXPORT_DIR, showWarnings = FALSE, recursive = TRUE)

  # 1. latest.csv — one row per sensor, what the map needs. Tiny.
  # latest.csv carries the CALIBRATED value the dashboard should display,
  # alongside the uncalibrated one so nothing is hidden.
  latest <- DBI::dbGetQuery(con, "
    WITH ranked AS (
      SELECT *, row_number() OVER (PARTITION BY sn ORDER BY timestamp DESC) AS rn
      FROM sensor_data
      WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 12 HOUR
    )
    SELECT sn, strftime(timestamp, '%Y-%m-%d %H:%M:%S') AS timestamp,
           geo_lat, geo_lon, pm1, pm25, pm10, o3, co, no2, rh, temp
    FROM ranked WHERE rn = 1 ORDER BY sn")
  write.csv(latest, file.path(EXPORT_DIR, "latest.csv"), row.names = FALSE)

  # 2. status.csv — per-sensor state with an explicit reason for missing PM.
  status <- build_status(con)
  write.csv(status, file.path(EXPORT_DIR, "status.csv"), row.names = FALSE)

  # 3. hourly_30d.csv — the real history the app has never had.
  hourly <- DBI::dbGetQuery(con, "
    SELECT sn, strftime(hour_utc, '%Y-%m-%d %H:%M:%S') AS hour_utc,
           pm25, pm25_cal, pm10, pm1, o3, o3_cal, co, no2, rh, temp,
           n_obs, pm_status, hour_complete
    FROM sensor_hourly
    WHERE hour_utc >= CAST(now() AS TIMESTAMP) - INTERVAL 30 DAY
    ORDER BY sn, hour_utc")
  write.csv(hourly, file.path(EXPORT_DIR, "hourly_30d.csv"), row.names = FALSE)

  # TIMESTAMPS ARE FORMATTED IN SQL, NOT LEFT TO write.csv. R's write.csv omits
  # the time component when a POSIXct falls on exact midnight, and a SINGLE such
  # row is enough to make as.POSIXct() infer a date-only format and silently
  # truncate EVERY timestamp in the file to 00:00:00. Observed 2026-08-03: 1 row
  # in 126,610 destroyed all time-of-day information in the published feed.
  # strftime() guarantees a full timestamp on every row.

  # 4. app_feed.csv.gz — 1-minute records in EXACTLY the schema the Shiny app's
  #    fetch_sensor_data() returns, so the app can swap its data source without
  #    any change to downstream reactives. Includes the calibrated columns.
  #    Retention is capped so the artifact cannot grow without bound; 8 days
  #    covers the UI's longest window (7 days) with a margin.
  # PARQUET is the primary format. It is smaller (2.1 vs 2.5 MB), reads in
  # 0.01 s vs 0.26 s, and — the real reason — stores the timestamp TYPE rather
  # than a string, so the midnight-truncation bug that silently flattened
  # 126,610 timestamps on 2026-08-03 cannot occur at all. Removing a failure
  # mode beats guarding against it.
  DBI::dbExecute(con, sprintf("
    COPY (SELECT sn, timestamp, geo_lat, geo_lon, co, no, no2, o3,
                 pm1, pm10, pm25, rh, temp
          FROM sensor_data
          WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 8 DAY
          ORDER BY sn, timestamp)
    TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    file.path(EXPORT_DIR, "app_feed.parquet")))

  # csv.gz retained one release cycle so a client pinned to the old artifact
  # does not break mid-transition. Drop once the app reads parquet in prod.
  feed <- DBI::dbGetQuery(con, "
    SELECT sn, strftime(timestamp, '%Y-%m-%d %H:%M:%S') AS timestamp,
           geo_lat, geo_lon, co, no, no2, o3, pm1, pm10, pm25, rh, temp
    FROM sensor_data
    WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 8 DAY
    ORDER BY sn, timestamp")
  gz <- gzfile(file.path(EXPORT_DIR, "app_feed.csv.gz"), "wt")
  utils::write.csv(feed, gz, row.names = FALSE)
  close(gz)

  # 5. manifest.json — provenance, so a stale artifact is detectable rather
  #    than silently served.
  span <- DBI::dbGetQuery(con, "
    SELECT min(timestamp) AS first_obs, max(timestamp) AS last_obs,
           count(*) AS n_records, count(DISTINCT sn) AS n_sensors
    FROM sensor_data")
  manifest <- sprintf(
    '{\n  "generated_utc": "%s",\n  "n_records": %s,\n  "n_sensors": %s,\n  "first_obs": "%s",\n  "last_obs": "%s",\n  "calibration": "APPLIED: PM2.5 SIZEBINS + O3 baseline (v2026-06-30)",\n  "feed_rows": %s,\n  "artifacts": ["latest.csv","status.csv","hourly_30d.csv","app_feed.parquet","app_feed.csv.gz"]\n}\n',
    format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ"),
    span$n_records, span$n_sensors, span$first_obs, span$last_obs, nrow(feed))
  writeLines(manifest, file.path(EXPORT_DIR, "manifest.json"))

  list(latest = nrow(latest), status = nrow(status), hourly = nrow(hourly),
       feed = nrow(feed), span = span)
}

# 30c2_export_wind.R — wind artifact for the dashboard's wind-rose tab.
#
# Deliberately a separate file from 30c_export.R rather than an added column
# in one of its queries: every existing artifact (latest.csv, status.csv,
# hourly_30d.csv, app_feed.parquet) stays byte-for-byte what it already was.
#
# Exports at native 1-minute resolution, not hourly means — wind direction is
# circular (see 30a2's header) and there is no correct way to average it down
# to an hourly value without vector/circular averaging, which the dashboard's
# rose does not need: it bins each point into its own direction sector.
# 30 days mirrors hourly_30d.csv's retention so the two tabs can show the same
# window if asked to.
#
# Sourced by 30_run_pipeline.R; not run standalone.

export_wind_artifact <- function(con) {
  dir.create(EXPORT_DIR, showWarnings = FALSE, recursive = TRUE)

  n <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM sensor_wind
    WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 30 DAY
      AND ws IS NOT NULL AND wd IS NOT NULL")$n

  DBI::dbExecute(con, sprintf("
    COPY (SELECT sn, timestamp, ws, wd
          FROM sensor_wind
          WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 30 DAY
            AND ws IS NOT NULL AND wd IS NOT NULL
          ORDER BY sn, timestamp)
    TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    file.path(EXPORT_DIR, "wind_30d.parquet")))

  list(wind = n)
}

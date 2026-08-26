# 30c2_export_wind.R — wind artifact for the dashboard's wind-rose tab.
#
# Deliberately a separate file from 30c_export.R rather than an added column
# in one of its queries: every existing artifact (latest.csv, status.csv,
# hourly_30d.csv, app_feed.parquet) stays byte-for-byte what it already was.
#
# TWO ARTIFACTS, FOR TWO READERS.
#
# wind_30d.parquet is native 1-minute resolution, because the dashboard's rose
# bins each point into its own direction sector and wants every point.
#
# wind_hourly_30d.csv is for the watchdog, which cannot read Parquet: that repo
# is stdlib-only on purpose, since the daily digest exists to make silence
# unambiguous and an install step that can fail is precisely the dependency it
# must not carry. So the hourly reduction happens here.
#
# It happens here for a second reason, which matters more. Direction is
# circular — 30a2's header spells out that mean(350, 10) = 180 is the compass
# opposite of the answer — and the only safe way to hand an hourly value to a
# consumer is to hand it the mean EAST and NORTH components and let it finish
# the vector average, never a pre-averaged bearing it might average again.
# u and v are signed so that they point the way the air is going; the consumer
# negates them to recover the direction the wind comes FROM.
#
# ws_mean is the SCALAR mean and is deliberately not sqrt(u^2 + v^2). The
# resultant vector's length is the mean speed times how steadily the wind held
# its bearing, so the two differ whenever the wind turned — and their ratio is
# the only number that says whether a mean bearing is worth reading at all.
# Both are needed; neither can be recovered from the other.
#
# 30 days mirrors hourly_30d.csv's retention so the two can show the same
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

  # wd is taken modulo 360 because the feed carries both 0 and 360 for due
  # north; without it the two are one bin apart in anything that rounds.
  DBI::dbExecute(con, sprintf("
    COPY (
      WITH w AS (
        SELECT sn,
               date_trunc('hour', timestamp) AS hour_utc,
               ws,
               (wd %% 360) AS wd
        FROM sensor_wind
        WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 30 DAY
          AND ws IS NOT NULL AND wd IS NOT NULL
      )
      SELECT sn,
             strftime(hour_utc, '%%Y-%%m-%%d %%H:%%M:%%S') AS hour_utc,
             count(*)                        AS n_obs,
             avg(ws)                         AS ws_mean,
             avg(-ws * sin(radians(wd)))     AS u_mean,
             avg(-ws * cos(radians(wd)))     AS v_mean
      FROM w
      GROUP BY sn, hour_utc
      ORDER BY sn, hour_utc
    ) TO '%s' (FORMAT CSV, HEADER)",
    file.path(EXPORT_DIR, "wind_hourly_30d.csv")))

  hourly <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM (
      SELECT sn, date_trunc('hour', timestamp)
      FROM sensor_wind
      WHERE timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 30 DAY
        AND ws IS NOT NULL AND wd IS NOT NULL
      GROUP BY 1, 2)")$n

  list(wind = n, wind_hours = hourly)
}

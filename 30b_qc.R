# 30b_qc.R — hourly aggregation + QC labelling.
#
# Produces sensor_hourly from sensor_data. The point of this stage is that a
# missing value is never silently missing: every hour carries a reason.
#
# pm_status for each sensor-hour:
#   "ok"              PM reported
#   "thermal_cutoff"  no PM and enclosure >= OPC_THERMAL_C. The MODULAIR optical
#                     particle counter has a thermal limit near 50 C; it stops
#                     returning counts and resumes on its own once cooler. This
#                     is the cause of the white dots partners reported
#                     2026-07-30 and is NOT a fault.
#   "no_pm"           no PM but the enclosure was cool — genuinely unexplained,
#                     worth a look.
#   "offline"         no records at all for that hour.
#
# Sourced by 30_run_pipeline.R; not run standalone.

build_hourly <- function(con) {
  DBI::dbExecute(con, "DROP TABLE IF EXISTS sensor_hourly")
  DBI::dbExecute(con, sprintf("
    CREATE TABLE sensor_hourly AS
    WITH base AS (
      SELECT
        sn,
        date_trunc('hour', timestamp) AS hour_utc,
        count(*)                       AS n_obs,
        count(pm25)                    AS n_pm25,
        avg(pm25) FILTER (WHERE pm25 IS NOT NULL) AS pm25,
        avg(pm10) FILTER (WHERE pm10 IS NOT NULL) AS pm10,
        avg(pm1)  FILTER (WHERE pm1  IS NOT NULL) AS pm1,
        avg(o3)   FILTER (WHERE o3   IS NOT NULL) AS o3,
        avg(co)   FILTER (WHERE co   IS NOT NULL) AS co,
        avg(no2)  FILTER (WHERE no2  IS NOT NULL) AS no2,
        avg(rh)   FILTER (WHERE rh   IS NOT NULL) AS rh,
        avg(temp) FILTER (WHERE temp IS NOT NULL) AS temp,
        max(temp)                      AS temp_max,
        any_value(geo_lat)             AS geo_lat,
        any_value(geo_lon)             AS geo_lon
      FROM sensor_data
      GROUP BY 1, 2
    ),
    day_ctx AS (
      -- Did this sensor produce ANY PM on this calendar day? Temperature alone
      -- cannot separate a unit that will recover on its own from one that needs
      -- a service call: Lauffer and Marana sat at a MEAN of 38 C with no PM for
      -- 60+ hours (genuinely down), while Mission View, Ajo, Valdez and
      -- Roadrunner lost single hours at 48 C and came back (thermal). The
      -- distinguishing signal is recovery within the same day, not the reading.
      SELECT sn, CAST(hour_utc AS DATE) AS d, sum(n_pm25) AS day_pm
      FROM base GROUP BY 1, 2
    )
    SELECT
      b.*,
      CASE
        WHEN b.n_pm25 > 0                          THEN 'ok'
        WHEN c.day_pm = 0 OR c.day_pm IS NULL      THEN 'opc_down'
        WHEN b.temp_max >= %f                      THEN 'thermal_cutoff'
        ELSE 'no_pm'
      END AS pm_status,
      -- 75%% completeness gate, same rule the calibration work used
      (b.n_obs >= 45) AS hour_complete
    FROM base b
    LEFT JOIN day_ctx c
      ON b.sn = c.sn AND CAST(b.hour_utc AS DATE) = c.d", OPC_THERMAL_C))

  DBI::dbGetQuery(con, "
    SELECT pm_status, count(*) AS hours
    FROM sensor_hourly GROUP BY 1 ORDER BY 2 DESC")
}

# Current status per sensor, for the dashboard's map and status tab.
build_status <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    WITH latest AS (
      SELECT sn, max(timestamp) AS last_seen FROM sensor_data GROUP BY 1
    ),
    recent AS (
      SELECT d.sn,
             max(d.timestamp) FILTER (WHERE d.pm25 IS NOT NULL) AS last_pm25,
             max(d.temp)      AS temp_recent
      FROM sensor_data d
      WHERE d.timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 6 HOUR
      GROUP BY 1
    ),
    day AS (
      -- Same recovery test as build_hourly: a unit that produced PM at some
      -- point in the last 24 h is thermally cycling and will come back; one
      -- that has produced none needs a service call. Keep these two rules in
      -- step, or status.csv and sensor_hourly will disagree about the same
      -- sensor.
      SELECT d.sn, count(d.pm25) AS pm_24h
      FROM sensor_data d
      WHERE d.timestamp >= CAST(now() AS TIMESTAMP) - INTERVAL 24 HOUR
      GROUP BY 1
    )
    SELECT l.sn, l.last_seen, r.last_pm25, r.temp_recent, y.pm_24h,
      CASE
        WHEN l.last_seen < CAST(now() AS TIMESTAMP) - INTERVAL %d HOUR THEN 'offline'
        WHEN r.last_pm25 IS NOT NULL THEN 'ok'
        WHEN COALESCE(y.pm_24h, 0) = 0 THEN 'opc_down'
        WHEN r.temp_recent >= %f THEN 'thermal_cutoff'
        ELSE 'no_pm'
      END AS status
    FROM latest l
    LEFT JOIN recent r USING (sn)
    LEFT JOIN day    y USING (sn)
    ORDER BY l.sn", STALE_HOURS, OPC_THERMAL_C))
}

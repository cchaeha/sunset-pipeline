# 30d_calibrate.R — apply the validated SUNSET calibration to hourly values.
#
# PROVENANCE (verified 2026-08-01, do not re-litigate):
# The curves in SUNSET_calibration_curves_for_Kylie.csv were fit on columns
# named pm25_raw / pm1_raw / pm10_raw. "raw" there means "before OUR
# calibration", NOT the instrument's raw OPC counts. Checked by comparing the
# archive (calibrated_data_v9.csv.gz) against both API endpoints for
# MOD-00548 on 2025-11-15: archive pm25_raw matches the vendor `pm25` field
# EXACTLY (mean abs diff 0.0000), versus 3.34 for opc.pm25 and 2.30 for
# neph.pm25. So the correct inputs are the vendor-processed values this
# pipeline already stores, and applying the curves to them does NOT
# double-correct.
#
# Models (Quant/CALIBRATION_FINAL.md, hold-out validated):
#   PM2.5  SIZEBINS per-sensor OLS, expected field R2 ~0.66
#          pm25_cal = b0 + b1*pm25 + b2*pm1 + b3*pm10 + b4*rh + b5*temp
#   O3     baseline per-sensor OLS, expected field R2 ~0.50
#          o3_cal   = b0 + b1*(o3/1000)      [sensor o3 is ppb; curve wants ppm]
#   CO/NO2/NO  NOT calibrated. CO needs a random forest and is cool-season only;
#          NO2/NO raw channels are unreliable and under review with the vendor.
#
# Fallback rules ported from Quant/apply_calibration.R:
#   MOD-00549  weak fit  -> NETWORK_POOL curve for PM2.5; NO O3 curve at all
#   MOD-00559  faulty OPC -> excluded entirely, both pollutants NA
#
# Sourced by 30_run_pipeline.R; not run standalone.

load_curves <- function(path = CURVES_CSV) {
  cv <- read.csv(path, stringsAsFactors = FALSE)
  stopifnot(all(c("sensor_id", "pollutant", "b_intercept") %in% names(cv)))
  cv
}

apply_calibration <- function(con, curves = load_curves()) {
  h <- DBI::dbGetQuery(con, "
    SELECT sn, hour_utc, pm25, pm1, pm10, o3, rh, temp FROM sensor_hourly")
  if (!nrow(h)) return(list(n = 0L, pm25 = 0L, o3 = 0L))

  pm <- curves[curves$pollutant == "PM2.5", ]
  o3 <- curves[curves$pollutant == "O3", ]
  pm_per  <- pm[pm$sensor_id != "NETWORK_POOL", ]
  pm_pool <- pm[pm$sensor_id == "NETWORK_POOL", ][1, ]

  # ---- PM2.5 ----------------------------------------------------------------
  use_pool <- !(h$sn %in% pm_per$sensor_id) | h$sn == "MOD-00549"
  idx <- match(h$sn, pm_per$sensor_id)
  b <- function(col) ifelse(use_pool, pm_pool[[col]], pm_per[[col]][idx])

  h$pm25_cal <- b("b_intercept") +
                b("b_pm25_raw") * h$pm25 +
                b("b_pm1_raw")  * h$pm1  +
                b("b_pm10_raw") * h$pm10 +
                b("b_met_rh")   * h$rh   +
                b("b_met_temp") * h$temp
  h$pm25_cal[h$sn %in% EXCLUDE_CAL] <- NA_real_

  # ---- O3 -------------------------------------------------------------------
  # No pooled fallback exists for O3, so a sensor without its own curve gets NA.
  oi <- match(h$sn, o3$sensor_id)
  h$o3_cal <- o3$b_intercept[oi] + o3$b_o3_ppm[oi] * (h$o3 / 1000)
  h$o3_cal[h$sn %in% c(EXCLUDE_CAL, "MOD-00549")] <- NA_real_

  # Calibrated PM2.5 can go slightly negative at very low concentrations, which
  # is expected for a linear model near zero. Floor at 0 for display; the
  # uncalibrated column is retained so nothing is lost.
  h$pm25_cal[!is.na(h$pm25_cal) & h$pm25_cal < 0] <- 0

  DBI::dbWriteTable(con, "stage_cal", h[, c("sn","hour_utc","pm25_cal","o3_cal")],
                    overwrite = TRUE, temporary = TRUE)
  DBI::dbExecute(con, "ALTER TABLE sensor_hourly ADD COLUMN IF NOT EXISTS pm25_cal DOUBLE")
  DBI::dbExecute(con, "ALTER TABLE sensor_hourly ADD COLUMN IF NOT EXISTS o3_cal DOUBLE")
  DBI::dbExecute(con, "
    UPDATE sensor_hourly AS t
    SET pm25_cal = s.pm25_cal, o3_cal = s.o3_cal
    FROM stage_cal AS s
    WHERE t.sn = s.sn AND t.hour_utc = s.hour_utc")

  list(n    = nrow(h),
       pm25 = sum(!is.na(h$pm25_cal)),
       o3   = sum(!is.na(h$o3_cal)))
}

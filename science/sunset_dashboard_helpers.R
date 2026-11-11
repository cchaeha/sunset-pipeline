# Pure calculations shared by the SUNSET map, status table, and replay view.
# Times are instants in UTC; formatting for visitors happens in the app.

sunset_aqi_spec <- function(pollutant) {
  # EPA AQI breakpoints in effect after the 2024 PM2.5 revision. Each row is
  # concentration low/high followed by AQI low/high. Units are those below.
  specs <- list(
    pm25 = list(hours = 24, unit = "ug/m3", digits = 1, bp = matrix(c(
      0, 9.0, 0, 50, 9.1, 35.4, 51, 100, 35.5, 55.4, 101, 150,
      55.5, 125.4, 151, 200, 125.5, 225.4, 201, 300,
      225.5, 325.4, 301, 500), ncol = 4, byrow = TRUE)),
    pm10 = list(hours = 24, unit = "ug/m3", digits = 0, bp = matrix(c(
      0, 54, 0, 50, 55, 154, 51, 100, 155, 254, 101, 150,
      255, 354, 151, 200, 355, 424, 201, 300, 425, 604, 301, 500
    ), ncol = 4, byrow = TRUE)),
    o3 = list(hours = 8, unit = "ppm", digits = 3, bp = matrix(c(
      0, .054, 0, 50, .055, .070, 51, 100, .071, .085, 101, 150,
      .086, .105, 151, 200, .106, .200, 201, 300
    ), ncol = 4, byrow = TRUE)),
    o3_1h = list(hours = 1, unit = "ppm", digits = 3, bp = matrix(c(
      .125, .164, 101, 150, .165, .204, 151, 200,
      .205, .404, 201, 300, .405, .604, 301, 500
    ), ncol = 4, byrow = TRUE)),
    no2 = list(hours = 1, unit = "ppb", digits = 0, bp = matrix(c(
      0, 53, 0, 50, 54, 100, 51, 100, 101, 360, 101, 150,
      361, 649, 151, 200, 650, 1249, 201, 300,
      1250, 2049, 301, 500), ncol = 4, byrow = TRUE)),
    co = list(hours = 8, unit = "ppm", digits = 1, bp = matrix(c(
      0, 4.4, 0, 50, 4.5, 9.4, 51, 100, 9.5, 12.4, 101, 150,
      12.5, 15.4, 151, 200, 15.5, 30.4, 201, 300,
      30.5, 50.4, 301, 500), ncol = 4, byrow = TRUE))
  )
  specs[[pollutant]]
}

sunset_aqi_value <- function(value, pollutant) {
  spec <- sunset_aqi_spec(pollutant)
  if (is.null(spec) || length(value) != 1 || !is.finite(value) || value < 0)
    return(NA_integer_)
  # The feed stores gases in ppb; EPA's O3 and CO tables use ppm.
  if (pollutant %in% c("o3", "o3_1h", "co")) value <- value / 1000
  factor <- 10 ^ spec$digits
  value <- floor(value * factor + 1e-9) / factor
  bp <- spec$bp
  row <- which(value >= bp[, 1] & value <= bp[, 2])
  if (!length(row)) {
    if (value > max(bp[, 2])) {
      # The 8-hour O3 scale ends at 300; use the 1-hour estimate above it.
      if (pollutant == "o3") return(NA_integer_)
      b <- bp[nrow(bp), ]
      return(as.integer(floor((b[4] - b[3]) * (value - b[1]) /
                                (b[2] - b[1]) + b[3] + .5)))
    }
    return(NA_integer_)
  }
  b <- bp[row[1], ]
  as.integer(floor((b[4] - b[3]) * (value - b[1]) / (b[2] - b[1]) + b[3] + .5))
}

sunset_aqi_category <- function(value) {
  if (length(value) != 1 || is.na(value)) return("Insufficient data")
  c("Good", "Moderate", "Unhealthy for Sensitive Groups", "Unhealthy",
    "Very Unhealthy", "Hazardous")[
      findInterval(value, c(0, 51, 101, 151, 201, 301))]
}

sunset_aqi_snapshot <- function(data, pollutant, now = Sys.time(),
                                min_coverage = .75, max_age_minutes = 90) {
  spec <- sunset_aqi_spec(pollutant)
  column <- if (pollutant == "o3_1h") "o3" else pollutant
  if (is.null(spec) || !nrow(data) || !column %in% names(data))
    return(data.frame(sn = character(), aqi = integer(),
                      coverage = numeric(), age_min = numeric()))
  start <- now - spec$hours * 3600
  d <- data[!is.na(data$timestamp) & data$timestamp > start &
              data$timestamp <= now, c("sn", "timestamp", column)]
  if (!nrow(d)) return(data.frame(sn = character(), aqi = integer(),
                                   coverage = numeric(), age_min = numeric()))
  names(d)[3] <- "value"
  d <- d[is.finite(d$value) & d$value >= 0, ]
  if (!nrow(d)) return(data.frame(sn = character(), aqi = integer(),
                                   coverage = numeric(), age_min = numeric()))
  groups <- split(d, d$sn)
  out <- do.call(rbind, lapply(groups, function(x) {
    minute <- floor(as.numeric(x$timestamp) / 60)
    coverage <- length(unique(minute)) / (spec$hours * 60)
    age <- as.numeric(difftime(now, max(x$timestamp), units = "mins"))
    value <- if (coverage >= min_coverage && age >= -5 &&
                 age <= max_age_minutes) sunset_aqi_value(mean(x$value), pollutant)
             else NA_integer_
    data.frame(sn = x$sn[1], aqi = value,
               coverage = min(1, coverage), age_min = age)
  }))
  if (pollutant == "o3") {
    hourly <- sunset_aqi_snapshot(data, "o3_1h", now, min_coverage, max_age_minutes)
    out <- merge(out, hourly[, c("sn", "aqi")], by = "sn", all = TRUE,
                 suffixes = c("", "_1h"), sort = FALSE)
    out$aqi <- ifelse(is.na(out$aqi), out$aqi_1h,
                     ifelse(is.na(out$aqi_1h), out$aqi, pmax(out$aqi, out$aqi_1h)))
    out$aqi_1h <- NULL
  }
  out
}

sunset_relative_domain <- function(current, reference, minimum_width = .1) {
  values <- c(current, reference)
  values <- values[is.finite(values)]
  if (!length(values)) return(c(0, 1))
  span <- range(values)
  if (diff(span) < minimum_width) span <- mean(span) + c(-1, 1) * minimum_width / 2
  if (span[1] < 0 && all(values >= 0)) span[1] <- 0
  if (diff(span) < minimum_width) span[2] <- span[1] + minimum_width
  span
}

sunset_status_label <- function(status) {
  labels <- c(ok = "Reporting", thermal_cutoff = "PM paused by heat",
              opc_down = "PM sensor needs review", no_pm = "PM missing",
              offline = "Offline")
  out <- labels[status]
  out[is.na(out)] <- "Status unavailable"
  unname(out)
}

sunset_site_status <- function(data, roster, status_feed = NULL,
                               now = Sys.time()) {
  roster <- unique(as.character(roster))
  out <- data.frame(sn = roster, records_24h = 0L,
                    transmission_rate = 0, last_seen = as.POSIXct(NA, tz = "UTC"),
                    last_pm25 = as.POSIXct(NA, tz = "UTC"),
                    temp_recent = NA_real_, latest_pm25 = NA_real_,
                    quality = "Status unavailable")
  if (nrow(data)) {
    recent <- data[!is.na(data$timestamp) & data$timestamp > now - 86400 &
                     data$timestamp <= now, ]
    for (i in seq_along(roster)) {
      x <- recent[recent$sn == roster[i], ]
      if (nrow(x)) {
        out$records_24h[i] <- length(unique(floor(as.numeric(x$timestamp) / 60)))
        out$last_seen[i] <- max(x$timestamp)
        pm <- x$timestamp[is.finite(x$pm25)]
        if (length(pm)) out$last_pm25[i] <- max(pm)
        j <- which.max(x$timestamp)
        out$temp_recent[i] <- x$temp[j]
        out$latest_pm25[i] <- x$pm25[j]
      }
    }
  }
  out$transmission_rate <- pmin(100, round(100 * out$records_24h / 1440, 1))
  data_age_h <- as.numeric(difftime(now, out$last_seen, units = "hours"))
  if (!is.null(status_feed) && nrow(status_feed)) {
    match_idx <- match(out$sn, status_feed$sn)
    valid <- !is.na(match_idx)
    out$quality[valid] <- sunset_status_label(status_feed$status[match_idx[valid]])
    for (nm in intersect(c("last_seen", "last_pm25"), names(status_feed))) {
      incoming <- status_feed[[nm]][match_idx]
      replace <- valid & !is.na(incoming) &
        (is.na(out[[nm]]) | incoming > out[[nm]])
      out[[nm]][replace] <- incoming[replace]
    }
  }
  age_h <- as.numeric(difftime(now, out$last_seen, units = "hours"))
  out$quality[is.na(out$last_seen) | age_h > 6] <- "Offline"
  current <- !is.na(data_age_h) & data_age_h <= 1
  out$quality[current & is.finite(out$latest_pm25)] <- "Reporting"
  missing_pm <- current & !is.finite(out$latest_pm25)
  recovered <- !is.na(out$last_pm25) & out$last_pm25 >= now - 86400
  out$quality[missing_pm & recovered] <- "PM missing"
  out$quality[missing_pm & recovered & is.finite(out$temp_recent) &
                out$temp_recent >= 47.5] <- "PM paused by heat"
  out$quality[missing_pm & !recovered] <- "PM sensor needs review"
  out$age_hours <- age_h
  out
}

sunset_hourly_replay <- function(data, wind, end, pollutant = "pm25") {
  start <- end - 3600
  d <- data[!is.na(data$timestamp) & data$timestamp > start &
              data$timestamp <= end & is.finite(data[[pollutant]]), ]
  out <- data.frame(sn = character(), value = numeric(), n_minutes = integer(),
                    timestamp = as.POSIXct(character(), tz = "UTC"),
                    geo_lat = numeric(), geo_lon = numeric())
  if (nrow(d)) out <- do.call(rbind, lapply(split(d, d$sn), function(x) {
    data.frame(sn = x$sn[1], value = mean(x[[pollutant]]),
               n_minutes = length(unique(floor(as.numeric(x$timestamp) / 60))),
               timestamp = max(x$timestamp),
               geo_lat = x$geo_lat[which.max(x$timestamp)],
               geo_lon = x$geo_lon[which.max(x$timestamp)])
  }))
  out$value[which(out$n_minutes < 30)] <- NA_real_
  if (!is.null(wind) && nrow(wind)) {
    w <- wind[!is.na(wind$timestamp) & wind$timestamp > start &
                wind$timestamp <= end & is.finite(wind$ws) &
                is.finite(wind$wd), ]
    if (nrow(w)) {
      wind_summary <- do.call(rbind, lapply(split(w, w$sn), function(x) {
        # Mean vector uses speed as weight; the direction is the direction
        # wind comes FROM, as in the original sensor feed.
        u <- mean(x$ws * sin(x$wd * pi / 180))
        v <- mean(x$ws * cos(x$wd * pi / 180))
        data.frame(sn = x$sn[1], ws = sqrt(u^2 + v^2),
                   wd = (atan2(u, v) * 180 / pi + 360) %% 360,
                   wind_minutes = length(unique(floor(as.numeric(x$timestamp) / 60))))
      }))
      out <- merge(out, wind_summary, by = "sn", all = TRUE, sort = FALSE)
    }
  }
  # rep() keeps an empty hour (stale feed, no wind) a zero-row frame; a bare
  # NA_real_ cannot be assigned to zero rows and crashed every page load.
  for (nm in c("ws", "wd", "wind_minutes"))
    if (!nm %in% names(out)) out[[nm]] <- rep(NA_real_, nrow(out))
  out
}

# ── Calibration (added 2026-11-05) ─────────────────────────────────────────
# Curves are vendored from sunset-pipeline/config/calibration_curves.csv,
# whose source of record is CALIBRATION_FINAL.md (2026-06-30): PM2.5 is a
# per-sensor SIZEBINS OLS (pooled curve for MOD-00549 and any sensor without
# its own), O3 a per-sensor baseline OLS in ppm (none for MOD-00549). The
# curves are linear, so calibrating minute rows yields hourly means identical
# to calibrating hourly means. Negative results are floored at 0 for display.
# MOD-00559 has a faulty particle sensor: all of its PM channels are blanked.
SUNSET_PM_EXCLUDE <- c("MOD-00559")
SUNSET_PM_POOLED  <- c("MOD-00549")

sunset_load_curves <- function(path = "config/calibration_curves.csv") {
  if (!file.exists(path)) return(NULL)
  cv <- utils::read.csv(path, stringsAsFactors = FALSE)
  if (!all(c("sensor_id", "pollutant", "b_intercept") %in% names(cv))) return(NULL)
  cv
}

sunset_calibrate <- function(df, curves, calibrate_pm25 = TRUE, calibrate_o3 = TRUE) {
  if (is.null(df) || !nrow(df)) return(df)
  bad <- df$sn %in% SUNSET_PM_EXCLUDE
  for (col in intersect(c("pm1", "pm25", "pm10"), names(df))) df[[col]][bad] <- NA_real_
  if (is.null(curves)) return(df)
  coef0 <- function(v) { v[is.na(v)] <- 0; v }
  if (calibrate_pm25 && all(c("pm25", "pm1", "pm10", "rh", "temp") %in% names(df))) {
    pm <- curves[curves$pollutant == "PM2.5", ]
    per <- pm[pm$sensor_id != "NETWORK_POOL", ]
    pool <- pm[pm$sensor_id == "NETWORK_POOL", ][1, ]
    use_pool <- !(df$sn %in% per$sensor_id) | df$sn %in% SUNSET_PM_POOLED
    idx <- match(df$sn, per$sensor_id)
    b <- function(col) coef0(ifelse(use_pool, pool[[col]], per[[col]][idx]))
    cal <- b("b_intercept") + b("b_pm25_raw") * df$pm25 + b("b_pm1_raw") * df$pm1 +
      b("b_pm10_raw") * df$pm10 + b("b_met_rh") * df$rh + b("b_met_temp") * df$temp
    cal[!is.na(cal) & cal < 0] <- 0
    df$pm25 <- cal
  }
  if (calibrate_o3 && "o3" %in% names(df)) {
    o3 <- curves[curves$pollutant == "O3" & !curves$sensor_id %in% SUNSET_PM_POOLED, ]
    oi <- match(df$sn, o3$sensor_id)
    cal <- (o3$b_intercept[oi] + o3$b_o3_ppm[oi] * (df$o3 / 1000)) * 1000  # ppm -> ppb
    cal[!is.na(cal) & cal < 0] <- 0
    df$o3 <- cal
  }
  df
}

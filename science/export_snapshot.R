# Browser-ready public data. Source calculations are vendored, unchanged, from
# SUNSET Shiny d7bec83. No credentials or private device fields are exported.
source("science/sunset_dashboard_helpers.R")
library(jsonlite)

build_snapshot <- function(raw, meta, status = NULL, now = Sys.time()) {
  raw$timestamp <- as.POSIXct(raw$timestamp, tz = "UTC", format = "%Y-%m-%d %H:%M:%S")
  d <- sunset_calibrate(raw, sunset_load_curves("science/config/calibration_curves.csv"), TRUE, FALSE)
  roster <- c("MOD-00433", sprintf("MOD-%05d", 546:565))
  meta <- meta[match(roster, meta$sn), ]; meta$sn <- roster
  if (!is.null(status)) for (nm in c("last_seen", "last_pm25"))
    status[[nm]] <- as.POSIXct(status[[nm]], tz = "UTC", format = "%Y-%m-%d %H:%M:%S")
  quality <- sunset_site_status(d, roster, status, now)
  iso <- function(x) if (!length(x) || is.na(x)) NULL else format(x, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  measures <- list(
    list(key="pm25",label="PM₂.₅",unit="µg/m³",aqi_hours=24),
    list(key="pm10",label="PM₁₀",unit="µg/m³",aqi_hours=24),
    list(key="pm1",label="PM₁",unit="µg/m³",aqi_hours=NULL),
    list(key="o3",label="O₃",unit="ppm",aqi_hours=8),
    list(key="co",label="CO",unit="ppm",aqi_hours=8),
    list(key="temp",label="Enclosure temperature",unit="°C",aqi_hours=NULL),
    list(key="rh",label="Relative humidity",unit="%",aqi_hours=NULL))
  hours <- c(real_time=.5, `1hr`=1, `12hr`=12, `24hr`=24)
  windows <- lapply(names(hours), function(k) {
    r <- d[!is.na(d$timestamp) & d$timestamp >= now-hours[[k]]*3600 & d$timestamp <= now+300, ]
    r <- r[order(r$sn, -as.numeric(r$timestamp)), ]
    r[!duplicated(r$sn), ]
  }); names(windows) <- names(hours)
  domains <- aqis <- trends <- list()
  hist <- d[!is.na(d$timestamp) & d$timestamp >= now-86400 & d$timestamp <= now+300, ]
  # Exact completed-hour bins. Empty or sparse hours stay gaps in the chart.
  bins <- seq(floor(as.numeric(now)/3600)*3600-23*3600, by=3600, length.out=24)
  for (m in measures) {
    key <- m$key; divisor <- if (key %in% c("o3","co")) 1000 else 1
    reference <- hist[[key]]/divisor; reference <- reference[is.finite(reference)]
    if (length(reference)) reference <- as.numeric(quantile(reference,c(.05,.95)))
    domains[[key]] <- lapply(windows,function(r) sunset_relative_domain(r[[key]]/divisor,reference,if(m$unit=="ppm") .006 else .1))
    aqis[[key]] <- sunset_aqi_snapshot(d,key,now)
    trends[[key]] <- lapply(roster,function(sn) {
      x <- hist[hist$sn==sn & is.finite(hist[[key]]) & hist$timestamp<=now, ]
      x$bin <- floor(as.numeric(x$timestamp)/3600)*3600
      lapply(bins,function(bin) {
        h <- x[x$bin==bin, ]; n <- length(unique(floor(as.numeric(h$timestamp)/60)))
        list(at=iso(as.POSIXct(bin,origin="1970-01-01",tz="UTC")),
             value=if(n>=30) mean(h[[key]])/divisor else NA_real_)
      })
    }); names(trends[[key]]) <- roster
  }
  sites <- lapply(seq_along(roster),function(i) {
    sn <- roster[i]; q <- quality[i, ]
    metrics <- lapply(measures,function(m) {
      key <- m$key; divisor <- if(key %in% c("o3","co")) 1000 else 1
      a <- aqis[[key]]; a <- a[a$sn==sn, ]
      list(readings=lapply(windows,function(r) {
        x<-r[r$sn==sn, ]; list(value=if(nrow(x)) x[[key]][1]/divisor else NA_real_,at=if(nrow(x)) iso(x$timestamp[1]) else NULL)
      }), aqi=if(nrow(a)) a$aqi[1] else NA_integer_,
      aqi_coverage=if(nrow(a)) a$coverage[1] else NA_real_,
      aqi_at=if(nrow(a)) iso(now-a$age_min[1]*60) else NULL,
      trend=trends[[key]][[sn]])
    }); names(metrics)<-vapply(measures,`[[`,character(1),"key")
    list(id=sn,name=if(is.na(meta$description[i])) sn else meta$description[i],
      lat=meta$geo_lat[i],lng=meta$geo_lon[i],
      last_seen=iso(q$last_seen),pm_quality=q$quality,coverage_24h=q$transmission_rate,
      minutes_24h=q$records_24h,metrics=metrics)
  })
  list(schema_version=1,generated_at=iso(now),last_observation=iso(max(d$timestamp,na.rm=TRUE)),
    calibration=list(pm25=TRUE,o3=FALSE,source="SUNSET Shiny d7bec83",excluded_pm=I(SUNSET_PM_EXCLUDE)),
    source="https://raw.githubusercontent.com/cchaeha/sunset-pipeline/gh-pages/app_feed.csv.gz",
    refresh_minutes=20,measures=measures,domains=domains,sites=sites)
}

if (sys.nframe()==0) {
  args <- commandArgs(TRUE)
  feed <- if(length(args)) args[1] else "data/export/app_feed.csv.gz"
  output <- if(length(args)>1) args[2] else "data/export/react-snapshot.json"
  status_path <- file.path(dirname(feed),"status.csv")
  raw <- read.csv(gzfile(feed),stringsAsFactors=FALSE)
  status <- if(file.exists(status_path)) read.csv(status_path,stringsAsFactors=FALSE) else NULL
  snapshot <- build_snapshot(raw,read.csv("science/config/sites.csv",stringsAsFactors=FALSE),status)
  dir.create(dirname(output),recursive=TRUE,showWarnings=FALSE)
  write_json(snapshot,output,auto_unbox=TRUE,na="null",null="null",digits=12)
  cat("Snapshot:",length(snapshot$sites),"sites; observations through",snapshot$last_observation,"\n")
}

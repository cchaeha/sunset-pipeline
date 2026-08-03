# 30e_archive.R — durable daily Parquet partitions.
#
# WHY THIS EXISTS. The QuantAQ subscription is the single point of failure this
# project cannot engineer around: if it lapses, ingestion stops and the API is
# no longer a source of history. It has already lapsed once, which is what made
# data disappear from the public dashboard. These Parquet files are therefore
# the asset that has to survive — an institutional move, a returned laptop, a
# lost API key, or a handover to PDEQ.
#
# One file per completed day, zstd: ~553 KB/day, ~17 MB/month, ~207 MB/year.
# Immutable once written, so committing them to git creates no churn and the
# repo stays well inside GitHub's comfortable range for years.
#
# Sourced by 30_run_pipeline.R; not run standalone.

ARCHIVE_DIR <- file.path(PIPE_DIR, "archive")

write_archive <- function(con, rewrite_today = FALSE) {
  dir.create(ARCHIVE_DIR, showWarnings = FALSE, recursive = TRUE)

  days <- DBI::dbGetQuery(con, "
    SELECT CAST(timestamp AS DATE) AS d, count(*) AS n,
           max(CAST(timestamp AS TIME)) AS last_time
    FROM sensor_data GROUP BY 1 ORDER BY 1")
  if (!nrow(days)) return(list(written = 0L, skipped = 0L))

  today <- Sys.Date()
  written <- 0L; skipped <- 0L
  for (i in seq_len(nrow(days))) {
    d <- as.Date(days$d[i])
    # Only archive COMPLETED days: today is still accumulating, and writing a
    # partial day would produce a file that is immutable but wrong.
    if (d >= today && !rewrite_today) { skipped <- skipped + 1L; next }

    # A day is only "complete" if the store actually holds data to the END of
    # it. Without this check a machine that stopped ingesting mid-afternoon
    # freezes a truncated day as authoritative. Observed 2026-08-03: this
    # laptop wrote 2026-08-02 with 18,600 rows ending 16:21 while the real day
    # had 27,309 rows ending 23:59 — 8 hours would have been lost permanently
    # had CI not written the same day independently.
    if (is.na(days$last_time[i]) || as.character(days$last_time[i]) < "23:00:00") {
      message(sprintf("   skipping %s: store only reaches %s, day looks incomplete",
                      format(d, "%Y-%m-%d"), days$last_time[i]))
      skipped <- skipped + 1L; next
    }

    yr  <- format(d, "%Y")
    out <- file.path(ARCHIVE_DIR, yr, sprintf("%s.parquet", format(d, "%Y-%m-%d")))
    dir.create(dirname(out), showWarnings = FALSE, recursive = TRUE)

    # Self-correcting: if an existing file has FEWER rows than the store now
    # holds for that day, it was written from incomplete data — replace it.
    if (file.exists(out)) {
      have <- tryCatch(DBI::dbGetQuery(con, sprintf(
        "SELECT count(*) AS n FROM read_parquet('%s')", out))$n, error = function(e) NA_integer_)
      if (!is.na(have) && have >= days$n[i]) { skipped <- skipped + 1L; next }
      message(sprintf("   replacing %s: file has %s rows, store has %s",
                      format(d, "%Y-%m-%d"), format(have, big.mark = ","),
                      format(days$n[i], big.mark = ",")))
    }

    DBI::dbExecute(con, sprintf("
      COPY (SELECT * FROM sensor_data WHERE CAST(timestamp AS DATE) = DATE '%s'
            ORDER BY sn, timestamp)
      TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", format(d, "%Y-%m-%d"), out))
    written <- written + 1L
    message(sprintf("   archived %s (%s rows, %.0f KB)",
                    format(d, "%Y-%m-%d"), format(days$n[i], big.mark = ","),
                    file.size(out) / 1024))
  }
  list(written = written, skipped = skipped)
}

# Rebuild the working store from committed Parquet. This is what makes the
# GitHub Actions cache disposable: if the cache is evicted, restore from the
# archive and let the incremental ingest fill the tail from the API.
restore_from_archive <- function(con) {
  files <- list.files(ARCHIVE_DIR, pattern = "\\.parquet$",
                      recursive = TRUE, full.names = TRUE)
  if (!length(files)) return(0L)
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sensor_data (
      sn VARCHAR, timestamp TIMESTAMP, geo_lat DOUBLE, geo_lon DOUBLE,
      pm1 DOUBLE, pm25 DOUBLE, pm10 DOUBLE, co DOUBLE, no DOUBLE, no2 DOUBLE,
      o3 DOUBLE, rh DOUBLE, temp DOUBLE,
      ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      PRIMARY KEY (sn, timestamp))")
  n <- DBI::dbExecute(con, sprintf("
    INSERT INTO sensor_data
      (sn,timestamp,geo_lat,geo_lon,pm1,pm25,pm10,co,no,no2,o3,rh,temp)
    SELECT sn,timestamp,geo_lat,geo_lon,pm1,pm25,pm10,co,no,no2,o3,rh,temp
    FROM read_parquet('%s/*/*.parquet')
    ON CONFLICT (sn, timestamp) DO NOTHING", ARCHIVE_DIR))
  message(sprintf("   restored %s rows from %d archive files",
                  format(n, big.mark = ","), length(files)))
  n
}

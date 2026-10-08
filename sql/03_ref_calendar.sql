-- =====================================================================
-- 03_ref_calendar.sql  —  REFERENCE DATA
-- The 2025–26 school calendar, built from the districts' notes (both
-- follow the same state calendar). One row per calendar day.
-- Used to catch attendance recorded on non-school days and to check
-- that enrolled-day counts are possible.
-- =====================================================================

CREATE OR REPLACE TABLE ref_calendar AS
WITH all_days AS (
    SELECT CAST(d AS DATE) AS cal_date
    FROM generate_series(DATE '2025-08-11', DATE '2026-05-22', INTERVAL 1 DAY) AS t(d)
),
no_school (start_date, end_date, reason) AS (
    VALUES
        (DATE '2025-09-01', DATE '2025-09-01', 'Labor Day'),
        (DATE '2025-10-31', DATE '2025-10-31', 'Nevada Day'),
        (DATE '2025-11-11', DATE '2025-11-11', 'Veterans Day'),
        (DATE '2025-11-26', DATE '2025-11-28', 'Thanksgiving break'),
        (DATE '2025-12-22', DATE '2026-01-02', 'Winter break'),
        (DATE '2026-01-19', DATE '2026-01-19', 'MLK Day'),
        (DATE '2026-02-16', DATE '2026-02-16', 'Presidents Day'),
        (DATE '2026-03-23', DATE '2026-03-27', 'Spring break')
)
SELECT
    d.cal_date,
    strftime(d.cal_date, '%Y-%m')                         AS month,
    CASE WHEN d.cal_date <= DATE '2025-12-19' THEN 'S1' ELSE 'S2' END AS semester,
    CASE
        WHEN dayofweek(d.cal_date) IN (0, 6) THEN 'Weekend'   -- 0 = Sunday, 6 = Saturday
        ELSE n.reason
    END                                                   AS no_school_reason,
    (dayofweek(d.cal_date) NOT IN (0, 6) AND n.reason IS NULL) AS is_school_day
FROM all_days d
LEFT JOIN no_school n
       ON d.cal_date BETWEEN n.start_date AND n.end_date;

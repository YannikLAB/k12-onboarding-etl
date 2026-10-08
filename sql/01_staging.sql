-- =====================================================================
-- 01_staging.sql  —  EXTRACT
-- Load every raw file exactly as delivered. Every column is read as text
-- (all_varchar = true) so nothing gets silently converted: grade "06"
-- stays "06", bad dates stay visible, and we decide how to clean them
-- in the next step. Staging tables are prefixed stg_.
-- =====================================================================

-- District A (Mesquite Flats, PowerSchool-style)
CREATE OR REPLACE TABLE stg_a_schools    AS SELECT * FROM read_csv('data/raw/district_a_mesquite_flats/schools.csv',       all_varchar = true);
CREATE OR REPLACE TABLE stg_a_students   AS SELECT * FROM read_csv('data/raw/district_a_mesquite_flats/students.csv',      all_varchar = true);
CREATE OR REPLACE TABLE stg_a_attendance AS SELECT * FROM read_csv('data/raw/district_a_mesquite_flats/attendance.csv',    all_varchar = true);
CREATE OR REPLACE TABLE stg_a_grades     AS SELECT * FROM read_csv('data/raw/district_a_mesquite_flats/stored_grades.csv', all_varchar = true);

-- District B (Pinon Ridge, Infinite Campus-style)
CREATE OR REPLACE TABLE stg_b_enrollment AS SELECT * FROM read_csv('data/raw/district_b_pinon_ridge/enrollment.csv',         all_varchar = true);
CREATE OR REPLACE TABLE stg_b_attendance AS SELECT * FROM read_csv('data/raw/district_b_pinon_ridge/attendance_monthly.csv', all_varchar = true);
CREATE OR REPLACE TABLE stg_b_grades     AS SELECT * FROM read_csv('data/raw/district_b_pinon_ridge/grades.csv',             all_varchar = true);

-- Data quality log: every issue you find gets a row here.
CREATE OR REPLACE TABLE dq_log (
    district              TEXT,
    source_file           TEXT,
    issue                 TEXT,
    rows_affected         INTEGER,
    action_taken          TEXT,   -- fixed / excluded / flagged
    question_for_district TEXT
);

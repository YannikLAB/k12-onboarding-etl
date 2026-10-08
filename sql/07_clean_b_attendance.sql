-- =====================================================================
-- 07_clean_b_attendance.sql  —  TRANSFORM
-- District B sends attendance already summarized by student and month,
-- so it can't be broken back down into days. That's why the combined
-- model uses student-month as its common level of detail.
-- =====================================================================

INSERT INTO dq_log
SELECT 'B', 'attendance_monthly.csv', 'School name spelled differently from the official name', COUNT(*),
       'fixed (mapped to official school)', NULL
FROM stg_b_attendance
WHERE schoolName NOT IN ('Juniper Canyon Middle School', 'Pinon Ridge High School')
  AND b_school_key(schoolName) IS NOT NULL      -- unknown names are rejected below, not "fixed"
HAVING COUNT(*) > 0;

-- The same student + month appearing more than once means a file was loaded twice.
INSERT INTO dq_log
SELECT 'B', 'attendance_monthly.csv', 'Same student and month appears twice (duplicate load)',
       SUM(copies - 1),
       'excluded (kept one copy)',
       'Rows for ' || string_agg(DISTINCT month || ' at ' || school, '; ')
       || ' appear twice. Was that month''s file loaded twice?'
FROM (
    SELECT studentNumber, month, schoolName AS school, COUNT(*) AS copies
    FROM stg_b_attendance
    GROUP BY ALL
    HAVING COUNT(*) > 1
)
HAVING COUNT(*) > 0;

CREATE OR REPLACE TABLE b_attendance_checked AS
WITH deduped AS (
    SELECT DISTINCT * FROM stg_b_attendance
),
typed AS (
    SELECT
        TRIM(studentNumber)                         AS local_student_number,
        schoolName                                  AS raw_school_name,
        b_school_key(schoolName)                    AS school_key,
        month,
        -- TRY_CAST: a value like "n/a" becomes NULL and is rejected below, instead of crashing the run.
        TRY_CAST(daysEnrolled AS INTEGER)           AS days_enrolled,
        TRY_CAST(daysAbsentExcused AS INTEGER)      AS days_absent_excused,
        TRY_CAST(daysAbsentUnexcused AS INTEGER)    AS days_absent_unexcused   -- includes suspensions (per district notes)
    FROM deduped
)
SELECT
    s.student_key,
    t.*,
    CASE
        WHEN s.student_key IS NULL AND t.local_student_number IN (SELECT local_student_number FROM rejected_b_students)
                                   THEN 'Student record was rejected'
        WHEN s.student_key IS NULL THEN 'Student not in enrollment.csv'
        WHEN t.school_key IS NULL  THEN 'Unknown school name'
        WHEN t.days_enrolled IS NULL OR t.days_absent_excused IS NULL OR t.days_absent_unexcused IS NULL
                                   THEN 'Unreadable numbers'
    END AS reject_reason,
    -- Impossible numbers are FLAGGED, not fixed or dropped: we can't know the
    -- true value, and dropping the month would make the student look better.
    CASE
        WHEN t.days_absent_excused + t.days_absent_unexcused > t.days_enrolled
            THEN 'absences exceed days enrolled'
    END AS dq_flag
FROM typed t
LEFT JOIN clean_b_students s ON s.local_student_number = t.local_student_number;

INSERT INTO dq_log
SELECT 'B', 'attendance_monthly.csv', 'Absences exceed days enrolled', COUNT(*),
       'flagged (student''s attendance marked "needs review")',
       'For student(s) ' || string_agg(local_student_number || ' (' || month || ')', ', ')
       || ', absences are higher than days enrolled. What are the correct numbers?'
FROM b_attendance_checked
WHERE dq_flag IS NOT NULL
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'B', 'attendance_monthly.csv', reject_reason, COUNT(*), 'excluded (kept in rejected_b_attendance)', NULL
FROM b_attendance_checked
WHERE reject_reason IS NOT NULL
GROUP BY reject_reason;

CREATE OR REPLACE TABLE rejected_b_attendance AS
SELECT * FROM b_attendance_checked WHERE reject_reason IS NOT NULL;

CREATE OR REPLACE TABLE clean_b_attendance AS
SELECT student_key, school_key, month, days_enrolled, days_absent_excused, days_absent_unexcused, dq_flag
FROM b_attendance_checked
WHERE reject_reason IS NULL;

DROP TABLE b_attendance_checked;

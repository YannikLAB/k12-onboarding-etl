-- =====================================================================
-- 11_validation.sql  —  CHECKS
-- Automated tests that run after every load. Each check counts the rows
-- that break a rule; 0 problems = PASS. run_pipeline.py prints these and
-- stops with an error if anything fails.
-- =====================================================================

CREATE OR REPLACE TABLE validation_results AS

-- Every raw attendance row is accounted for: clean + rejected = raw.
SELECT 'District A attendance: raw rows = clean + rejected' AS check_name,
       ABS((SELECT COUNT(*) FROM stg_a_attendance)
         - (SELECT COUNT(*) FROM clean_a_attendance)
         - (SELECT COUNT(*) FROM rejected_a_attendance)) AS problems

UNION ALL
-- A duplicate here would double-count everything joined to it.
SELECT 'One row per student in dim_student',
       COUNT(*) - COUNT(DISTINCT student_key)
FROM dim_student

UNION ALL
SELECT 'One row per student per month in attendance',
       COUNT(*) - COUNT(DISTINCT (student_key, month))
FROM fact_attendance_monthly

UNION ALL
SELECT 'Every attendance row belongs to a known student',
       COUNT(*)
FROM fact_attendance_monthly f
LEFT JOIN dim_student s ON s.student_key = f.student_key
WHERE s.student_key IS NULL

UNION ALL
SELECT 'Every student belongs to a known school',
       COUNT(*)
FROM dim_student st
LEFT JOIN dim_school sc ON sc.school_key = st.school_key
WHERE sc.school_key IS NULL

UNION ALL
-- Reconcile two independent sources: attendance rows vs. the calendar.
SELECT 'District A: days enrolled match the school calendar',
       COUNT(*)
FROM (
    SELECT st.student_key,
           (SELECT COUNT(*) FROM ref_calendar c
             WHERE c.is_school_day AND c.cal_date BETWEEN st.entry_date AND st.last_enrolled_date) AS calendar_days,
           (SELECT COUNT(*) FROM clean_a_attendance a WHERE a.student_key = st.student_key)      AS attendance_days
    FROM dim_student st
    WHERE st.district = 'A'
)
WHERE calendar_days <> attendance_days

UNION ALL
SELECT 'District B: days enrolled never exceed school days in the month',
       COUNT(*)
FROM fact_attendance_monthly f
JOIN (SELECT month, COUNT(*) AS school_days FROM ref_calendar WHERE is_school_day GROUP BY month) c
  ON c.month = f.month
WHERE f.student_key LIKE 'B-%' AND f.days_enrolled > c.school_days

UNION ALL
SELECT 'Absences never exceed days enrolled (unless flagged)',
       COUNT(*)
FROM fact_attendance_monthly
WHERE days_absent_excused + days_absent_unexcused > days_enrolled
  AND dq_flag IS NULL

UNION ALL
SELECT 'Every posted grade is A, B, C, D or F',
       COUNT(*)
FROM fact_course_grade
WHERE grade_status = 'graded'
  AND (letter_grade IS NULL OR letter_grade NOT IN ('A', 'B', 'C', 'D', 'F'))

UNION ALL
SELECT 'Every student has an early warning status',
       ABS((SELECT COUNT(*) FROM dim_student) - (SELECT COUNT(*) FROM v_early_warning));

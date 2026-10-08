-- =====================================================================
-- 05_clean_a_grades.sql  —  TRANSFORM
-- District A final semester grades: staging -> clean.
-- District A sends letter grades with +/- (e.g. "B+"). Families see the
-- plain letter (A–F), so "B+" becomes "B". "W" means withdrew from the
-- course; a blank means no grade was posted.
-- =====================================================================

CREATE OR REPLACE TABLE a_grades_checked AS
WITH typed AS (
    SELECT
        TRIM(Student_Number)                            AS local_student_number,
        TRIM(Course_Number)                             AS course_code,
        TRIM(Course_Name)                               AS course_name,
        regexp_extract(TRIM(Course_Number), '^[A-Z]+')  AS subject_code,   -- "ENG09" -> "ENG"
        StoreCode                                       AS term,           -- already S1 / S2
        NULLIF(UPPER(TRIM(Grade)), '')                  AS grade_raw,      -- blank -> NULL; "b+" -> "B+"
        TRY_CAST(NULLIF(EarnedCrHrs, '') AS DOUBLE)     AS credits_earned
    FROM stg_a_grades
)
SELECT
    s.student_key,
    t.*,
    t.subject_code IN ('ENG', 'MATH', 'SCI', 'SS')     AS is_core,
    CASE
        WHEN t.grade_raw IS NULL THEN 'not posted'
        WHEN t.grade_raw = 'W'   THEN 'withdrawn'
        ELSE 'graded'
    END                                                 AS grade_status,
    CASE
        WHEN t.grade_raw IS NULL OR t.grade_raw = 'W' THEN NULL
        ELSE LEFT(t.grade_raw, 1)                       -- "B+" -> "B", "D-" -> "D"
    END                                                 AS letter_grade,
    CASE
        WHEN s.student_key IS NULL AND t.local_student_number IN (SELECT local_student_number FROM rejected_a_students)
                                   THEN 'Student record was rejected'
        WHEN s.student_key IS NULL THEN 'Student not in students.csv'
        WHEN t.grade_raw IS NOT NULL AND t.grade_raw <> 'W'
         AND LEFT(t.grade_raw, 1) NOT IN ('A', 'B', 'C', 'D', 'F') THEN 'Unrecognized grade'
    END                                                 AS reject_reason
FROM typed t
LEFT JOIN clean_a_students s ON s.local_student_number = t.local_student_number;

INSERT INTO dq_log
SELECT 'A', 'stored_grades.csv', 'Blank grade (not posted)', COUNT(*),
       'flagged (shown as "not posted yet"; not counted as a failure)',
       'Grades are blank for ' || COUNT(*) || ' course sections in ' || string_agg(DISTINCT term, ', ')
       || '. Not yet posted, or missing from the export?'
FROM a_grades_checked
WHERE grade_status = 'not posted'
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'A', 'stored_grades.csv', reject_reason, COUNT(*), 'excluded (kept in rejected_a_grades)', NULL
FROM a_grades_checked
WHERE reject_reason IS NOT NULL
GROUP BY reject_reason;

CREATE OR REPLACE TABLE rejected_a_grades AS
SELECT * FROM a_grades_checked WHERE reject_reason IS NOT NULL;

CREATE OR REPLACE TABLE clean_a_grades AS
SELECT student_key, term, course_code, course_name, subject_code, is_core,
       grade_status, letter_grade, NULL::DOUBLE AS score_percent, credits_earned
FROM a_grades_checked
WHERE reject_reason IS NULL;

DROP TABLE a_grades_checked;

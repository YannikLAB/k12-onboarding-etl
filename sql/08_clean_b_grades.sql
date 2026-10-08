-- =====================================================================
-- 08_clean_b_grades.sql  —  TRANSFORM
-- District B sends percentages. Families see letters, so scores are
-- converted with District B's own scale (from its notes).
-- =====================================================================

INSERT INTO dq_log
SELECT 'B', 'grades.csv', 'Score above 100%', COUNT(*),
       'kept (treated as an A; assumed extra credit)',
       'Some scores are above 100% (' || string_agg(score, ', ') || '). Is extra credit allowed, or are these entry errors?'
FROM stg_b_grades
WHERE TRY_CAST(score AS DOUBLE) > 100
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'B', 'grades.csv', 'Blank score (not posted)', COUNT(*),
       'flagged (shown as "not posted yet"; not counted as a failure)',
       'Scores are blank for ' || COUNT(*) || ' course sections. Not yet posted, or missing from the export?'
FROM stg_b_grades
WHERE NULLIF(TRIM(score), '') IS NULL
HAVING COUNT(*) > 0;

CREATE OR REPLACE TABLE b_grades_checked AS
WITH typed AS (
    SELECT
        TRIM(studentNumber)                             AS local_student_number,
        courseCode                                      AS course_code,
        TRIM(courseName)                                AS course_name,
        split_part(courseCode, '-', 1)                  AS subject_code,   -- "ENG-9" -> "ENG"
        CASE term WHEN 'Sem 1' THEN 'S1' WHEN 'Sem 2' THEN 'S2' END AS term,
        TRY_CAST(NULLIF(TRIM(score), '') AS DOUBLE)     AS score_percent,
        TRY_CAST(NULLIF(creditsEarned, '') AS DOUBLE)   AS credits_earned
    FROM stg_b_grades
)
SELECT
    s.student_key,
    t.*,
    t.subject_code IN ('ENG', 'MATH', 'SCI', 'SS')     AS is_core,
    CASE WHEN t.score_percent IS NULL THEN 'not posted' ELSE 'graded' END AS grade_status,
    CASE
        WHEN t.score_percent IS NULL THEN NULL          -- unknown stays unknown, never an F
        WHEN t.score_percent >= 90   THEN 'A'
        WHEN t.score_percent >= 80   THEN 'B'
        WHEN t.score_percent >= 70   THEN 'C'
        WHEN t.score_percent >= 60   THEN 'D'
        ELSE 'F'
    END                                                 AS letter_grade,
    CASE
        WHEN s.student_key IS NULL AND t.local_student_number IN (SELECT local_student_number FROM rejected_b_students)
                                   THEN 'Student record was rejected'
        WHEN s.student_key IS NULL THEN 'Student not in enrollment.csv'
        WHEN t.term IS NULL        THEN 'Unknown term'
    END                                                 AS reject_reason
FROM typed t
LEFT JOIN clean_b_students s ON s.local_student_number = t.local_student_number;

INSERT INTO dq_log
SELECT 'B', 'grades.csv', reject_reason, COUNT(*), 'excluded (kept in rejected_b_grades)', NULL
FROM b_grades_checked
WHERE reject_reason IS NOT NULL
GROUP BY reject_reason;

CREATE OR REPLACE TABLE rejected_b_grades AS
SELECT * FROM b_grades_checked WHERE reject_reason IS NOT NULL;

CREATE OR REPLACE TABLE clean_b_grades AS
SELECT student_key, term, course_code, course_name, subject_code, is_core,
       grade_status, letter_grade, score_percent, credits_earned
FROM b_grades_checked
WHERE reject_reason IS NULL;

DROP TABLE b_grades_checked;

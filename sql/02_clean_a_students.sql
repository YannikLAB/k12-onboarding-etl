-- =====================================================================
-- 02_clean_a_students.sql  —  TRANSFORM (worked example)
-- District A students: staging -> clean.
-- Use this file as the pattern for every other clean_ table:
--   1. convert text to real types with TRY_ functions (bad values become
--      NULL instead of crashing the whole run),
--   2. label each row with a reject reason, or NULL if it's usable,
--   3. log the counts, then split into clean_ and rejected_ tables.
-- =====================================================================

-- Step 1: log exact duplicates BEFORE removing them, so the count is accurate.
INSERT INTO dq_log
SELECT 'A', 'students.csv', 'Exact duplicate rows', dupes, 'excluded (kept one copy)', NULL
FROM (SELECT (SELECT COUNT(*) FROM stg_a_students)
           - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM stg_a_students)) AS dupes)
WHERE dupes > 0;

-- Step 2: convert types and label every row.
CREATE OR REPLACE TABLE a_students_labeled AS
WITH deduped AS (
    SELECT DISTINCT * FROM stg_a_students          -- removes exact duplicates
),
typed AS (
    SELECT
        'A-' || TRIM(Student_Number)                    AS student_key,   -- student numbers repeat across districts
        'A'                                             AS district,
        TRIM(Student_Number)                            AS local_student_number,
        -- trim stray spaces, then fix capitalization: "  sanchez " -> "Sanchez"
        upper(left(trim(First_Name), 1)) || lower(substr(trim(First_Name), 2)) AS first_name,
        upper(left(trim(Last_Name), 1))  || lower(substr(trim(Last_Name), 2))  AS last_name,
        -- try_strptime returns NULL for text it can't read ("13/45/2025"), instead of crashing.
        try_strptime(TRIM(DOB), '%m/%d/%Y')::DATE       AS birth_date,
        Gender                                          AS gender,
        TRY_CAST(TRIM(Grade_Level) AS INTEGER)          AS grade_level,
        'A-' || TRIM(SchoolID)                          AS school_key,
        try_strptime(TRIM(EntryDate), '%m/%d/%Y')::DATE AS entry_date,
        -- District A's ExitDate is the first day NOT enrolled, so the last
        -- enrolled day is the day before. (District B is different. Read its notes!)
        try_strptime(TRIM(ExitDate), '%m/%d/%Y')::DATE - 1 AS last_enrolled_date,
        NULLIF(TRIM(DOB), '')                           AS raw_birth_date,
        NULLIF(TRIM(Grade_Level), '')                   AS raw_grade_level
    FROM deduped
)
SELECT
    *,
    -- Without a student number or readable enrollment dates, the student
    -- can't be placed in the school year at all, so the row is set aside.
    CASE
        WHEN NULLIF(local_student_number, '') IS NULL       THEN 'Missing student number'
        WHEN entry_date IS NULL OR last_enrolled_date IS NULL THEN 'Unreadable enrollment dates'
    END AS reject_reason
FROM typed;

INSERT INTO dq_log
SELECT 'A', 'students.csv', reject_reason, COUNT(*), 'excluded (kept in rejected_a_students)',
       'Student(s) ' || string_agg(local_student_number, ', ') || ' could not be loaded: '
       || lower(reject_reason) || '. Can you resend these records?'
FROM a_students_labeled
WHERE reject_reason IS NOT NULL
GROUP BY reject_reason;

CREATE OR REPLACE TABLE rejected_a_students AS
SELECT * FROM a_students_labeled WHERE reject_reason IS NOT NULL;

-- Step 3: build the clean table, keeping ONE row per student.
-- Why: if a student appears twice here, every later JOIN to attendance or
-- grades would match both rows and double-count that student's data.
CREATE OR REPLACE TABLE clean_a_students AS
WITH ranked AS (
    SELECT
        *,
        COUNT(*)     OVER (PARTITION BY student_key)                      AS copies,   -- how many rows this student has
        ROW_NUMBER() OVER (PARTITION BY student_key ORDER BY birth_date)  AS row_num   -- numbers each student's rows 1, 2, ...
    FROM a_students_labeled
    WHERE reject_reason IS NULL
)
SELECT
    student_key, district, local_student_number, first_name, last_name, birth_date, gender,
    grade_level, school_key, entry_date, last_enrolled_date,
    -- Flag, don't delete: these are questions for the district,
    -- not reasons to drop the student's attendance and grades.
    CASE
        WHEN copies > 1 THEN 'conflicting student records'
        WHEN raw_birth_date IS NOT NULL AND birth_date IS NULL THEN 'unreadable birth_date'
        WHEN birth_date < DATE '2000-01-01' OR birth_date > DATE '2020-12-31'
            THEN 'suspicious birth_date'
        WHEN grade_level IS NULL THEN 'unreadable grade_level'
    END AS dq_flag
FROM ranked
WHERE row_num = 1;   -- keep only the first row for each student

-- Step 4: log the flagged rows.
INSERT INTO dq_log
SELECT 'A', 'students.csv', 'Same student listed twice with different birth dates', COUNT(*),
       'kept one row, flagged',
       'Student(s) ' || string_agg(local_student_number, ', ') || ' appear twice with different birth dates. Which is correct?'
FROM clean_a_students
WHERE dq_flag = 'conflicting student records'
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'A', 'students.csv', 'Impossible or placeholder birth date', COUNT(*),
       'flagged (kept student)',
       'Birth dates for student(s) ' || string_agg(local_student_number, ', ') || ' look like placeholders or typos. What are the correct dates?'
FROM clean_a_students
WHERE dq_flag = 'suspicious birth_date'
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'A', 'students.csv', 'Unreadable birth date or grade level', COUNT(*),
       'flagged (kept student)',
       'Birth date or grade level for student(s) ' || string_agg(local_student_number, ', ') || ' could not be read. What are the correct values?'
FROM clean_a_students
WHERE dq_flag IN ('unreadable birth_date', 'unreadable grade_level')
HAVING COUNT(*) > 0;

DROP TABLE a_students_labeled;

-- =====================================================================
-- 02_clean_a_students.sql  —  TRANSFORM (worked example)
-- District A students: staging -> clean.
-- Use this file as the pattern for every other clean_ table.
-- =====================================================================

-- Step 1: log the issue BEFORE fixing it, so the count is accurate.
INSERT INTO dq_log
SELECT
    'A',
    'students.csv',
    'Exact duplicate rows',
    (SELECT COUNT(*) FROM stg_a_students)
      - (SELECT COUNT(*) FROM (SELECT DISTINCT * FROM stg_a_students)),
    'excluded (kept one copy)',
    NULL;

-- Step 2: build the clean table.
CREATE OR REPLACE TABLE clean_a_students AS
WITH deduped AS (
    SELECT DISTINCT * FROM stg_a_students          -- removes exact duplicates
),
typed AS (
    SELECT
        'A-' || Student_Number                          AS student_key,   -- student numbers repeat across districts
        'A'                                             AS district,
        Student_Number                                  AS local_student_number,
        -- trim stray spaces, then fix capitalization: "  sanchez " -> "Sanchez"
        upper(left(trim(First_Name), 1)) || lower(substr(trim(First_Name), 2)) AS first_name,
        upper(left(trim(Last_Name), 1))  || lower(substr(trim(Last_Name), 2))  AS last_name,
        strptime(DOB, '%m/%d/%Y')::DATE                 AS birth_date,     -- text "MM/DD/YYYY" -> real date
        Gender                                          AS gender,
        Grade_Level::INTEGER                            AS grade_level,
        'A-' || SchoolID                                AS school_key,
        strptime(EntryDate, '%m/%d/%Y')::DATE           AS entry_date,
        -- District A's ExitDate is the first day NOT enrolled, so the last
        -- enrolled day is the day before. (District B is different. Read its notes!)
        strptime(ExitDate, '%m/%d/%Y')::DATE - 1        AS last_enrolled_date
    FROM deduped
),
-- Step 2b: keep ONE row per student.
-- Why: if a student appears twice here, every later JOIN to attendance or
-- grades would match both rows and double-count that student's data.
ranked AS (
    SELECT
        *,
        COUNT(*)     OVER (PARTITION BY student_key)                      AS copies,   -- how many rows this student has
        ROW_NUMBER() OVER (PARTITION BY student_key ORDER BY birth_date)  AS row_num   -- numbers each student's rows 1, 2, ...
    FROM typed
)
SELECT
    * EXCLUDE (copies, row_num),   -- DuckDB shortcut: all columns except these helpers
    -- Flag, don't delete: these are questions for the district,
    -- not reasons to drop the student's attendance and grades.
    CASE
        WHEN copies > 1 THEN 'conflicting student records'
        WHEN birth_date < DATE '2000-01-01' OR birth_date > DATE '2020-12-31'
            THEN 'suspicious birth_date'
    END AS dq_flag
FROM ranked
WHERE row_num = 1;   -- keep only the first row for each student

-- Step 3: log the flagged rows.
INSERT INTO dq_log
SELECT 'A', 'students.csv', 'Same student listed twice with different birth dates', COUNT(*),
       'kept one row, flagged',
       'Student(s) ' || string_agg(local_student_number, ', ') || ' appear twice with different birth dates. Which is correct?'
FROM clean_a_students
WHERE dq_flag = 'conflicting student records';

INSERT INTO dq_log
SELECT 'A', 'students.csv', 'Impossible or placeholder birth date', COUNT(*),
       'flagged (kept student)',
       'Birth dates for student(s) ' || string_agg(local_student_number, ', ') || ' look like placeholders or typos. What are the correct dates?'
FROM clean_a_students
WHERE dq_flag = 'suspicious birth_date';

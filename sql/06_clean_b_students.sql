-- =====================================================================
-- 06_clean_b_students.sql  —  TRANSFORM
-- District B enrollment: staging -> clean, in the SAME shape as
-- clean_a_students so the two can be stacked later.
-- =====================================================================

-- District B has no schools file and spells school names inconsistently,
-- so every spelling seen so far is listed here explicitly. Names are
-- compared after normalizing: lowercase, accents removed ("Piñon" ->
-- "pinon"), extra spaces collapsed. A spelling that isn't on this list is
-- REJECTED and logged, so a person adds it here instead of the pipeline
-- guessing. (An earlier version matched on the start of the name, which
-- would have put "Pinon Ridge Elementary" into the high school.)
CREATE OR REPLACE TABLE ref_b_school_names AS
SELECT * FROM (VALUES
    ('juniper canyon middle school', 'B-JUNIPER'),
    ('juniper canyon ms',            'B-JUNIPER'),
    ('pinon ridge high school',      'B-PINON'),
    ('pinon ridge hs',               'B-PINON')
) AS t(spelling, school_key);

CREATE OR REPLACE MACRO norm_name(name) AS
    regexp_replace(lower(strip_accents(trim(name))), '\s+', ' ', 'g');

CREATE OR REPLACE MACRO b_school_key(school_name) AS
    (SELECT school_key FROM ref_b_school_names WHERE spelling = norm_name(school_name));

INSERT INTO dq_log
SELECT 'B', 'enrollment.csv', 'Grade level written inconsistently ("06", "6", "Gr 6")', COUNT(*),
       'fixed (converted to a number)', NULL
FROM stg_b_enrollment
WHERE NOT regexp_matches(grade, '^[0-9]{2}$')
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'B', 'enrollment.csv', 'Name not in "Last, First" format', COUNT(*),
       'fixed (read as "First Last"), flagged',
       'Names for student(s) ' || string_agg(studentNumber, ', ') || ' are not in "Last, First" format. Please confirm first and last names.'
FROM stg_b_enrollment
WHERE studentName NOT LIKE '%,%'
HAVING COUNT(*) > 0;

INSERT INTO dq_log
SELECT 'B', 'enrollment.csv', 'Missing birth date', COUNT(*), 'flagged (kept student)',
       'Birth dates are missing for student(s) ' || string_agg(studentNumber, ', ') || '.'
FROM stg_b_enrollment
WHERE NULLIF(TRIM(birthDate), '') IS NULL
HAVING COUNT(*) > 0;

CREATE OR REPLACE TABLE b_students_labeled AS
WITH deduped AS (
    SELECT DISTINCT * FROM stg_b_enrollment
),
typed AS (
    SELECT
        'B-' || TRIM(studentNumber)                              AS student_key,
        'B'                                                      AS district,
        TRIM(studentNumber)                                      AS local_student_number,
        -- "Garcia, Sofia" -> first = after the comma. Without a comma, assume "Sofia Garcia".
        CASE WHEN studentName LIKE '%,%' THEN TRIM(split_part(studentName, ',', 2))
             ELSE TRIM(split_part(studentName, ' ', 1)) END      AS first_name,
        CASE WHEN studentName LIKE '%,%' THEN TRIM(split_part(studentName, ',', 1))
             ELSE TRIM(substr(studentName, strpos(studentName, ' ') + 1)) END AS last_name,
        TRY_CAST(NULLIF(TRIM(birthDate), '') AS DATE)            AS birth_date,
        CASE gender WHEN 'Female' THEN 'F' WHEN 'Male' THEN 'M' END AS gender,
        TRY_CAST(regexp_extract(grade, '[0-9]+') AS INTEGER)     AS grade_level,   -- "Gr 6" -> 6
        schoolName                                               AS raw_school_name,
        b_school_key(schoolName)                                 AS school_key,
        TRY_CAST(NULLIF(TRIM(startDate), '') AS DATE)            AS entry_date,
        NULLIF(TRIM(endDate), '')                                AS raw_end_date,
        -- District B's endDate IS the last enrolled day (District A's is the day after).
        -- Blank means still enrolled, so use the calendar's last school day.
        COALESCE(TRY_CAST(NULLIF(TRIM(endDate), '') AS DATE),
                 (SELECT MAX(cal_date) FROM ref_calendar WHERE is_school_day)) AS last_enrolled_date,
        CASE
            WHEN NULLIF(TRIM(birthDate), '') IS NULL THEN 'missing birth_date'
            WHEN studentName NOT LIKE '%,%'          THEN 'name format: confirm first/last'
        END                                                      AS dq_flag,
        personID                                                 AS source_person_id
    FROM deduped
)
SELECT
    *,
    CASE
        WHEN NULLIF(local_student_number, '') IS NULL THEN 'Missing student number'
        WHEN school_key IS NULL                       THEN 'Unknown school name'
        -- A filled-in end date that can't be read must not quietly become "still enrolled".
        WHEN entry_date IS NULL
          OR (raw_end_date IS NOT NULL AND TRY_CAST(raw_end_date AS DATE) IS NULL)
                                                      THEN 'Unreadable enrollment dates'
    END AS reject_reason
FROM typed;

INSERT INTO dq_log
SELECT 'B', 'enrollment.csv', reject_reason, COUNT(*), 'excluded (kept in rejected_b_students)',
       CASE reject_reason
           WHEN 'Unknown school name'
               THEN 'These school names are not on our list: ' || string_agg(DISTINCT raw_school_name, ', ')
                    || '. Which school is each one?'
           ELSE 'Student(s) ' || string_agg(local_student_number, ', ') || ' could not be loaded: '
                || lower(reject_reason) || '. Can you resend these records?'
       END
FROM b_students_labeled
WHERE reject_reason IS NOT NULL
GROUP BY reject_reason;

CREATE OR REPLACE TABLE rejected_b_students AS
SELECT * FROM b_students_labeled WHERE reject_reason IS NOT NULL;

CREATE OR REPLACE TABLE clean_b_students AS
SELECT student_key, district, local_student_number, first_name, last_name, birth_date, gender,
       grade_level, school_key, entry_date, last_enrolled_date, dq_flag, source_person_id
FROM b_students_labeled
WHERE reject_reason IS NULL;

DROP TABLE b_students_labeled;

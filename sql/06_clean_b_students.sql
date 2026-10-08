-- =====================================================================
-- 06_clean_b_students.sql  —  TRANSFORM
-- District B enrollment: staging -> clean, in the SAME shape as
-- clean_a_students so the two can be stacked later.
-- =====================================================================

-- District B has no schools file and spells school names inconsistently
-- in its attendance export, so one reusable rule maps any spelling to a
-- school key. strip_accents turns "Piñon" into "Pinon"; the regex removes
-- spaces and punctuation, so "Juniper Canyon MS" -> "junipercanyonms".
CREATE OR REPLACE MACRO b_school_key(school_name) AS
    CASE
        WHEN regexp_replace(lower(strip_accents(school_name)), '[^a-z]', '', 'g') LIKE 'junipercanyon%' THEN 'B-JUNIPER'
        WHEN regexp_replace(lower(strip_accents(school_name)), '[^a-z]', '', 'g') LIKE 'pinonridge%'    THEN 'B-PINON'
    END;

INSERT INTO dq_log
SELECT 'B', 'enrollment.csv', 'Grade level written inconsistently ("06", "6", "Gr 6")', COUNT(*),
       'fixed (converted to a number)', NULL
FROM stg_b_enrollment
WHERE NOT regexp_matches(grade, '^[0-9]{2}$');

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

CREATE OR REPLACE TABLE clean_b_students AS
WITH deduped AS (
    SELECT DISTINCT * FROM stg_b_enrollment
)
SELECT
    'B-' || studentNumber                                    AS student_key,
    'B'                                                      AS district,
    studentNumber                                            AS local_student_number,
    -- "Garcia, Sofia" -> first = after the comma. Without a comma, assume "Sofia Garcia".
    CASE WHEN studentName LIKE '%,%' THEN TRIM(split_part(studentName, ',', 2))
         ELSE TRIM(split_part(studentName, ' ', 1)) END      AS first_name,
    CASE WHEN studentName LIKE '%,%' THEN TRIM(split_part(studentName, ',', 1))
         ELSE TRIM(substr(studentName, strpos(studentName, ' ') + 1)) END AS last_name,
    TRY_CAST(NULLIF(TRIM(birthDate), '') AS DATE)            AS birth_date,
    CASE gender WHEN 'Female' THEN 'F' WHEN 'Male' THEN 'M' END AS gender,
    TRY_CAST(regexp_extract(grade, '[0-9]+') AS INTEGER)     AS grade_level,   -- "Gr 6" -> 6
    b_school_key(schoolName)                                 AS school_key,
    startDate::DATE                                          AS entry_date,
    -- District B's endDate IS the last enrolled day (District A's is the day after).
    -- Blank means still enrolled, so use the last day of school.
    COALESCE(TRY_CAST(NULLIF(endDate, '') AS DATE), DATE '2026-05-22') AS last_enrolled_date,
    CASE
        WHEN NULLIF(TRIM(birthDate), '') IS NULL THEN 'missing birth_date'
        WHEN studentName NOT LIKE '%,%'          THEN 'name format: confirm first/last'
    END                                                      AS dq_flag,
    personID                                                 AS source_person_id
FROM deduped;

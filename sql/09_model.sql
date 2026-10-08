-- =====================================================================
-- 09_model.sql  —  LOAD
-- Stack both districts into one common model. From here on, nothing
-- downstream needs to know which district a row came from.
--
--   dim_school               one row per school
--   dim_student              one row per student
--   fact_attendance_monthly  one row per student per month
--   fact_course_grade        one row per student per course per semester
-- =====================================================================

CREATE OR REPLACE TABLE dim_school AS
SELECT 'A-' || SchoolID AS school_key, 'A' AS district, 'Mesquite Flats Unified' AS district_name,
       School_Name AS school_name, Low_Grade::INTEGER AS low_grade, High_Grade::INTEGER AS high_grade
FROM stg_a_schools
UNION ALL
SELECT * FROM (VALUES
    ('B-JUNIPER', 'B', 'Piñon Ridge School District', 'Juniper Canyon Middle School', 6, 8),
    ('B-PINON',   'B', 'Piñon Ridge School District', 'Piñon Ridge High School',      9, 12)
);

-- UNION ALL stacks rows; the column lists must line up exactly.
CREATE OR REPLACE TABLE dim_student AS
SELECT student_key, district, local_student_number, first_name, last_name, birth_date, gender,
       grade_level, school_key, entry_date, last_enrolled_date, dq_flag
FROM clean_a_students
UNION ALL
SELECT student_key, district, local_student_number, first_name, last_name, birth_date, gender,
       grade_level, school_key, entry_date, last_enrolled_date, dq_flag
FROM clean_b_students;

-- District A is daily, so roll it up to months to match District B.
-- Suspensions (S) go into unexcused, matching how District B reports them.
CREATE OR REPLACE TABLE fact_attendance_monthly AS
SELECT
    a.student_key,
    s.school_key,
    strftime(a.att_date, '%Y-%m')                              AS month,
    COUNT(*)                                                   AS days_enrolled,
    SUM(CASE WHEN a.att_code = 'E' THEN 1 ELSE 0 END)          AS days_absent_excused,
    SUM(CASE WHEN a.att_code IN ('A', 'S') THEN 1 ELSE 0 END)  AS days_absent_unexcused,
    NULL::VARCHAR                                              AS dq_flag
FROM clean_a_attendance a
JOIN dim_student s ON s.student_key = a.student_key
GROUP BY a.student_key, s.school_key, strftime(a.att_date, '%Y-%m')
UNION ALL
SELECT student_key, school_key, month, days_enrolled, days_absent_excused, days_absent_unexcused, dq_flag
FROM clean_b_attendance;

CREATE OR REPLACE TABLE fact_course_grade AS
SELECT * FROM clean_a_grades
UNION ALL BY NAME            -- DuckDB: match columns by name instead of position
SELECT * FROM clean_b_grades;

-- Student numbers are only unique within a district. Prefixing keys with
-- the district ("A-123456" vs "B-123456") keeps different kids apart.
INSERT INTO dq_log
SELECT 'A+B', 'students.csv / enrollment.csv', 'Same student number used in both districts (different students)',
       COUNT(*), 'handled (keys include a district prefix)', NULL
FROM clean_a_students a
JOIN clean_b_students b ON a.local_student_number = b.local_student_number;

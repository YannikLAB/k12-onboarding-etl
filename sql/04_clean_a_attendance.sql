-- =====================================================================
-- 04_clean_a_attendance.sql  —  TRANSFORM
-- District A daily attendance: staging -> clean.
-- Pattern: label every row with a reject reason (or NULL if it's fine),
-- log the counts, then split into clean_ and rejected_ tables.
-- Nothing is silently dropped: every raw row ends up in exactly one place.
-- =====================================================================

-- Lowercase codes ("a" vs "A") are fixable, so log and fix rather than reject.
INSERT INTO dq_log
SELECT 'A', 'attendance.csv', 'Attendance codes in lowercase ("a" instead of "A")', COUNT(*),
       'fixed (converted to uppercase)', NULL
FROM stg_a_attendance
WHERE Att_Code <> UPPER(Att_Code);

CREATE OR REPLACE TABLE a_attendance_checked AS
WITH typed AS (
    SELECT
        Student_Number                              AS local_student_number,
        strptime(Att_Date, '%m/%d/%Y')::DATE        AS att_date,
        UPPER(TRIM(Att_Code))                       AS att_code
    FROM stg_a_attendance
)
SELECT
    t.local_student_number,
    s.student_key,
    t.att_date,
    t.att_code,
    -- First matching reason wins, so order matters: no student -> no school -> not enrolled.
    CASE
        WHEN s.student_key IS NULL                  THEN 'Student not in students.csv'
        WHEN c.is_school_day IS NOT TRUE            THEN 'Recorded on a non-school day'
        WHEN t.att_date < s.entry_date
          OR t.att_date > s.last_enrolled_date      THEN 'Recorded outside enrollment dates'
        WHEN t.att_code NOT IN ('P', 'T', 'E', 'A', 'S') THEN 'Unknown attendance code'
    END                                             AS reject_reason
FROM typed t
LEFT JOIN clean_a_students s ON s.local_student_number = t.local_student_number   -- LEFT JOIN keeps orphans visible
LEFT JOIN ref_calendar     c ON c.cal_date = t.att_date;

-- One log row per kind of problem, with the evidence in the question.
INSERT INTO dq_log
SELECT
    'A', 'attendance.csv', reject_reason, COUNT(*), 'excluded (kept in rejected_a_attendance)',
    CASE reject_reason
        WHEN 'Student not in students.csv'
            THEN 'Attendance exists for student(s) ' || string_agg(DISTINCT local_student_number, ', ')
                 || ' but there is no enrollment record. Is an enrollment missing?'
        WHEN 'Recorded on a non-school day'
            THEN 'Attendance was recorded on ' || string_agg(DISTINCT strftime(att_date, '%m/%d/%Y'), ', ')
                 || ', which your calendar lists as no school. Entry error?'
        WHEN 'Recorded outside enrollment dates'
            THEN 'Absences were recorded after student(s) ' || string_agg(DISTINCT local_student_number, ', ')
                 || ' withdrew. Did they re-enroll, or should these be removed?'
    END
FROM a_attendance_checked
WHERE reject_reason IS NOT NULL
GROUP BY reject_reason;

CREATE OR REPLACE TABLE rejected_a_attendance AS
SELECT * FROM a_attendance_checked WHERE reject_reason IS NOT NULL;

CREATE OR REPLACE TABLE clean_a_attendance AS
SELECT student_key, att_date, att_code
FROM a_attendance_checked
WHERE reject_reason IS NULL;

DROP TABLE a_attendance_checked;

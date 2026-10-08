-- =====================================================================
-- 10_business_rules.sql  —  BUSINESS RULES (as views)
-- Each rule from the README, written so it can be read top to bottom.
-- Views recalculate whenever they're queried, so they always reflect
-- the latest load.
-- =====================================================================

-- Totals per student for the whole year.
CREATE OR REPLACE VIEW v_student_attendance AS
SELECT
    student_key,
    SUM(days_enrolled)                                        AS days_enrolled,
    SUM(days_absent_excused + days_absent_unexcused)          AS days_absent,
    SUM(days_absent_excused)                                  AS days_absent_excused,
    SUM(days_absent_unexcused)                                AS days_absent_unexcused,
    ROUND(SUM(days_absent_excused + days_absent_unexcused) * 100.0
          / NULLIF(SUM(days_enrolled), 0), 1)                 AS absence_rate_pct,
    BOOL_OR(dq_flag IS NOT NULL)                              AS needs_review
FROM fact_attendance_monthly
GROUP BY student_key;

-- RULE 1: Chronic absenteeism = absent on 10% or more of enrolled days.
-- Excused, unexcused and suspension days all count; tardies don't.
-- Students enrolled fewer than 10 days are excluded.
-- Three possible answers, on purpose: TRUE, FALSE, or NULL (= we can't say).
--
-- attendance_band is the single source of truth for attendance. Both the
-- staff rule (is_chronically_absent) and the family report read it, so
-- they can never disagree. 'at risk' (5% to under 10%) is only used to
-- choose the wording of family messages; it is not a state category.
CREATE OR REPLACE VIEW v_chronic_absenteeism AS
WITH base AS (
    SELECT
        st.student_key,
        COALESCE(a.days_enrolled, 0)          AS days_enrolled,
        COALESCE(a.days_absent, 0)            AS days_absent,
        a.absence_rate_pct,
        COALESCE(a.needs_review, FALSE)       AS attendance_needs_review
    FROM dim_student st
    LEFT JOIN v_student_attendance a ON a.student_key = st.student_key
),
banded AS (
    SELECT
        *,
        -- 0.10 and 0.05 are exact decimals in DuckDB, so a student at exactly
        -- 10% (e.g. 18 of 180 days) is compared without floating-point rounding.
        CASE
            WHEN attendance_needs_review                 THEN 'needs review'   -- bad source data: don't guess
            WHEN days_enrolled = 0                       THEN 'no data'
            WHEN days_enrolled < 10                      THEN 'too few days'   -- not enough days to judge
            WHEN days_absent >= 0.10 * days_enrolled     THEN 'chronic'
            WHEN days_absent >= 0.05 * days_enrolled     THEN 'at risk'
            ELSE 'good'
        END AS attendance_band
    FROM base
)
SELECT
    student_key,
    days_enrolled,
    days_absent,
    absence_rate_pct,
    days_enrolled >= 10                                   AS is_eligible,
    CASE attendance_band
        WHEN 'chronic' THEN TRUE
        WHEN 'at risk' THEN FALSE
        WHEN 'good'    THEN FALSE
    END                                                   AS is_chronically_absent,   -- NULL for the other bands
    attendance_needs_review,
    attendance_band
FROM banded;

-- RULE 2: Core course failure = an F in English, Math, Science or Social
-- Studies in either semester. Withdrawn and not-yet-posted grades don't count.
CREATE OR REPLACE VIEW v_core_course_failures AS
SELECT
    st.student_key,
    COUNT(g.course_code)                                      AS core_failures,
    string_agg(g.course_name || ' (' || g.term || ')', ', ' ORDER BY g.term, g.course_name) AS failed_courses
FROM dim_student st
LEFT JOIN fact_course_grade g
       ON g.student_key = st.student_key
      AND g.is_core
      AND g.letter_grade = 'F'      -- in the ON clause so students with zero failures stay in the list
GROUP BY st.student_key;

-- RULE 3: Early warning status.
--   On Track = neither indicator, Watch = one, Off Track = both.
--   Needs Review = attendance data is unreliable, so we won't call it either way.
CREATE OR REPLACE VIEW v_early_warning AS
SELECT
    st.student_key,
    st.district,
    st.school_key,
    st.first_name,
    st.last_name,
    st.grade_level,
    ca.days_enrolled,
    ca.days_absent,
    ca.absence_rate_pct,
    ca.is_chronically_absent,
    ca.attendance_band,
    f.core_failures,
    f.failed_courses,
    CASE
        WHEN ca.attendance_needs_review                                     THEN 'Needs Review'
        WHEN COALESCE(ca.is_chronically_absent, FALSE) AND f.core_failures > 0 THEN 'Off Track'
        WHEN COALESCE(ca.is_chronically_absent, FALSE) OR  f.core_failures > 0 THEN 'Watch'
        ELSE 'On Track'
    END AS early_warning_status
FROM dim_student st
JOIN v_chronic_absenteeism  ca ON ca.student_key = st.student_key
JOIN v_core_course_failures f  ON f.student_key  = st.student_key;

-- RULE 4 lives in the clean_ grade tables: every grade is stored as A–F
-- (letter_grade), whatever the district's original format.

-- Summary for district and school staff.
CREATE OR REPLACE VIEW v_school_summary AS
SELECT
    sc.district_name,
    sc.school_name,
    COUNT(*)                                                          AS students,
    COUNT(*) FILTER (WHERE ew.is_chronically_absent)                  AS chronically_absent,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ew.is_chronically_absent)
          / NULLIF(COUNT(ew.is_chronically_absent), 0), 1)            AS chronic_absence_rate_pct,  -- denominator skips NULLs
    COUNT(*) FILTER (WHERE ew.core_failures > 0)                      AS failed_a_core_course,
    COUNT(*) FILTER (WHERE ew.early_warning_status = 'On Track')      AS on_track,
    COUNT(*) FILTER (WHERE ew.early_warning_status = 'Watch')         AS watch,
    COUNT(*) FILTER (WHERE ew.early_warning_status = 'Off Track')     AS off_track,
    COUNT(*) FILTER (WHERE ew.early_warning_status = 'Needs Review')  AS needs_review
FROM v_early_warning ew
JOIN dim_school sc ON sc.school_key = ew.school_key
GROUP BY sc.district_name, sc.school_name
ORDER BY sc.district_name, sc.school_name;

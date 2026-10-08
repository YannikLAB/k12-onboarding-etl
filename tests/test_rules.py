"""Business rules and cleaning, tested on tiny hand-made datasets.

Most of these cases never occur in the sample data, so before this suite
existed, the code paths behind them had never actually run.
"""
from datetime import date

from conftest import A, B, Data


def attendance(con, key):
    return con.execute("""SELECT is_chronically_absent, attendance_band, days_enrolled, days_absent
                          FROM v_chronic_absenteeism WHERE student_key = ?""", [key]).fetchone()


def status(con, key):
    return con.execute("SELECT early_warning_status FROM v_early_warning WHERE student_key = ?",
                       [key]).fetchone()[0]


# ---------------------------------------------------------------- chronic absenteeism

def test_exactly_ten_percent_absent_is_chronic(run):
    d = Data()
    d.add_a_student("100002", n_days=20, absences=2)                 # 2 / 20 = exactly 10%
    assert attendance(run(d), "A-100002")[:2] == (True, "chronic")


def test_just_under_ten_percent_is_not_chronic(run):
    d = Data()
    d.add_a_student("100002", n_days=21, absences=2)                 # 2 / 21 = 9.5%
    assert attendance(run(d), "A-100002")[:2] == (False, "at risk")


def test_fewer_than_ten_days_enrolled_is_not_judged(run):
    d = Data()
    d.add_a_student("100002", n_days=8, absences=4)                  # 50%, but only 8 days
    con = run(d)
    assert attendance(con, "A-100002")[:2] == (None, "too few days")
    assert status(con, "A-100002") == "On Track"                     # attendance can't push them to Watch


def test_tardies_count_as_present_and_suspensions_as_absent(run):
    d = Data()
    d.add_a_student("100002", n_days=20, codes=["T"] * 10 + ["S"] * 2 + ["P"] * 8)
    assert attendance(run(d), "A-100002") == (True, "chronic", 20, 2)


def test_lowercase_attendance_codes_are_fixed_and_logged(run):
    d = Data()
    d.add_a_student("100002", n_days=20, codes=["a", "e"] + ["p"] * 18)
    con = run(d)
    assert attendance(con, "A-100002")[3] == 2
    assert con.execute("SELECT rows_affected FROM dq_log WHERE issue LIKE 'Attendance codes in lowercase%'").fetchone() == (20,)


def test_impossible_month_means_needs_review_not_a_guess(run):
    d = Data()
    d.add_b_student("200002", months=[("2025-09", 21, 0, 24), ("2025-10", 21, 0, 0)])
    con = run(d)
    assert attendance(con, "B-200002")[:2] == (None, "needs review")
    assert status(con, "B-200002") == "Needs Review"


# ---------------------------------------------------------------- bad input doesn't crash the run

def test_unreadable_attendance_date_is_rejected_not_a_crash(run):
    d = Data()
    d.add_a_student("100002", n_days=20)
    d.add_row(f"{A}/attendance.csv", "100002,101,13/45/2025,A")
    con = run(d)                                                     # used to raise InvalidInputException
    assert con.execute("SELECT reject_reason FROM rejected_a_attendance").fetchall() == [("Unreadable date",)]
    assert attendance(con, "A-100002")[2] == 20
    question = con.execute("SELECT question_for_district FROM dq_log WHERE issue = 'Unreadable date'").fetchone()[0]
    assert "13/45/2025" in question


def test_student_with_unreadable_enrollment_date_is_rejected_and_rows_say_why(run):
    d = Data()
    d.add_a_student("100003", n_days=20, entry="soon")
    con = run(d)
    assert con.execute("SELECT reject_reason FROM rejected_a_students").fetchall() == [("Unreadable enrollment dates",)]
    reasons = con.execute("SELECT DISTINCT reject_reason FROM rejected_a_attendance").fetchall()
    assert reasons == [("Student record was rejected",)]
    assert con.execute("SELECT COUNT(*) FROM dim_student WHERE student_key = 'A-100003'").fetchone() == (0,)


def test_unreadable_b_end_date_is_rejected_not_treated_as_still_enrolled(run):
    d = Data()
    d.add_b_student("200002", end="sometime")
    con = run(d)
    assert con.execute("SELECT reject_reason FROM rejected_b_students").fetchall() == [("Unreadable enrollment dates",)]


# ---------------------------------------------------------------- matching and keys

def test_unknown_school_name_is_rejected_not_guessed(run):
    d = Data()
    d.add_b_student("200002", school="Pinon Ridge Elementary")       # used to be mapped to the high school
    con = run(d)
    assert con.execute("SELECT reject_reason FROM rejected_b_students").fetchall() == [("Unknown school name",)]
    assert con.execute("SELECT reject_reason FROM rejected_b_attendance").fetchall() == [("Student record was rejected",)]


def test_every_known_school_spelling_maps_to_the_right_school(run):
    con = run(Data())
    for name, key in [("Juniper Canyon Middle School", "B-JUNIPER"), ("Juniper Canyon MS", "B-JUNIPER"),
                      ("JUNIPER CANYON MIDDLE SCHOOL", "B-JUNIPER"), ("Pinon Ridge High School", "B-PINON"),
                      ("Piñon Ridge High School", "B-PINON"), ("  Pinon  Ridge HS ", "B-PINON")]:
        assert con.execute("SELECT b_school_key(?)", [name]).fetchone()[0] == key, name


def test_same_student_number_in_both_districts_stays_two_students(run):
    d = Data()
    d.add_a_student("300001")
    d.add_b_student("300001")
    con = run(d)
    keys = con.execute("SELECT student_key FROM dim_student WHERE local_student_number = '300001' ORDER BY 1").fetchall()
    assert keys == [("A-300001",), ("B-300001",)]


def test_duplicate_student_is_kept_once_and_attendance_not_double_counted(run):
    d = Data()
    d.add_a_student("100002", n_days=20)
    d.add_row(f"{A}/students.csv", d.files[f"{A}/students.csv"][-1].replace("03/14/2012", "03/17/2012"))
    con = run(d)
    assert con.execute("SELECT dq_flag FROM dim_student WHERE student_key = 'A-100002'").fetchall() == [
        ("conflicting student records",)]
    assert attendance(con, "A-100002")[2] == 20                     # not 40


def test_end_dates_follow_each_districts_convention(run):
    d = Data()
    days = d.add_a_student("100002", n_days=20)                      # A: ExitDate = day after the last day
    d.add_b_student("200002", end="2025-09-30")                      # B: endDate = the last day itself
    con = run(d)
    last = dict(con.execute("SELECT student_key, last_enrolled_date FROM dim_student").fetchall())
    assert last["A-100002"] == days[-1]
    assert last["B-200002"] == date(2025, 9, 30)


# ---------------------------------------------------------------- grades

def test_only_an_f_in_a_core_class_counts_as_a_core_failure(run):
    d = Data()
    for number, row in [("100010", "ART07,Art,S1,F,0"),             # elective F: not a core failure
                        ("100011", "MATH07,Math 7,S2,,"),            # blank: not posted, not an F
                        ("100012", "ENG07,English 7,S1,F,0")]:       # core F: counts
        d.add_a_student(number)
        d.add_row(f"{A}/stored_grades.csv", f"{number},101,{row}")
    con = run(d)
    failures = dict(con.execute("SELECT student_key, core_failures FROM v_core_course_failures").fetchall())
    assert (failures["A-100010"], failures["A-100011"], failures["A-100012"]) == (0, 0, 1)
    assert con.execute("SELECT grade_status FROM fact_course_grade WHERE student_key = 'A-100011'").fetchone() == (
        "not posted",)


def test_b_scores_use_the_districts_scale_and_extra_credit_is_an_a(run):
    d = Data()
    for score in ["104.0", "60.0", "59.9", ""]:
        d.add_row(f"{B}/grades.csv", f"200001,SCI-7,Science 7,Sem 2,{score},")
    con = run(d)
    got = con.execute("""SELECT score_percent, letter_grade, grade_status FROM fact_course_grade
                         WHERE course_code = 'SCI-7' ORDER BY score_percent DESC NULLS LAST""").fetchall()
    assert got == [(104.0, "A", "graded"), (60.0, "D", "graded"), (59.9, "F", "graded"), (None, None, "not posted")]

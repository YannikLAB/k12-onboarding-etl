"""The family report: wording for each attendance band, and safety."""
from datetime import date

import pytest

import build_reports as br
from conftest import Data

YEAR = {"first_day": date(2025, 8, 11), "last_day": date(2026, 5, 22), "school_days": 182,
        "months": [(f"2025-{m:02d}", "S1") for m in range(8, 13)] + [(f"2026-{m:02d}", "S2") for m in range(1, 6)]}

ALARM = "1 in every 10 school days. Students who miss this much"
ATTENDANCE_HELP = "hard to get to school"


def student(**changes):
    s = {"first_name": "Sam", "school_name": "Red Mesa Middle School", "grade_level": 7,
         "attendance_band": "good", "days_enrolled": 182, "days_absent": 3, "excused": 3, "unexcused": 0,
         "months": {"2025-09": (21, 3)}, "grades": [("English 7", True, "B", "B")],
         "entry_date": date(2025, 8, 11), "last_enrolled_date": date(2026, 5, 22)}
    s.update(changes)
    return s


def test_student_with_no_attendance_records_gets_a_neutral_message():
    html = br.render(student(attendance_band="no data", days_enrolled=0, days_absent=0, months={}), YEAR)
    assert "No attendance records yet" in html
    assert "0 of the 0 days" not in html                             # the old bug
    assert ALARM not in html and ATTENDANCE_HELP not in html


def test_too_few_days_is_not_alarming_even_at_a_high_rate():
    html = br.render(student(attendance_band="too few days", days_enrolled=5, days_absent=2), YEAR)
    assert "too few days to say much" in html
    assert ALARM not in html and ATTENDANCE_HELP not in html


@pytest.mark.parametrize("band, words", [
    ("good", "strong attendance"),
    ("at risk", "stayed below that"),
    ("chronic", ALARM),
    ("needs review", "being double-checked"),
])
def test_each_attendance_band_gets_its_own_message(band, words):
    assert words in br.render(student(attendance_band=band), YEAR)


def test_attendance_help_appears_only_for_chronic_absence():
    assert ATTENDANCE_HELP in br.render(student(attendance_band="chronic"), YEAR)
    assert ATTENDANCE_HELP not in br.render(student(attendance_band="at risk"), YEAR)


def test_report_follows_the_sql_rule_end_to_end(run):
    """The report used to redo the math in Python. A student with 4 absences in
    8 days got the alarming message even though the staff rule doesn't judge them."""
    d = Data()
    d.add_a_student("100002", n_days=8, absences=4)
    con = run(d)
    html = br.render(br.load_student(con, "A-100002"), br.load_school_year(con))
    assert "too few days to say much" in html
    assert ALARM not in html


def test_every_failed_class_is_named_not_only_core_classes():
    grades = [("English 7", True, "F", "D"), ("Band", False, "F", "F"), ("Math 7", True, "C", "C")]
    assert "didn't pass English 7 and Band" in br.render(student(grades=grades), YEAR)


def test_hostile_text_is_escaped():
    html = br.render(student(first_name="<script>alert(1)</script>",
                             grades=[("<img src=x onerror=alert(1)>", True, "A", "A")]), YEAR)
    assert "<script>" not in html and "<img src=x" not in html


def test_year_grid_puts_fall_and_spring_on_separate_rows():
    assert br.render(student(), YEAR).count('<div class="break">') == 1

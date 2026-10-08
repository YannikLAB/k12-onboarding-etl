"""Shared helpers for the test suite.

Each test builds a tiny, hand-made dataset (a few students) in a temporary
folder, runs the project's real SQL files against it in an in-memory
database, and checks the result. Nothing touches data/processed/.
"""
import sys
from datetime import timedelta
from pathlib import Path

import duckdb
import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))          # so tests can `import build_reports`
SQL_FILES = sorted((REPO / "sql").glob("*.sql"))

A = "data/raw/district_a_mesquite_flats"
B = "data/raw/district_b_pinon_ridge"
HEADERS = {
    f"{A}/schools.csv": "SchoolID,School_Name,Low_Grade,High_Grade",
    f"{A}/students.csv": "Student_Number,Last_Name,First_Name,DOB,Gender,Grade_Level,SchoolID,EntryDate,ExitDate,Enroll_Status",
    f"{A}/attendance.csv": "Student_Number,SchoolID,Att_Date,Att_Code",
    f"{A}/stored_grades.csv": "Student_Number,SchoolID,Course_Number,Course_Name,StoreCode,Grade,EarnedCrHrs",
    f"{B}/enrollment.csv": "personID,studentNumber,studentName,birthDate,gender,grade,schoolName,startDate,endDate",
    f"{B}/attendance_monthly.csv": "studentNumber,schoolName,month,daysEnrolled,daysAbsentExcused,daysAbsentUnexcused",
    f"{B}/grades.csv": "studentNumber,courseCode,courseName,term,score,creditsEarned",
}


def _school_days():
    con = duckdb.connect()
    con.execute((REPO / "sql" / "03_ref_calendar.sql").read_text())
    return [r[0] for r in con.execute(
        "SELECT cal_date FROM ref_calendar WHERE is_school_day ORDER BY cal_date").fetchall()]


SCHOOL_DAYS = _school_days()            # the 182 school days of 2025-26, from the project's own calendar


def us(d):
    return d.strftime("%m/%d/%Y")


class Data:
    """A tiny two-district dataset. Starts with one healthy student per
    district (so no file is empty); tests add the cases they care about."""

    def __init__(self):
        self.files = {path: [] for path in HEADERS}
        self.files[f"{A}/schools.csv"].append("101,Red Mesa Middle School,6,8")
        self.add_a_student("100001", n_days=20)
        self.add_row(f"{A}/stored_grades.csv", "100001,101,ENG07,English 7,S1,B,0")
        self.add_b_student("200001")
        self.add_row(f"{B}/grades.csv", "200001,ENG-7,English 7,Sem 1,85.0,")

    def add_row(self, path, row):
        self.files[path].append(row)

    def add_a_student(self, number, n_days=20, absences=0, codes=None, start=0, dob="03/14/2012",
                      entry=None, exit_date=None):
        """A District A student enrolled for n_days school days, with daily attendance."""
        days = SCHOOL_DAYS[start:start + n_days]
        entry = entry or us(days[0])
        exit_date = exit_date or us(days[-1] + timedelta(days=1))     # A's ExitDate = first day NOT enrolled
        self.add_row(f"{A}/students.csv", f"{number},Lee,Sam,{dob},M,7,101,{entry},{exit_date},2")
        codes = codes or ["A"] * absences + ["P"] * (n_days - absences)
        for d, code in zip(days, codes, strict=True):
            self.add_row(f"{A}/attendance.csv", f"{number},101,{us(d)},{code}")
        return days

    def add_b_student(self, number, school="Juniper Canyon Middle School", months=(("2025-09", 21, 0, 0),),
                      start="2025-08-11", end=""):
        """A District B student with monthly attendance rows: (month, enrolled, excused, unexcused)."""
        self.add_row(f"{B}/enrollment.csv",
                     f'9{number},{number},"Kim, Ana",2012-05-01,Female,07,{school},{start},{end}')
        for month, enrolled, excused, unexcused in months:
            self.add_row(f"{B}/attendance_monthly.csv", f"{number},{school},{month},{enrolled},{excused},{unexcused}")


def run_sql(con, patch=None):
    """Run every project SQL file in order. `patch` = {filename: (old, new)} to break a file on purpose."""
    for f in SQL_FILES:
        sql = f.read_text()
        if patch and f.name in patch:
            old, new = patch[f.name]
            assert old in sql, f"patch target not found in {f.name}"
            sql = sql.replace(old, new)
        con.execute(sql)
    return con


@pytest.fixture
def run(tmp_path, monkeypatch):
    """run(data) -> an in-memory DuckDB connection after the full pipeline ran on `data`."""
    def _run(data, patch=None):
        for rel, rows in data.files.items():
            path = tmp_path / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join([HEADERS[rel], *rows]) + "\n")
        monkeypatch.chdir(tmp_path)
        return run_sql(duckdb.connect(), patch)
    return _run


@pytest.fixture
def run_sample(monkeypatch):
    """Run the pipeline on the real sample data in data/raw/, in memory."""
    def _run(patch=None):
        monkeypatch.chdir(REPO)
        return run_sql(duckdb.connect(), patch)
    return _run

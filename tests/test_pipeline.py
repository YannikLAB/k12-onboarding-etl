"""Whole-pipeline tests on the real sample data in data/raw/."""
import shutil
import subprocess
import sys

from conftest import REPO

BREAK_DEDUPE = {"02_clean_a_students.sql": ("WHERE row_num = 1;", "WHERE row_num >= 1;")}


def failing_checks(con):
    return {name for name, problems in con.execute("SELECT check_name, problems FROM validation_results").fetchall()
            if problems != 0}


def test_sample_data_passes_every_check_and_gives_the_known_results(run_sample):
    con = run_sample()
    assert failing_checks(con) == set()
    assert con.execute("SELECT COUNT(*) FROM dq_log").fetchone() == (17,)
    by_district = dict(((d, (c, f)) for d, c, f in con.execute("""
        SELECT district,
               COUNT(*) FILTER (WHERE is_chronically_absent),
               COUNT(*) FILTER (WHERE core_failures > 0)
        FROM v_early_warning GROUP BY district""").fetchall()))
    assert by_district == {"A": (25, 26), "B": (31, 28)}


def test_checks_catch_a_reintroduced_duplicate_student(run_sample):
    """The README's "test the tests" experiment, automated."""
    con = run_sample(patch=BREAK_DEDUPE)
    failed = failing_checks(con)
    assert "One row per student in dim_student" in failed
    assert "District A: days enrolled match the school calendar" in failed
    # The blind spot worth remembering: GROUP BY hides the duplicate in the
    # monthly table, which still has one row per student per month...
    assert "One row per student per month in attendance" not in failed
    # ...while the totals inside it are four times too big.
    days = con.execute("SELECT SUM(days_enrolled) FROM fact_attendance_monthly WHERE student_key = 'A-131384'").fetchone()
    assert days == (728,)


def test_pipeline_exports_nothing_when_a_check_fails(tmp_path):
    for item in ["sql", "data/raw"]:
        shutil.copytree(REPO / item, tmp_path / item)
    shutil.copy(REPO / "run_pipeline.py", tmp_path)
    broken = tmp_path / "sql" / "02_clean_a_students.sql"
    old, new = BREAK_DEDUPE["02_clean_a_students.sql"]
    broken.write_text(broken.read_text().replace(old, new))

    result = subprocess.run([sys.executable, "run_pipeline.py"], cwd=tmp_path, capture_output=True, text=True)

    assert result.returncode == 1
    assert "FAILED" in result.stderr
    assert not (tmp_path / "reports" / "dq_log.csv").exists()
    assert not (tmp_path / "reports" / "school_summary.csv").exists()

"""Run the full pipeline: every SQL file in sql/ in filename order, then
print the data quality log and validation checks, and export the results.

Usage (from the project root):  python run_pipeline.py
"""
import sys
from pathlib import Path
import duckdb

DB_PATH = Path("data/processed/k12.duckdb")
SQL_DIR = Path("sql")
REPORTS = Path("reports")

DB_PATH.parent.mkdir(parents=True, exist_ok=True)
REPORTS.mkdir(exist_ok=True)
DB_PATH.unlink(missing_ok=True)          # rebuild from scratch every run
con = duckdb.connect(str(DB_PATH))

for sql_file in sorted(SQL_DIR.glob("*.sql")):
    print(f"Running {sql_file.name}")
    con.execute(sql_file.read_text())

print("\nDATA QUALITY LOG")
con.sql("SELECT district, source_file, issue, rows_affected, action_taken FROM dq_log").show(max_width=250)

print("\nVALIDATION CHECKS")
con.sql("""SELECT CASE WHEN problems = 0 THEN 'PASS' ELSE 'FAIL' END AS result, check_name, problems
           FROM validation_results""").show(max_width=250)

failed = con.sql("SELECT COUNT(*) FROM validation_results WHERE problems <> 0").fetchone()[0]
if failed:
    con.close()
    sys.exit(f"\n{failed} validation check(s) FAILED. Nothing exported. Fix before using these numbers.")

con.execute(f"COPY dq_log TO '{REPORTS}/dq_log.csv' (HEADER)")
con.execute(f"COPY (SELECT * FROM v_school_summary) TO '{REPORTS}/school_summary.csv' (HEADER)")
con.close()
print(f"\nAll validation checks passed. Exported {REPORTS}/dq_log.csv and {REPORTS}/school_summary.csv")

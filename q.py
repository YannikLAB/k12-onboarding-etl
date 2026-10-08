"""Quick query runner for testing SQL while you work.

Usage (from the project root):
    python q.py my_queries.sql                      run the queries in a .sql file
    python q.py "SELECT * FROM dq_log"              run a query typed inline

Opens the database read-only, so it can't change anything.
Run `python run_pipeline.py` first so the database exists.
"""
import sys
from pathlib import Path
import duckdb

DB_PATH = "data/processed/k12.duckdb"

if len(sys.argv) < 2:
    sys.exit(__doc__)

arg = sys.argv[1]
sql = Path(arg).read_text() if arg.endswith(".sql") else arg

if not Path(DB_PATH).exists():
    sys.exit("No database yet. Run:  python run_pipeline.py")

con = duckdb.connect(DB_PATH, read_only=True)
# Run each statement separately so every query's results get printed.
for statement in sql.split(";"):
    code_lines = [line for line in statement.splitlines() if line.strip() and not line.strip().startswith("--")]
    if not code_lines:
        continue  # skip blanks and comment-only chunks
    print(f"\n>>> {code_lines[0].strip()}{' ...' if len(code_lines) > 1 else ''}")
    con.sql(statement).show(max_rows=50, max_width=250)
con.close()

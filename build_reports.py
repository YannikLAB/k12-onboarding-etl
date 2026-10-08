"""Build plain-language, one-page reports for families.

Usage (from the project root, after run_pipeline.py):
    python build_reports.py                 sample reports (one per status)
    python build_reports.py A-112752        one specific student

Each report is a single self-contained HTML file in reports/parent_reports/.
Families never see staff labels like "Off Track". They see what happened
and what would help, in everyday words.

All attendance judgments come from SQL (v_chronic_absenteeism.attendance_band),
so the family report and the staff rule can never disagree. This file only
chooses the wording.
"""
import base64
import calendar
import html
import sys
from pathlib import Path

import duckdb

DB_PATH = "data/processed/k12.duckdb"
OUT_DIR = Path("reports/parent_reports")
FONT_DIR = Path(__file__).resolve().parent / "assets" / "fonts"   # next to this script, from any folder

GRADE_WORDS = {"A": "Excellent", "B": "Good", "C": "Fair", "D": "Passing, but struggling", "F": "Not passing"}

# One sample per staff status, so the README can show each kind of message.
SAMPLES = ["A-112752",   # misses school often AND failed a class   (staff: Off Track)
           "B-108491",   # misses school often, grades fine         (staff: Watch)
           "A-100166",   # doing well                               (staff: On Track)
           "B-132692"]   # attendance data needs checking           (staff: Needs Review)


# ---------------------------------------------------------------- data

def load_school_year(con):
    """First and last school day, and the months of the year with their semester."""
    first_day, last_day, school_days = con.execute(
        "SELECT MIN(cal_date), MAX(cal_date), COUNT(*) FROM ref_calendar WHERE is_school_day").fetchone()
    months = con.execute("""
        SELECT month, MIN(semester) FROM ref_calendar
        WHERE is_school_day GROUP BY month ORDER BY month""").fetchall()
    return {"first_day": first_day, "last_day": last_day, "school_days": school_days, "months": months}


def load_student(con, key):
    row = con.execute("""
        SELECT ew.*, sc.school_name, ds.entry_date, ds.last_enrolled_date
        FROM v_early_warning ew
        JOIN dim_school sc  ON sc.school_key  = ew.school_key
        JOIN dim_student ds ON ds.student_key = ew.student_key
        WHERE ew.student_key = ?""", [key]).fetchone()
    if row is None:
        sys.exit(f"No student with key {key}")
    student = dict(zip([d[0] for d in con.description], row, strict=True))

    monthly = con.execute("""
        SELECT month, days_enrolled, days_absent_excused, days_absent_unexcused
        FROM fact_attendance_monthly WHERE student_key = ?""", [key]).fetchall()
    student["months"] = {m: (enr, ex + un) for m, enr, ex, un in monthly}
    student["excused"] = sum(r[2] for r in monthly)
    student["unexcused"] = sum(r[3] for r in monthly)

    # One row per class, with the fall and spring grade side by side.
    student["grades"] = con.execute("""
        SELECT course_name, is_core,
               MAX(CASE WHEN term = 'S1' THEN COALESCE(letter_grade, grade_status) END) AS fall,
               MAX(CASE WHEN term = 'S2' THEN COALESCE(letter_grade, grade_status) END) AS spring
        FROM fact_course_grade WHERE student_key = ?
        GROUP BY course_name, is_core
        ORDER BY is_core DESC, course_name""", [key]).fetchall()
    return student


# ---------------------------------------------------------------- wording

def nice_date(d):
    return f"{d:%B} {d.day}, {d.year}"


def attendance_message(band, first, school):
    """The sentence under the attendance headline, chosen by the SQL band.
    Returns None for bands that replace the whole section (see attendance_section)."""
    return {
        "good":         f"That's strong attendance. Thank you for getting {first} to school.",
        "at risk":      (f"Missing 1 in every 10 school days makes it much harder to keep up. "
                         f"{first} stayed below that this year. Every day still counts."),
        "chronic":      ("That's more than 1 in every 10 school days. Students who miss this much often fall "
                         "behind, even when every absence has a good reason."),
        "too few days": "That's too few days to say much about attendance yet.",
    }.get(band)


def failed_classes(grades):
    """Every class not passed. Staff rules count only core classes, but families should hear about all."""
    return [name for name, _core, fall, spring in grades if "F" in (fall, spring)]


def join_names(names):
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def help_items(s, first, school):
    items = []
    failed = failed_classes(s["grades"])
    if failed:
        items.append(f"{first} didn't pass {html.escape(join_names(failed))}. Ask {school} how {first} can make "
                     f"{'it' if len(failed) == 1 else 'them'} up, for example with summer school or tutoring.")
    if s["attendance_band"] == "chronic":
        items.append(f"If something makes it hard to get to school, like rides, health, or worries about "
                     f"school itself, let {school} know. They can often help.")
    if not items:
        items.append(f"Keep doing what you're doing. Ask {first} what they enjoyed most this year.")
    return items


# ---------------------------------------------------------------- HTML pieces

def font_face(weight):
    data = base64.b64encode((FONT_DIR / f"atkinson-hyperlegible-latin-{weight}-normal.woff2").read_bytes()).decode()
    return (f"@font-face{{font-family:'Atkinson Hyperlegible';font-weight:{weight};font-display:swap;"
            f"src:url(data:font/woff2;base64,{data}) format('woff2');}}")


def year_grid(months, year):
    """Each month is a small block of squares, one square per school day.
    Missed days are filled first; the squares show how many, not which dates."""
    blocks = []
    for i, (key, semester) in enumerate(year["months"]):
        label = calendar.month_abbr[int(key[5:7])]
        if key not in months:
            blocks.append(f'<div class="month off"><div class="sq-wrap"></div><p>{label}</p></div>')
        else:
            enrolled, absent = months[key]
            squares = '<i class="miss"></i>' * absent + "<i></i>" * max(enrolled - absent, 0)
            blocks.append(f'<div class="month" title="{label}: missed {absent} of {enrolled} days">'
                          f'<div class="sq-wrap">{squares}</div><p>{label}</p></div>')
        next_semester = year["months"][i + 1][1] if i + 1 < len(year["months"]) else semester
        if next_semester != semester:
            blocks.append('<div class="break"></div>')   # fall on one row, spring on the next
    return "".join(blocks)


def attendance_section(s, first, school, year):
    band = s["attendance_band"]
    if band == "needs review":
        return f"""
  <h2>Attendance is being double-checked</h2>
  <p class="lead">Part of {first}'s attendance record doesn't add up, so we're checking it with {school}
  before showing it here. Nothing is needed from you.</p>"""
    if band == "no data":
        return f"""
  <h2>No attendance records yet</h2>
  <p class="lead">We don't have any attendance records for {first} yet. If that seems wrong,
  please let {school} know.</p>"""

    enrolled, absent = int(s["days_enrolled"]), int(s["days_absent"])
    days_phrase = (f"{enrolled} school days" if enrolled >= year["school_days"]
                   else f"the {enrolled} days {first} was enrolled")
    return f"""
  <h2>{first} was at school {enrolled - absent} of {days_phrase}.</h2>
  <p class="lead">{attendance_message(band, first, school)}</p>
  <div class="year" role="img" aria-label="Days missed each month">{year_grid(s["months"], year)}</div>
  <p class="key"><i class="miss"></i> Day missed &nbsp; <i></i> Day at school<br>
  {absent} days missed in all: {s["excused"]} excused, {s["unexcused"]} not excused.
  Arriving late counts as a day at school.</p>"""


def grade_cell(value):
    if value is None:
        return '<td class="g none">—</td>'
    if value == "not posted":
        return '<td class="g none">Not posted yet</td>'
    if value == "withdrawn":
        return '<td class="g none">Left the class</td>'
    cls = "g fail" if value == "F" else "g"
    return f'<td class="{cls}"><b>{value}</b><span>{GRADE_WORDS[value]}</span></td>'


def grades_rows(grades):
    return "".join(f"<tr><th scope='row'>{html.escape(name)}</th>{grade_cell(fall)}{grade_cell(spring)}</tr>"
                   for name, _core, fall, spring in grades)


def enrollment_note(s, year):
    dates = []
    if s["entry_date"] > year["first_day"]:
        dates.append(f"Joined {nice_date(s['entry_date'])}.")
    if s["last_enrolled_date"] < year["last_day"]:
        dates.append(f"Last day enrolled: {nice_date(s['last_enrolled_date'])}.")
    return (". " + " ".join(dates)) if dates else ""


STYLE = """
:root { --ink:#1D2B3A; --soft:#56657A; --paper:#FFFFFF; --day:#D6DEE6; --miss:#E5A50A; --rule:#E3E8ED; --fail:#B42318; }
* { box-sizing:border-box; }
body { margin:0; background:var(--paper); color:var(--ink);
  font:400 18px/1.55 'Atkinson Hyperlegible', 'Segoe UI', Helvetica, Arial, sans-serif; }
main { max-width:680px; margin:0 auto; padding:40px 24px 56px; }
.who { color:var(--soft); margin:0 0 4px; font-size:16px; }
h1 { font-size:clamp(32px, 7vw, 44px); line-height:1.1; margin:0 0 36px; letter-spacing:-0.01em; }
h2 { font-size:24px; line-height:1.25; margin:0 0 8px; }
section { padding:28px 0; border-top:2px solid var(--ink); }
.lead { margin:0 0 24px; max-width:60ch; }
.year, .key { --sq:clamp(8px, 2.3vw, 13px); }
.year { display:flex; flex-wrap:wrap; gap:18px 14px; margin-bottom:16px; }
.break { flex-basis:100%; height:0; }
.sq-wrap { display:grid; grid-template-columns:repeat(5, var(--sq)); gap:3px; align-content:start;
  min-height:calc(var(--sq) * 5 + 12px); }
.month p { margin:6px 0 0; font-size:14px; color:var(--soft); }
.month.off p::after { content:" (not enrolled)"; }
i { display:inline-block; width:var(--sq); height:var(--sq); background:var(--day); border-radius:2px; }
i.miss { background:var(--miss); }
.key { font-size:15px; color:var(--soft); margin:0; }
.key i { vertical-align:-1px; margin-right:4px; }
table { width:100%; border-collapse:collapse; margin-top:12px; }
th, td { text-align:left; padding:10px 8px 10px 0; border-bottom:1px solid var(--rule); vertical-align:top; }
thead th { font-size:15px; color:var(--soft); font-weight:400; }
tbody th { font-weight:400; }
td.g b { display:inline-block; min-width:1.4em; font-size:20px; }
td.g span { display:block; font-size:14px; color:var(--soft); }
td.fail b, td.fail span { color:var(--fail); }
td.none { color:var(--soft); font-size:15px; }
ul { margin:8px 0 0; padding-left:1.2em; }
li { margin-bottom:8px; max-width:60ch; }
footer { border-top:1px solid var(--rule); padding-top:16px; font-size:15px; color:var(--soft); }
@media (max-width:520px) { body { font-size:17px; } main { padding:28px 18px 40px; } }
"""


def render(s, year):
    first, school = html.escape(s["first_name"]), html.escape(s["school_name"])
    span = f"{year['first_day'].year}–{str(year['last_day'].year)[2:]}"
    helps = "".join(f"<li>{item}</li>" for item in help_items(s, first, school))
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{first}'s {span} school year</title>
<style>
{font_face(400)}{font_face(700)}{STYLE}</style></head>
<body><main>
<p class="who">{school}, grade {s["grade_level"]}{enrollment_note(s, year)}</p>
<h1>{first}'s {span} school year</h1>

<section>{attendance_section(s, first, school, year)}
</section>

<section>
  <h2>Final grades</h2>
  <table>
    <thead><tr><th scope="col">Class</th><th scope="col">Fall</th><th scope="col">Spring</th></tr></thead>
    <tbody>{grades_rows(s["grades"])}</tbody>
  </table>
</section>

<section>
  <h2>What would help</h2>
  <ul>{helps}</ul>
</section>

<footer>Questions about this report? Contact {school}.<br>Sample report: the student and school are fictional.</footer>
</main></body></html>"""


def main():
    keys = sys.argv[1:] or SAMPLES
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(DB_PATH, read_only=True)
    year = load_school_year(con)
    for key in keys:
        path = OUT_DIR / f"{key}.html"
        path.write_text(render(load_student(con, key), year), encoding="utf-8")
        print(f"Wrote {path}")
    con.close()


if __name__ == "__main__":
    main()

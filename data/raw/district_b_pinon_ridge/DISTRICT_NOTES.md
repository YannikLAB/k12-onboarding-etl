# Piñon Ridge School District — Data Export Notes

*From: Director of Assessment & Accountability. Exports pulled June 3, 2026, for school year 2025–26.*

Here are the files you requested. Quick guide:

## Files
- `enrollment.csv` — one row per student.
- `attendance_monthly.csv` — attendance summarized by student and month.
- `grades.csv` — final semester scores.

## Conventions
- Dates are **YYYY-MM-DD**.
- `personID` is an internal system ID. Use `studentNumber` to connect the files.
- `endDate` is the **last day the student was enrolled**. Blank means still enrolled at year end.
- `studentName` is formatted "Last, First".

## Attendance
- `daysEnrolled` = instructional days the student was enrolled that month.
- Suspension days are included in `daysAbsentUnexcused`.

## Grades
- Scores are percentages. Our scale: A = 90+, B = 80–89.9, C = 70–79.9, D = 60–69.9, F = below 60.
- Sections a student withdrew from are not included in this export.
- Middle school courses earn no credit; high school courses earn 0.5 credit per semester when passed.
- Core subjects use course code prefixes `ENG`, `MATH`, `SCI`, `SS`.

## Calendar
We follow the same state calendar as other districts in our region: Aug 11, 2025 – May 22, 2026.

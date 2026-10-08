# Mesquite Flats Unified School District — Data Export Notes

*From: District Data Coordinator. Exports pulled June 1, 2026, for school year 2025–26.*

Hi! Attached are our exports from our student information system. A few notes:

## Files
- `schools.csv` — our two schools.
- `students.csv` — one row per student enrollment for the year.
- `attendance.csv` — one row per student per enrolled school day.
- `stored_grades.csv` — final semester grades (S1 and S2).

## Conventions
- All dates are **MM/DD/YYYY**.
- `ExitDate` is the **first day the student is no longer enrolled**. Students still enrolled at year end show `05/23/2026`.
- `Enroll_Status`: `0` = active, `2` = transferred/withdrawn.

## Attendance codes
| Code | Meaning |
|---|---|
| P | Present |
| T | Tardy (counts as present) |
| E | Excused absence |
| A | Unexcused absence |
| S | Out-of-school suspension |

## Grades
- Letter grades with +/− (A+ through D−, F).
- `W` = student withdrew from the course.
- Middle school courses earn no credit. High school courses earn 0.5 credit per semester when passed.
- Core subjects use course number prefixes `ENG`, `MATH`, `SCI`, `SS`.

## School calendar 2025–26
First day: Aug 11, 2025. Last day: May 22, 2026. Semester 1 ends Dec 19, 2025.
No school: Sep 1, Oct 31, Nov 11, Nov 26–28, Dec 22–Jan 2, Jan 19, Feb 16, Mar 23–27.

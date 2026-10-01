# IPEDS Institutional Analytics Warehouse

A SQL Server and Power BI project built on national IPEDS higher ed data, with a Python regression analysis on top. Goal: do what an institutional research office actually does. Pull federal data, clean it, model it, build dashboards people can use, then test a finding with real statistics instead of just eyeballing a chart.

## Stack

SQL Server, Python (pandas, statsmodels), Power BI.

## Data

IPEDS 2025 files: institutional directory (`hd2025`), fall enrollment by distance ed status (`effy2025_dist`), completions by CIP code and award level (`c2025_a`). Raw CSVs get cleaned in Python, loaded into SQL Server staging tables, then turned into three views joined on `UnitID`.

One thing worth knowing about this data: both the enrollment and completions files bury a grand-total row inside themselves. Enrollment's grand total sits at `StudentLevelCode = 1`, alongside its own sub-levels. Completions' grand total sits at `CIPCode = "99"`. Every measure in this project filters to those so nothing gets double-counted. I didn't catch that at first, and it inflated every number on the dashboard until I found it.

## Dashboard pages

**Executive Overview**: enrollment, online enrollment, completions-to-enrollment ratio, and online penetration, nationwide or drilled into one institution. Picking nothing shows the full rollup, picking one institution drills down, same slicer does both jobs.

**Peer Benchmarking & Cohort Analysis**: scatter chart of enrollment against online penetration, colored by institutional type instead of by school name, which is what actually makes the pattern visible. Public, private nonprofit, and private for-profit schools cluster differently. A bar chart next to it shows the average penetration by type directly. The table below adds a completions-to-enrollment ratio per school and flags whether each one runs above or below its type's average.

**Args Map**: national map, bubble size and color by online enrollment and penetration, state checkboxes to filter.

**Completions & Academic Output**: degree completions by gender, by institution.

Page 2 is still blank, not started.

## The regression

The scatter chart suggested institutional type matters more than size for online penetration. I tested that with an OLS regression instead of leaving it as a visual impression.

`CompletionRate ~ OnlinePenetration + IsPrivate + TotalEnrollment`, 3,738 institutions nationwide, HC3 robust standard errors.

Online penetration came back as a significant negative predictor (p < .001). Institutional type was a bigger one: private schools run about 6 points higher completion rate than public, controlling for the rest. Enrollment size wasn't significant once type was in the model. Adjusted R squared landed at 0.118, modest but real, and adding institutional type nearly doubled the model's explanatory power over online penetration alone.

Full write-up with the diagnostics and limitations is in `docs/IPEDS_Project_Journal.md`.

## Bugs I hit and fixed along the way

- Enrollment numbers were inflated because I was summing every student-level code instead of filtering to the grand total row.
- Same issue on completions, caught it because one measure had the right filter and another didn't.
- A KPI card showed 0 on one page and worked fine on another. Turned out to be a filter on that one visual, not the formula.
- A pandas script used a parameter name that got removed in a newer pandas version. Would have crashed on any current setup.
- One institution with 2 total students produced a 350% completion rate and wrecked the regression diagnostics until I added a minimum enrollment cutoff.

## Repo layout

```
/sql          ipeds_build.sql
/python       ipeds_clean.py, ipeds_regression_analysis.py
/powerbi      IPEDS_Analytics.pbix
/screenshots  page screenshots
/docs         IPEDS_Project_Journal.md
```

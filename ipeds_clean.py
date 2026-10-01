"""
================================================================================
PROJECT: IPEDS Data Pipeline for Institutional Research Dashboard
PURPOSE: (1) Clean raw IPEDS CSVs for SQL Server BULK INSERT, same as before.
         (2) NEW: Also build one institution-level analysis CSV — merges all
             three files, applies the same StudentLevelCode=1 / CIPCode="99"
             rules as the DAX measures, and outputs columns ready to drop
             straight into ipeds_regression_analysis.py — no manual Power BI
             export step needed.

Verified against uploaded IPEDS dictionaries (hd2025.xlsx, effy2025_dist.xlsx,
c2025_a.xlsx) on 2026-08-06.
================================================================================
"""

import pandas as pd
import csv
import re

# =============================================================================
# CONFIGURATION
# =============================================================================
RAW_HD_PATH      = r"C:\IPEDS_Data\raw\hd2025.csv"
RAW_COMP_PATH    = r"C:\IPEDS_Data\raw\c2025_a.csv"
RAW_DIST_PATH    = r"C:\IPEDS_Data\raw\effy2025_dist.csv"

OUT_HD           = r"C:\IPEDS_Data\raw\hd2025_clean.csv"
OUT_COMP         = r"C:\IPEDS_Data\raw\c2025_a_clean.csv"
OUT_DIST         = r"C:\IPEDS_Data\raw\effy2025_dist_clean.csv"

# NEW: output for the regression script
OUT_ANALYSIS     = r"C:\IPEDS_Data\raw\institution_level_export.csv"

DELIMITER = '~'
ENCODING  = 'utf-8-sig'

# =============================================================================
# COLUMN SELECTION — confirmed against the uploaded IPEDS dictionaries
# =============================================================================
HD_COLS = ['UNITID', 'INSTNM', 'IALIAS', 'CITY', 'STABBR', 'SECTOR', 'CONTROL',
           'LONGITUD', 'LATITUDE']
COMP_COLS = ['UNITID', 'CIPCODE', 'AWLEVEL', 'CTOTALT', 'CTOTALM', 'CTOTALW']
DIST_COLS = ['UNITID', 'EFFYDLEV', 'EFYDETOT', 'EFYDEEXC', 'EFYDESOM', 'EFYDENON']

# =============================================================================
# CLEANING FUNCTIONS
# =============================================================================
def clean_text(s):
    if pd.isna(s):
        return ''
    s = str(s)
    s = s.replace(',', ' ')
    s = s.replace('\r', ' ').replace('\n', ' ')
    s = s.replace('"', "'")
    s = re.sub(r'\s+', ' ', s)
    return s.strip()

def sanitize_dataframe(df):
    for col in df.select_dtypes(include=['object']).columns:
        df[col] = df[col].apply(clean_text)
    return df

def quality_report(df, name, key_col='UNITID'):
    print(f"--- Data quality: {name} ---")
    print(f"  Rows: {len(df):,}")
    dupes = df[key_col].duplicated().sum()
    if dupes:
        print(f"  [!] {dupes} duplicate {key_col} values (expected if key_col isn't unique per row for this file)")
    nulls = df.isna().sum()
    nulls = nulls[nulls > 0]
    if len(nulls):
        print(f"  [!] Null counts:\n{nulls.to_string()}")
    else:
        print("  No nulls in selected columns.")
    print()

# =============================================================================
# PROCESS FILES — same as before, unchanged
# =============================================================================
print("Processing HD (Institutions)...")
df_hd = pd.read_csv(RAW_HD_PATH, usecols=HD_COLS, dtype=str, engine='python',
                     encoding=ENCODING, quoting=csv.QUOTE_MINIMAL)
df_hd = sanitize_dataframe(df_hd)
quality_report(df_hd, "hd2025", key_col='UNITID')
df_hd.to_csv(OUT_HD, sep=DELIMITER, index=False, encoding='utf-8', lineterminator='\n', quoting=csv.QUOTE_NONE)
print(f"Saved: {OUT_HD}\n")

print("Processing Completions...")
df_comp = pd.read_csv(RAW_COMP_PATH, usecols=COMP_COLS, dtype=str, engine='python',
                       encoding=ENCODING, quoting=csv.QUOTE_MINIMAL)
df_comp = sanitize_dataframe(df_comp)
quality_report(df_comp, "c2025_a", key_col='UNITID')
print(f"  Distinct CIPCODE values: {df_comp['CIPCODE'].nunique()} (should be 1618, incl. '99' grand-total row)")
df_comp.to_csv(OUT_COMP, sep=DELIMITER, index=False, encoding='utf-8', lineterminator='\n', quoting=csv.QUOTE_NONE)
print(f"Saved: {OUT_COMP}\n")

print("Processing Distance Education Enrollment...")
df_dist = pd.read_csv(RAW_DIST_PATH, usecols=DIST_COLS, dtype=str, engine='python',
                       encoding=ENCODING, quoting=csv.QUOTE_MINIMAL)
df_dist = sanitize_dataframe(df_dist)
quality_report(df_dist, "effy2025_dist", key_col='UNITID')
print(f"  Distinct EFFYDLEV values: {sorted(df_dist['EFFYDLEV'].unique())} (should be ['1','2','3','11','12'])")
df_dist.to_csv(OUT_DIST, sep=DELIMITER, index=False, encoding='utf-8', lineterminator='\n', quoting=csv.QUOTE_NONE)
print(f"Saved: {OUT_DIST}\n")

print("All SQL-ready files cleaned, quality-checked, and saved.\n")

# =============================================================================
# NEW STEP: BUILD THE INSTITUTION-LEVEL ANALYSIS EXPORT
# =============================================================================
# Applies the exact same rules as the Power BI DAX measures:
#   - Enrollment figures: filter EFFYDLEV == '1' ("All students total") to
#     avoid the overcounting bug we fixed earlier.
#   - Completions figures: filter CIPCODE == '99' (the grand-total row) to
#     avoid double-counting individual majors.
# Output columns match exactly what ipeds_regression_analysis.py expects:
#   InstitutionName, InstitutionalControl, TotalEnrollment, OnlinePenetration,
#   CompletionRate

print("Building institution-level analysis export...")

# --- Enrollment: one row per institution, StudentLevel = "All students total" ---
dist_totals = df_dist[df_dist['EFFYDLEV'] == '1'].copy()
dist_totals['TotalEnrollment'] = pd.to_numeric(dist_totals['EFYDETOT'], errors='coerce')
dist_totals['OnlineEnrollment'] = pd.to_numeric(dist_totals['EFYDEEXC'], errors='coerce')
dist_totals = dist_totals[['UNITID', 'TotalEnrollment', 'OnlineEnrollment']]

# --- Completions: one row per institution, CIP = "99" grand total, summed across ALL award levels ---
comp_grand = df_comp[df_comp['CIPCODE'] == '99'].copy()
comp_grand['TotalCompletions'] = pd.to_numeric(comp_grand['CTOTALT'], errors='coerce')
comp_totals = comp_grand.groupby('UNITID', as_index=False)['TotalCompletions'].sum()

# --- Institutions: decode CONTROL to a readable label, same mapping as the SQL view ---
CONTROL_MAP = {'1': 'Public', '2': 'Private not-for-profit', '3': 'Private for-profit'}
df_hd['InstitutionalControl'] = df_hd['CONTROL'].map(CONTROL_MAP).fillna('Not available')

institutions = df_hd[['UNITID', 'INSTNM', 'STABBR', 'InstitutionalControl']].rename(
    columns={'INSTNM': 'InstitutionName', 'STABBR': 'StateAbbr'}
)

# --- Merge all three, institution-level grain ---
analysis = (
    institutions
    .merge(dist_totals, on='UNITID', how='left')
    .merge(comp_totals, on='UNITID', how='left')
)

# --- Derived metrics, same math as the DAX measures ---
analysis['OnlinePenetration'] = (analysis['OnlineEnrollment'] / analysis['TotalEnrollment']) * 100
analysis['CompletionRate'] = (analysis['TotalCompletions'] / analysis['TotalEnrollment']) * 100

# Drop institutions with no enrollment data — can't compute a rate from them,
# and they'd break the regression the same way a 0-denominator breaks DIVIDE in DAX.
before = len(analysis)
analysis = analysis.dropna(subset=['TotalEnrollment', 'OnlinePenetration'])
analysis = analysis[analysis['TotalEnrollment'] > 0]
print(f"  Dropped {before - len(analysis)} institutions with no usable enrollment data.")

analysis.to_csv(OUT_ANALYSIS, index=False, encoding='utf-8')
print(f"Saved: {OUT_ANALYSIS}")
print(f"  Institutions in analysis file: {len(analysis)}")
print(analysis[['TotalEnrollment', 'OnlinePenetration', 'CompletionRate']].describe())

print("\nAll done. institution_level_export.csv is ready for ipeds_regression_analysis.py.")

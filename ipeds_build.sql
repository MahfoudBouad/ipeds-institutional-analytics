/*
================================================================================
PROJECT: IPEDS Analytics Pipeline - SQL Server Implementation (v2 - corrected)
================================================================================
Corrections from v1, verified against uploaded IPEDS dictionaries on 2026-08-06:
  - vw_Enrollment: StudentLevelCode decode fixed. Confirmed values are only
    1, 2, 3, 11, 12 (NOT 4/5 as the original comment guessed).
      1  = All students total   <- grand total row, filter to this for KPIs
      2  = Undergraduate total
      3  = Undergraduate, degree/certificate-seeking
      11 = Undergraduate, non-degree/certificate-seeking
      12 = Graduate
  - vw_Completions: CIPCode = '99' confirmed as the literal stored value for
    the "Grand total" row (plain text, not '99.0000').
  - AWLEVEL = 5 confirmed as "Bachelor's degree".
================================================================================
*/

USE master;
GO

IF EXISTS (SELECT name FROM sys.databases WHERE name = 'IPEDS_Analytics')
BEGIN
    ALTER DATABASE IPEDS_Analytics SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE IPEDS_Analytics;
END
GO

CREATE DATABASE IPEDS_Analytics;
GO

USE IPEDS_Analytics;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'staging')
    EXEC('CREATE SCHEMA staging');
GO

-- =============================================================================
-- STAGING TABLES (raw, NVARCHAR — matches the ~-delimited clean CSVs)
-- =============================================================================

DROP TABLE IF EXISTS staging.hd2025_raw;
CREATE TABLE staging.hd2025_raw (
    UNITID   NVARCHAR(50),
    INSTNM   NVARCHAR(200),
    IALIAS   NVARCHAR(MAX),
    CITY     NVARCHAR(100),
    STABBR   NVARCHAR(10),
    SECTOR   NVARCHAR(10),
    CONTROL  NVARCHAR(10),
    LONGITUD NVARCHAR(20),
    LATITUDE NVARCHAR(20)
);
GO

DROP TABLE IF EXISTS staging.effy2025_dist_raw;
CREATE TABLE staging.effy2025_dist_raw (
    UNITID    NVARCHAR(50),
    EFFYDLEV  NVARCHAR(10),
    EFYDETOT  NVARCHAR(20),
    EFYDEEXC  NVARCHAR(20),
    EFYDESOM  NVARCHAR(20),
    EFYDENON  NVARCHAR(20)
);
GO

DROP TABLE IF EXISTS staging.c2025_a_raw;
CREATE TABLE staging.c2025_a_raw (
    UNITID   NVARCHAR(50),
    CIPCODE  NVARCHAR(20),
    AWLEVEL  NVARCHAR(10),
    CTOTALT  NVARCHAR(20),
    CTOTALM  NVARCHAR(20),
    CTOTALW  NVARCHAR(20)
);
GO

-- =============================================================================
-- BULK INSERT — update the file paths to match your machine
-- =============================================================================

BULK INSERT staging.hd2025_raw
FROM 'C:\IPEDS_Data\raw\hd2025_clean.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = '~', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', TABLOCK);
GO

BULK INSERT staging.effy2025_dist_raw
FROM 'C:\IPEDS_Data\raw\effy2025_dist_clean.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = '~', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', TABLOCK);
GO

BULK INSERT staging.c2025_a_raw
FROM 'C:\IPEDS_Data\raw\c2025_a_clean.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = '~', ROWTERMINATOR = '0x0a', CODEPAGE = '65001', TABLOCK);
GO

-- =============================================================================
-- AUDIT — row counts and a few sanity checks
-- =============================================================================

SELECT 'HD' AS TableName, COUNT(*) AS Rows FROM staging.hd2025_raw
UNION ALL
SELECT 'Distance Enrollment', COUNT(*) FROM staging.effy2025_dist_raw
UNION ALL
SELECT 'Completions', COUNT(*) FROM staging.c2025_a_raw;
GO

-- Should return exactly 5 values: 1, 2, 3, 11, 12
SELECT DISTINCT EFFYDLEV FROM staging.effy2025_dist_raw ORDER BY EFFYDLEV;
GO

-- Should return exactly 1618 distinct values, including '99'
SELECT COUNT(DISTINCT CIPCODE) AS DistinctCIPCodes FROM staging.c2025_a_raw;
GO

-- =============================================================================
-- PRODUCTION VIEW 1: vw_Institutions
-- =============================================================================

IF OBJECT_ID('dbo.vw_Institutions', 'V') IS NOT NULL
    DROP VIEW dbo.vw_Institutions;
GO

CREATE VIEW dbo.vw_Institutions AS
SELECT
    TRY_CAST(UNITID AS INT) AS UnitID,
    INSTNM AS InstitutionName,
    IALIAS AS InstitutionAlias,
    CITY AS City,
    STABBR AS StateAbbr,

    -- SECTOR — confirmed against hd2025 dictionary
    CASE TRY_CAST(SECTOR AS INT)
        WHEN 0 THEN 'Administrative Unit'
        WHEN 1 THEN 'Public, 4-year or above'
        WHEN 2 THEN 'Private not-for-profit, 4-year or above'
        WHEN 3 THEN 'Private for-profit, 4-year or above'
        WHEN 4 THEN 'Public, 2-year'
        WHEN 5 THEN 'Private not-for-profit, 2-year'
        WHEN 6 THEN 'Private for-profit, 2-year'
        WHEN 7 THEN 'Public, less-than 2-year'
        WHEN 8 THEN 'Private not-for-profit, less-than 2-year'
        WHEN 9 THEN 'Private for-profit, less-than 2-year'
        WHEN 99 THEN 'Sector unknown (not active)'
        ELSE 'Unknown/Not Reported'
    END AS SectorDescription,

    -- CONTROL — confirmed against hd2025 dictionary
    CASE TRY_CAST(CONTROL AS INT)
        WHEN 1 THEN 'Public'
        WHEN 2 THEN 'Private not-for-profit'
        WHEN 3 THEN 'Private for-profit'
        ELSE 'Not available'
    END AS InstitutionalControl,

    TRY_CAST(LONGITUD AS FLOAT) AS Longitude,
    TRY_CAST(LATITUDE AS FLOAT) AS Latitude

FROM staging.hd2025_raw
WHERE TRY_CAST(UNITID AS INT) IS NOT NULL;
GO

-- =============================================================================
-- PRODUCTION VIEW 2: vw_Enrollment
-- =============================================================================

IF OBJECT_ID('dbo.vw_Enrollment', 'V') IS NOT NULL
    DROP VIEW dbo.vw_Enrollment;
GO

CREATE VIEW dbo.vw_Enrollment AS
SELECT
    TRY_CAST(UNITID AS INT) AS UnitID,
    TRY_CAST(EFFYDLEV AS INT) AS StudentLevelCode,

    -- StudentLevelCode — confirmed against effy2025_dist dictionary
    CASE TRY_CAST(EFFYDLEV AS INT)
        WHEN 1  THEN 'All students total'
        WHEN 2  THEN 'Undergraduate total'
        WHEN 3  THEN 'Undergraduate, degree/certificate-seeking'
        WHEN 11 THEN 'Undergraduate, non-degree/certificate-seeking'
        WHEN 12 THEN 'Graduate'
        ELSE 'Other/Unknown'
    END AS StudentLevelDescription,

    TRY_CAST(EFYDETOT AS INT) AS TotalHeadcount,
    TRY_CAST(EFYDEEXC AS INT) AS ExclusiveDistanceEdHeadcount,
    TRY_CAST(EFYDESOM AS INT) AS SomeDistanceEdHeadcount,
    TRY_CAST(EFYDENON AS INT) AS NoDistanceEdHeadcount

FROM staging.effy2025_dist_raw
WHERE TRY_CAST(UNITID AS INT) IS NOT NULL;
GO

-- =============================================================================
-- PRODUCTION VIEW 3: vw_Completions
-- =============================================================================

IF OBJECT_ID('dbo.vw_Completions', 'V') IS NOT NULL
    DROP VIEW dbo.vw_Completions;
GO

CREATE VIEW dbo.vw_Completions AS
SELECT
    TRY_CAST(UNITID AS INT) AS UnitID,
    CIPCODE AS CIPCode,          -- confirmed: '99' (plain text) = Grand total row
    TRY_CAST(AWLEVEL AS INT) AS AwardLevelCode,   -- confirmed: 5 = Bachelor's degree
    SUM(ISNULL(TRY_CAST(CTOTALT AS INT), 0)) AS TotalCompletions,
    SUM(ISNULL(TRY_CAST(CTOTALM AS INT), 0)) AS MaleCompletions,
    SUM(ISNULL(TRY_CAST(CTOTALW AS INT), 0)) AS FemaleCompletions
FROM staging.c2025_a_raw
WHERE TRY_CAST(UNITID AS INT) IS NOT NULL
GROUP BY TRY_CAST(UNITID AS INT), CIPCODE, TRY_CAST(AWLEVEL AS INT);
GO

-- =============================================================================
-- FINAL TEST
-- =============================================================================

SELECT TOP 10
    i.InstitutionName, i.StateAbbr,
    e.StudentLevelDescription, e.TotalHeadcount, e.ExclusiveDistanceEdHeadcount,
    c.AwardLevelCode, c.TotalCompletions
FROM dbo.vw_Institutions i
INNER JOIN dbo.vw_Enrollment e ON i.UnitID = e.UnitID
INNER JOIN dbo.vw_Completions c ON i.UnitID = c.UnitID
WHERE i.StateAbbr = 'MO'
  AND e.StudentLevelCode = 1
  AND c.AwardLevelCode = 5
  AND c.CIPCode = '99'
ORDER BY e.TotalHeadcount DESC;
GO

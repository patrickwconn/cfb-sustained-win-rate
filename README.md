# Project 1: SWR (Sustained Win-Rate) — SQL Rebuild

## Overview
This project rebuilds the College Football Sustained Win-Rate (SWR) metric — originally built in Python/pandas — entirely in PostgreSQL. The goal was to translate an existing, validated data pipeline into SQL, proving out core querying skills (joins, CTEs, aggregations, conditional logic, self-joins) against a dataset with known-correct answers.

**Data source:** CollegeFootballData (CFBD) API, Power Five teams, 2014-2025 seasons.
**Environment:** PostgreSQL 18, managed via pgAdmin4, running on Windows.
**Validation method:** Every stage was checked against the original Python/pandas output for Texas Tech before moving to the next step.

---

## Metric Definition
SWR combines three components:
1. **Weighted Win-Rate** — season win percentage adjusted for opponent strength (opponent win % relative to .500), weighted more heavily toward recent seasons.
2. **Consistency Score** — proportion of seasons a team finished above .500.
3. **Final SWR** — Weighted Win-Rate × Consistency Score.

---

## Pipeline Steps

### 1. Raw Data Load — `raw_games`
Loaded the full CFBD API game-level export (10,374 rows) into a raw table matching the API's camelCase fields (converted to snake_case columns).

**Validation:** Row count = 10,374. Zero nulls in `home_team`/`away_team`. Zero tie games (confirmed via `home_points = away_points` check), meaning win/loss logic required no tie-handling.

### 2. Home/Away Reshape — `team_games`
Used `UNION ALL` to convert each game row into two team-perspective rows (mirrors `pd.concat([home_df, away_df])` in the original Python build).

```sql
CREATE TABLE team_games AS
SELECT season, home_team AS team, home_points AS team_points,
       away_team AS opponent, away_points AS opponent_points,
       CASE WHEN home_points > away_points THEN 1 ELSE 0 END AS win
FROM raw_games
UNION ALL
SELECT season, away_team AS team, away_points AS team_points,
       home_team AS opponent, home_points AS opponent_points,
       CASE WHEN away_points > home_points THEN 1 ELSE 0 END AS win
FROM raw_games;
```

**Validation:** Row count = 20,748 (exactly 2x raw_games), confirming correct reshape.

### 3. Season-Level Aggregation — `season_records`
Collapsed team_games to one row per team per season (mirrors `groupby(['team','season']).agg(...)`).

```sql
CREATE TABLE season_records AS
SELECT team, season,
       SUM(win) AS wins,
       COUNT(*) AS games,
       COUNT(*) - SUM(win) AS losses,
       CAST(SUM(win) AS FLOAT) / COUNT(*) AS wp_raw
FROM team_games
GROUP BY team, season;
```

**Validation:** Texas Tech wins/losses/wp_raw matched Python output across all seasons.

### 4. Opponent Win Percentage Self-Join — `opponent_wp`
Self-joined team_games back to season_records on the opponent field to calculate average strength of schedule per team per season.

```sql
CREATE TABLE opponent_wp AS
SELECT tg.team, tg.season, AVG(sr.wp_raw) AS opp_wp
FROM team_games tg
JOIN season_records sr
  ON tg.opponent = sr.team AND tg.season = sr.season
GROUP BY tg.team, tg.season;
```

**Validation:** Texas Tech opp_wp values matched Python output.

### 5. Weighted, Adjusted Win-Rate (CTE stack)
Adjusted each team's win% by opponent strength deviation from .500, clamped at zero, then weighted more recent seasons more heavily.

```sql
WITH adjusted AS (
  SELECT sr.team, sr.season, sr.wp_raw, ow.opp_wp,
         sr.wp_raw + (ow.opp_wp - 0.5) AS wp_adj_raw
  FROM season_records sr
  JOIN opponent_wp ow ON sr.team = ow.team AND sr.season = ow.season
),
clamped AS (
  SELECT *,
         CASE WHEN wp_adj_raw < 0 THEN 0 ELSE wp_adj_raw END AS wp_adj_clamped,
         (season - 2013) AS weight
  FROM adjusted
)
SELECT team,
       SUM(wp_adj_clamped * weight) / SUM(weight) AS weighted_winrate
FROM clamped
GROUP BY team;
```

**Validation:** Texas Tech weighted_winrate matched Python output exactly.

### 6. Consistency Score
Proportion of seasons a team finished above .500.

```sql
WITH consistency AS (
  SELECT team,
         COUNT(*) AS total_seasons,
         SUM(CASE WHEN wp_raw > 0.5 THEN 1 ELSE 0 END) AS seasons_over_500,
         CAST(SUM(CASE WHEN wp_raw > 0.5 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) AS consistency_score
  FROM season_records
  GROUP BY team
)
SELECT * FROM consistency WHERE team = 'Texas Tech';
```

**Validation:** Texas Tech consistency_score matched Python output.

### 7. Final Combined Table — `swr_final`
```sql
CREATE TABLE swr_final AS
WITH adjusted AS (
  SELECT sr.team, sr.season, sr.wp_raw, ow.opp_wp,
         sr.wp_raw + (ow.opp_wp - 0.5) AS wp_adj_raw
  FROM season_records sr
  JOIN opponent_wp ow ON sr.team = ow.team AND sr.season = ow.season
),
clamped AS (
  SELECT *,
         CASE WHEN wp_adj_raw < 0 THEN 0 ELSE wp_adj_raw END AS wp_adj_clamped,
         (season - 2013) AS weight
  FROM adjusted
),
weighted AS (
  SELECT team, SUM(wp_adj_clamped * weight) / SUM(weight) AS weighted_winrate
  FROM clamped GROUP BY team
),
consistency AS (
  SELECT team,
         CAST(SUM(CASE WHEN wp_raw > 0.5 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) AS consistency_score
  FROM season_records GROUP BY team
)
SELECT w.team, w.weighted_winrate, c.consistency_score,
       w.weighted_winrate * c.consistency_score AS swr
FROM weighted w
JOIN consistency c ON w.team = c.team;
```

**Validation:** Texas Tech weighted_winrate, consistency_score, and final swr all matched Python output exactly, confirming end-to-end pipeline accuracy.

---

## Debugging Log (Real Issues Encountered)

| Issue | Cause | Fix |
|---|---|---|
| `invalid input syntax for type bigint: "id"` | Header row wasn't being skipped during import | Added `HEADER` option to `\copy` command |
| `invalid input syntax for type integer: "10140.0"` | Pandas upcast integer columns with nulls to float on CSV export | Changed affected columns (attendance, elo fields, points, week) from `INTEGER` to `NUMERIC` |
| `extra data after last expected column` | CSV had more columns than original table definition (full CFBD API field list vs. trimmed version) | Rewrote `CREATE TABLE` to include every field returned by the API |
| `invalid input syntax for type numeric: "Abilene Christian"` | CSV column order didn't match table's column order, causing values to shift into wrong columns | Rewrote `CREATE TABLE`/import to align exactly with CSV column order |

These issues reflect common real-world data loading friction — column mismatches, type inference differences between pandas and SQL, and header handling — rather than logic errors in the SWR calculation itself.

---

## SQL vs. Python: Comparison Notes

- **Where SQL felt more natural:** The home/away reshape (`UNION ALL`) was arguably cleaner in SQL than the pandas `pd.concat()` equivalent — the CASE WHEN win logic reads intuitively next to the SELECT.
- **Where pandas was easier:** Debugging intermediate steps was faster in Python (just print a dataframe), whereas SQL required creating intermediate tables or wrapping CTEs to inspect results at each stage.
- **Where SQL revealed new skills:** The self-join for opponent win percentage and the multi-layer CTE stack for weighting/clamping required a different mental model than pandas' `.merge()` and `.apply()` — arguably more transferable to real analyst job contexts using pure SQL environments.

---

## Skills Demonstrated
- Table design and CREATE TABLE statements matching real-world messy API data
- COPY/\copy CSV imports and troubleshooting (column order, header rows, type mismatches)
- UNION ALL for data reshaping
- GROUP BY aggregations with conditional (CASE WHEN) logic
- Self-joins for cross-referencing records within the same table
- Multi-layer CTEs for stacked, sequential calculations
- End-to-end validation methodology against a trusted external source (Python/pandas output)

---

## Next Steps
Building a database for NFL, NBA, and MLB using this same logic. 

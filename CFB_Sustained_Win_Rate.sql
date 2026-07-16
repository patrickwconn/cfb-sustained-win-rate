-- ============================================================
-- Project 1: SWR (Sustained Win-Rate) — SQL Rebuild
-- CollegeFootballData (CFBD) API, Power Five teams, 2014-2025
-- Validated against original Python/pandas pipeline (Texas Tech)
-- ============================================================

-- ------------------------------------------------------------
-- STEP 1: Raw Data Table
-- ------------------------------------------------------------
DROP TABLE IF EXISTS raw_games;

CREATE TABLE raw_games (
    id BIGINT PRIMARY KEY,
    season INT NOT NULL,
    week NUMERIC,
    season_type VARCHAR(20),
    start_date TIMESTAMP,
    start_time_tbd BOOLEAN,
    completed BOOLEAN,
    neutral_site BOOLEAN,
    conference_game BOOLEAN,
    attendance NUMERIC,
    venue_id NUMERIC,
    venue VARCHAR(150),
    home_id INT,
    home_team VARCHAR(100),
    home_classification VARCHAR(20),
    home_conference VARCHAR(50),
    home_points NUMERIC,
    home_line_scores TEXT,
    home_postgame_win_probability NUMERIC(6,4),
    home_pregame_elo NUMERIC,
    home_postgame_elo NUMERIC,
    away_id INT,
    away_team VARCHAR(100),
    away_classification VARCHAR(20),
    away_conference VARCHAR(50),
    away_points NUMERIC,
    away_line_scores TEXT,
    away_postgame_win_probability NUMERIC(6,4),
    away_pregame_elo NUMERIC,
    away_postgame_elo NUMERIC,
    excitement_index NUMERIC(6,3),
    highlights TEXT,
    notes TEXT
);

-- Import (run from psql, adjust column order/path to match your CSV):
-- \copy raw_games (id, season, week, season_type, start_date, start_time_tbd,
--   completed, neutral_site, conference_game, attendance, venue_id, venue,
--   home_id, home_team, home_classification, home_conference, home_points,
--   home_line_scores, home_postgame_win_probability, home_pregame_elo,
--   home_postgame_elo, away_id, away_team, away_classification, away_conference,
--   away_points, away_line_scores, away_postgame_win_probability, away_pregame_elo,
--   away_postgame_elo, excitement_index, highlights, notes)
-- FROM 'C:\path\to\your\file.csv' WITH (FORMAT CSV, HEADER);

-- Validation
SELECT COUNT(*) FROM raw_games;                                   -- expect 10374
SELECT MIN(season), MAX(season) FROM raw_games;                   -- expect 2014, 2025
SELECT COUNT(*) FROM raw_games WHERE home_team IS NULL OR away_team IS NULL; -- expect 0
SELECT COUNT(*) FROM raw_games WHERE home_points = away_points;   -- expect 0 (no ties)

-- ------------------------------------------------------------
-- STEP 2: Home/Away Reshape
-- ------------------------------------------------------------
DROP TABLE IF EXISTS team_games;

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

-- Validation
SELECT COUNT(*) FROM team_games; -- expect 20748 (2x raw_games)

-- ------------------------------------------------------------
-- STEP 3: Season-Level Aggregation
-- ------------------------------------------------------------
DROP TABLE IF EXISTS season_records;

CREATE TABLE season_records AS
SELECT team, season,
       SUM(win) AS wins,
       COUNT(*) AS games,
       COUNT(*) - SUM(win) AS losses,
       CAST(SUM(win) AS FLOAT) / COUNT(*) AS wp_raw
FROM team_games
GROUP BY team, season;

-- Validation
SELECT * FROM season_records WHERE team = 'Texas Tech' ORDER BY season;

-- ------------------------------------------------------------
-- STEP 4: Opponent Win Percentage Self-Join
-- ------------------------------------------------------------
DROP TABLE IF EXISTS opponent_wp;

CREATE TABLE opponent_wp AS
SELECT tg.team, tg.season, AVG(sr.wp_raw) AS opp_wp
FROM team_games tg
JOIN season_records sr
  ON tg.opponent = sr.team AND tg.season = sr.season
GROUP BY tg.team, tg.season;

-- Validation
SELECT * FROM opponent_wp WHERE team = 'Texas Tech' ORDER BY season;

-- ------------------------------------------------------------
-- STEP 5: Weighted, Adjusted Win-Rate (CTE stack)
-- ------------------------------------------------------------
SELECT team, weighted_winrate FROM (
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
  GROUP BY team
) sub
WHERE team = 'Texas Tech';

-- ------------------------------------------------------------
-- STEP 6: Consistency Score
-- ------------------------------------------------------------
WITH consistency AS (
  SELECT team,
         COUNT(*) AS total_seasons,
         SUM(CASE WHEN wp_raw > 0.5 THEN 1 ELSE 0 END) AS seasons_over_500,
         CAST(SUM(CASE WHEN wp_raw > 0.5 THEN 1 ELSE 0 END) AS FLOAT) / COUNT(*) AS consistency_score
  FROM season_records
  GROUP BY team
)
SELECT * FROM consistency WHERE team = 'Texas Tech';

-- ------------------------------------------------------------
-- STEP 7: Final Combined SWR Table
-- ------------------------------------------------------------
DROP TABLE IF EXISTS swr_final;

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

-- Final Validation
SELECT * FROM swr_final WHERE team = 'Texas Tech';
SELECT * FROM swr_final ORDER BY swr DESC;

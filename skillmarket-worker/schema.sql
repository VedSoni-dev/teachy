-- Download counts per Skill Market listing.
CREATE TABLE IF NOT EXISTS skill_counts (
  skill_id TEXT PRIMARY KEY,
  downloads INTEGER NOT NULL DEFAULT 0
);

-- One row per (hashed visitor, skill, day) so the same person counts once a day.
-- The hash uses a salt that changes every day; rows older than two days are deleted.
CREATE TABLE IF NOT EXISTS recent_counts (
  visitor_key TEXT PRIMARY KEY,
  day TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS recent_counts_day ON recent_counts (day);

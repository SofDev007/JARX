-- Run ONCE on the live database (schema.sql already has it for new
-- databases): npx wrangler d1 execute jarx --remote --file=migrations/0002_problem_reports.sql
-- Settings › Report a problem.
CREATE TABLE IF NOT EXISTS problem_reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  text TEXT NOT NULL,
  app TEXT,
  device TEXT
);

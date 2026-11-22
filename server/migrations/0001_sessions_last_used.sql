-- Run ONCE on the live database (schema.sql already has the column for new
-- databases): npx wrangler d1 execute jarx --remote --file=migrations/0001_sessions_last_used.sql
-- When each phone last used its sign-in, for the admin page's phone list.
ALTER TABLE sessions ADD COLUMN last_used INTEGER;

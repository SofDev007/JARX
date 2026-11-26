-- JARX server database (Cloudflare D1). Safe to run again.

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,                    -- Google account id ("sub")
  email TEXT NOT NULL,
  name TEXT,
  photo TEXT,
  first_seen INTEGER NOT NULL,            -- ms since epoch
  last_seen INTEGER NOT NULL,
  app_version TEXT,
  status TEXT NOT NULL DEFAULT 'active',  -- active | banned
  ban_reason TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,            -- sha256 of the token the app holds
  user_id TEXT NOT NULL REFERENCES users(id),
  device TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  last_used INTEGER                       -- GET /me; live DB: migrations/0001
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);

-- One row per user and kind: 'library' (playlists + Liked), 'taste'
-- (what JARX learned), 'listening' (listening time). Newest wins.
CREATE TABLE IF NOT EXISTS user_data (
  user_id TEXT NOT NULL REFERENCES users(id),
  kind TEXT NOT NULL,
  json TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, kind)
);

-- JARX AI (src/ai.js). Use per user per day (India time), for the daily limits.
CREATE TABLE IF NOT EXISTS ai_usage (
  user_id TEXT NOT NULL,
  day TEXT NOT NULL,                      -- YYYY-MM-DD
  chats INTEGER NOT NULL DEFAULT 0,
  tags INTEGER NOT NULL DEFAULT 0,        -- mood-tag requests that asked the AI
  PRIMARY KEY (user_id, day)
);

-- Mood tags, shared by everyone: each song is asked once. key = the phone's
-- song key (simplified title|artist); moods = comma list, '' = AI didn't know it.
-- ponytail: any signed-in phone can write tags for any key; fine with
-- approved users only. Check keys server-side if that ever changes.
CREATE TABLE IF NOT EXISTS song_moods (
  key TEXT PRIMARY KEY,
  moods TEXT NOT NULL,
  at INTEGER NOT NULL
);

-- "Report this reply" from the chat, for the owner to read on /admin.
CREATE TABLE IF NOT EXISTS ai_reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  said TEXT,
  reply TEXT NOT NULL
);

-- Settings › Report a problem: what people write, for the owner (admin page).
CREATE TABLE IF NOT EXISTS problem_reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  text TEXT NOT NULL,
  app TEXT,
  device TEXT
);

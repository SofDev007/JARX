-- JARX 1 schema. Tracks are stored as JSON in the normalized Track model.
-- Timestamps are Unix epoch milliseconds.

CREATE TABLE playlist (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_playlist_updated_at ON playlist (updated_at);

-- Positions are contiguous 0..n-1 per playlist, maintained by the API.
-- No UNIQUE(playlist_id, position): SQLite checks uniqueness per row, which
-- would break the single-statement shift used by reorder/remove.
CREATE TABLE playlist_track (
  playlist_id TEXT NOT NULL REFERENCES playlist (id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  track_json TEXT NOT NULL,
  added_at INTEGER NOT NULL
);
-- Serves the playlist_id foreign key (leftmost column) and ordered reads.
CREATE INDEX idx_playlist_track_playlist_position ON playlist_track (playlist_id, position);

-- track_key = Track.id ("<source>:<sourceId>"); the primary key is its index.
CREATE TABLE favorite (
  track_key TEXT PRIMARY KEY,
  track_json TEXT NOT NULL,
  added_at INTEGER NOT NULL
);
CREATE INDEX idx_favorite_added_at ON favorite (added_at);

CREATE TABLE recently_played (
  track_json TEXT NOT NULL,
  played_at INTEGER NOT NULL
);
CREATE INDEX idx_recently_played_played_at ON recently_played (played_at);

CREATE TABLE search_cache (
  query_hash TEXT PRIMARY KEY,
  results_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);
-- Used to purge expired entries.
CREATE INDEX idx_search_cache_fetched_at ON search_cache (fetched_at);

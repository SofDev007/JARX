import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// The last good copy of each API response, keyed by request path, so the library still
/// opens offline. Also holds the player's saved queue. A single key-value table doesn't
/// earn Drift's codegen, so this uses its raw-SQL API.
class Cache extends GeneratedDatabase {
  Cache([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'jarx'));

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => customStatement(
      'CREATE TABLE cache (key TEXT PRIMARY KEY, json TEXT NOT NULL, saved_at INTEGER NOT NULL)',
    ),
  );

  Future<String?> getJson(String key) async {
    final row = await customSelect(
      'SELECT json FROM cache WHERE key = ?',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row?.read<String>('json');
  }

  Future<void> putJson(String key, String json) => customStatement(
    'INSERT OR REPLACE INTO cache (key, json, saved_at) VALUES (?, ?, ?)',
    [key, json, DateTime.now().millisecondsSinceEpoch],
  );
}

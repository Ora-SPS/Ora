import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../db/db.dart';

class FoodCacheRepo {
  FoodCacheRepo(this._db);

  final AppDatabase _db;

  Future<Map<String, dynamic>?> getFresh(String cacheKey) async {
    final db = await _db.database;
    final rows = await db.query(
      'food_lookup_cache',
      columns: ['payload_json', 'expires_at'],
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final expiresAt =
        DateTime.tryParse(rows.first['expires_at'] as String? ?? '');
    if (expiresAt == null || expiresAt.isBefore(DateTime.now())) {
      return null;
    }
    return _decode(rows.first['payload_json'] as String?);
  }

  Future<Map<String, dynamic>?> getAny(String cacheKey) async {
    final db = await _db.database;
    final rows = await db.query(
      'food_lookup_cache',
      columns: ['payload_json'],
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['payload_json'] as String?);
  }

  Future<void> put({
    required String cacheKey,
    required String cacheType,
    required String queryText,
    required Map<String, dynamic> payload,
    required Duration ttl,
  }) async {
    final now = DateTime.now();
    final db = await _db.database;
    await db.insert(
      'food_lookup_cache',
      {
        'cache_key': cacheKey,
        'cache_type': cacheType,
        'query_text': queryText,
        'payload_json': jsonEncode(payload),
        'expires_at': now.add(ttl).toIso8601String(),
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> purgeExpired() async {
    final db = await _db.database;
    await db.delete(
      'food_lookup_cache',
      where: 'expires_at < ?',
      whereArgs: [DateTime.now().toIso8601String()],
    );
  }

  Map<String, dynamic>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }
}

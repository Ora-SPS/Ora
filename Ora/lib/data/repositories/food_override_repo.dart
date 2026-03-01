import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/food/food_models.dart';
import '../db/db.dart';

class FoodOverrideRepo {
  FoodOverrideRepo(this._db);

  final AppDatabase _db;

  Future<void> upsert(FoodSearchItem item) async {
    final db = await _db.database;
    final now = DateTime.now().toIso8601String();
    await db.insert(
      'food_custom_override',
      {
        'lookup_key': _lookupKey(item),
        'normalized_name': _normalize(item.name),
        'brand_name_normalized': _normalize(item.brandName),
        'display_name': item.displayName,
        'barcode': item.barcode,
        'payload_json': jsonEncode(item.toMap()),
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<FoodSearchItem?> findByBarcode(String barcode) async {
    final db = await _db.database;
    final rows = await db.query(
      'food_custom_override',
      columns: ['payload_json'],
      where: 'barcode = ?',
      whereArgs: [barcode.trim()],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['payload_json'] as String?);
  }

  Future<List<FoodSearchItem>> search(String query, {int limit = 12}) async {
    final normalized = _normalize(query);
    if (normalized.isEmpty) return const [];
    final db = await _db.database;
    final rows = await db.query(
      'food_custom_override',
      columns: ['payload_json'],
      where: 'normalized_name LIKE ? OR brand_name_normalized LIKE ?',
      whereArgs: ['%$normalized%', '%$normalized%'],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows
        .map((row) => _decode(row['payload_json'] as String?))
        .whereType<FoodSearchItem>()
        .toList();
  }

  FoodSearchItem? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return FoodSearchItem.fromMap(decoded);
      }
    } catch (_) {}
    return null;
  }

  String _lookupKey(FoodSearchItem item) {
    final barcode = item.barcode?.trim();
    if (barcode != null && barcode.isNotEmpty) {
      return 'barcode:$barcode';
    }
    final brand = _normalize(item.brandName);
    return 'name:${_normalize(item.name)}|brand:$brand';
  }

  String _normalize(String? input) {
    final raw = input?.trim().toLowerCase() ?? '';
    return raw.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }
}

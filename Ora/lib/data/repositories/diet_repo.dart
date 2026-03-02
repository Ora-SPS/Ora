import 'dart:convert';

import '../../domain/models/diet_entry.dart';
import '../db/db.dart';

class DietRepo {
  DietRepo(this._db);

  final AppDatabase _db;

  Future<int> addEntry({
    required String mealName,
    required DateTime loggedAt,
    required DietMealType mealType,
    double? calories,
    double? proteinG,
    double? carbsG,
    double? fatG,
    double? fiberG,
    double? sodiumMg,
    Map<String, double>? micros,
    String? notes,
    String? imagePath,
    String? barcode,
    String? foodSource,
    String? foodSourceId,
    String? portionLabel,
    double? portionGrams,
    double? portionAmount,
    String? portionUnit,
  }) async {
    final db = await _db.database;
    return db.insert('diet_entry', {
      'meal_name': mealName,
      'logged_at': loggedAt.toIso8601String(),
      'meal_type': mealType.storageValue,
      'calories': calories,
      'protein_g': proteinG,
      'carbs_g': carbsG,
      'fat_g': fatG,
      'fiber_g': fiberG,
      'sodium_mg': sodiumMg,
      'micros_json': micros == null ? null : jsonEncode(micros),
      'notes': notes,
      'image_path': imagePath,
      'barcode': barcode,
      'food_source': foodSource,
      'food_source_id': foodSourceId,
      'portion_label': portionLabel,
      'portion_grams': portionGrams,
      'portion_amount': portionAmount,
      'portion_unit': portionUnit,
    });
  }

  Future<List<DietEntry>> getEntriesForDay(DateTime day) async {
    final db = await _db.database;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await db.query(
      'diet_entry',
      where: 'logged_at >= ? AND logged_at < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'logged_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<DietEntry>> getEntriesForRange(
      DateTime start, DateTime end) async {
    final db = await _db.database;
    final rows = await db.query(
      'diet_entry',
      where: 'logged_at >= ? AND logged_at < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
      orderBy: 'logged_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<DietSummary> getSummaryForDay(DateTime day) async {
    final db = await _db.database;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await db.rawQuery('''
SELECT
  SUM(calories) as calories,
  SUM(protein_g) as protein_g,
  SUM(carbs_g) as carbs_g,
  SUM(fat_g) as fat_g,
  SUM(fiber_g) as fiber_g,
  SUM(sodium_mg) as sodium_mg
FROM diet_entry
WHERE logged_at >= ? AND logged_at < ?
''', [start.toIso8601String(), end.toIso8601String()]);
    if (rows.isEmpty) return const DietSummary();
    final row = rows.first;
    return DietSummary(
      calories: _asDouble(row['calories']),
      proteinG: _asDouble(row['protein_g']),
      carbsG: _asDouble(row['carbs_g']),
      fatG: _asDouble(row['fat_g']),
      fiberG: _asDouble(row['fiber_g']),
      sodiumMg: _asDouble(row['sodium_mg']),
    );
  }

  Future<DietSummary> getSummaryForRange(DateTime start, DateTime end) async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
SELECT
  SUM(calories) as calories,
  SUM(protein_g) as protein_g,
  SUM(carbs_g) as carbs_g,
  SUM(fat_g) as fat_g,
  SUM(fiber_g) as fiber_g,
  SUM(sodium_mg) as sodium_mg
FROM diet_entry
WHERE logged_at >= ? AND logged_at < ?
''', [start.toIso8601String(), end.toIso8601String()]);
    if (rows.isEmpty) return const DietSummary();
    final row = rows.first;
    return DietSummary(
      calories: _asDouble(row['calories']),
      proteinG: _asDouble(row['protein_g']),
      carbsG: _asDouble(row['carbs_g']),
      fatG: _asDouble(row['fat_g']),
      fiberG: _asDouble(row['fiber_g']),
      sodiumMg: _asDouble(row['sodium_mg']),
    );
  }

  Future<Map<String, double>> getMicrosForRange(
      DateTime start, DateTime end) async {
    final db = await _db.database;
    final rows = await db.query(
      'diet_entry',
      columns: ['micros_json'],
      where: 'logged_at >= ? AND logged_at < ?',
      whereArgs: [start.toIso8601String(), end.toIso8601String()],
    );
    final totals = <String, double>{};
    for (final row in rows) {
      final micros = _decodeMicros(row['micros_json'] as String?);
      if (micros == null) continue;
      micros.forEach((key, value) {
        totals[key] = (totals[key] ?? 0) + value;
      });
    }
    return totals;
  }

  Future<List<DietDaySummary>> getDailySummaries(
      DateTime startDay, int days) async {
    final db = await _db.database;
    final start = DateTime(startDay.year, startDay.month, startDay.day);
    final end = start.add(Duration(days: days));
    final rows = await db.rawQuery('''
SELECT
  substr(logged_at, 1, 10) as day,
  SUM(calories) as calories,
  SUM(protein_g) as protein_g,
  SUM(carbs_g) as carbs_g,
  SUM(fat_g) as fat_g,
  SUM(fiber_g) as fiber_g,
  SUM(sodium_mg) as sodium_mg
FROM diet_entry
WHERE logged_at >= ? AND logged_at < ?
GROUP BY substr(logged_at, 1, 10)
ORDER BY day DESC
''', [start.toIso8601String(), end.toIso8601String()]);
    return rows.map((row) {
      return DietDaySummary(
        day: row['day'] as String,
        calories: _asDouble(row['calories']),
        proteinG: _asDouble(row['protein_g']),
        carbsG: _asDouble(row['carbs_g']),
        fatG: _asDouble(row['fat_g']),
        fiberG: _asDouble(row['fiber_g']),
        sodiumMg: _asDouble(row['sodium_mg']),
      );
    }).toList();
  }

  Future<List<DietEntry>> getRecentEntries({int limit = 20}) async {
    final db = await _db.database;
    final rows = await db.query(
      'diet_entry',
      orderBy: 'logged_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<DietEntry>> getEntriesForBarcodeOnDay({
    required String barcode,
    required DateTime day,
  }) async {
    final db = await _db.database;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final rows = await db.query(
      'diet_entry',
      where: 'barcode = ? AND logged_at >= ? AND logged_at < ?',
      whereArgs: [barcode, start.toIso8601String(), end.toIso8601String()],
      orderBy: 'logged_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> updateEntry({
    required int id,
    String? mealName,
    DateTime? loggedAt,
    DietMealType? mealType,
    double? calories,
    double? proteinG,
    double? carbsG,
    double? fatG,
    double? fiberG,
    double? sodiumMg,
    Map<String, double>? micros,
    String? notes,
    String? imagePath,
    String? barcode,
    String? foodSource,
    String? foodSourceId,
    String? portionLabel,
    double? portionGrams,
    double? portionAmount,
    String? portionUnit,
  }) async {
    final db = await _db.database;
    await db.update(
      'diet_entry',
      {
        if (mealName != null) 'meal_name': mealName,
        if (loggedAt != null) 'logged_at': loggedAt.toIso8601String(),
        if (mealType != null) 'meal_type': mealType.storageValue,
        if (calories != null) 'calories': calories,
        if (proteinG != null) 'protein_g': proteinG,
        if (carbsG != null) 'carbs_g': carbsG,
        if (fatG != null) 'fat_g': fatG,
        if (fiberG != null) 'fiber_g': fiberG,
        if (sodiumMg != null) 'sodium_mg': sodiumMg,
        if (micros != null) 'micros_json': jsonEncode(micros),
        if (notes != null) 'notes': notes,
        if (imagePath != null) 'image_path': imagePath,
        if (barcode != null) 'barcode': barcode,
        if (foodSource != null) 'food_source': foodSource,
        if (foodSourceId != null) 'food_source_id': foodSourceId,
        if (portionLabel != null) 'portion_label': portionLabel,
        if (portionGrams != null) 'portion_grams': portionGrams,
        if (portionAmount != null) 'portion_amount': portionAmount,
        if (portionUnit != null) 'portion_unit': portionUnit,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteEntry(int id) async {
    final db = await _db.database;
    await db.delete('diet_entry', where: 'id = ?', whereArgs: [id]);
  }

  DietEntry _fromRow(Map<String, Object?> row) {
    return DietEntry(
      id: row['id'] as int,
      mealName: row['meal_name'] as String,
      loggedAt: DateTime.parse(row['logged_at'] as String),
      mealType: row['meal_type'] == null
          ? DietMealTypeX.inferFromLoggedAt(
              DateTime.parse(row['logged_at'] as String),
            )
          : DietMealTypeX.fromStorage(row['meal_type'] as String?),
      calories: _asDouble(row['calories']),
      proteinG: _asDouble(row['protein_g']),
      carbsG: _asDouble(row['carbs_g']),
      fatG: _asDouble(row['fat_g']),
      fiberG: _asDouble(row['fiber_g']),
      sodiumMg: _asDouble(row['sodium_mg']),
      micros: _decodeMicros(row['micros_json'] as String?),
      notes: row['notes'] as String?,
      imagePath: row['image_path'] as String?,
      barcode: row['barcode'] as String?,
      foodSource: row['food_source'] as String?,
      foodSourceId: row['food_source_id'] as String?,
      portionLabel: row['portion_label'] as String?,
      portionGrams: _asDouble(row['portion_grams']),
      portionAmount: _asDouble(row['portion_amount']),
      portionUnit: row['portion_unit'] as String?,
    );
  }

  double? _asDouble(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return double.tryParse(value.toString());
  }

  Map<String, double>? _decodeMicros(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        final result = <String, double>{};
        decoded.forEach((key, value) {
          final parsed = _asDouble(value);
          if (parsed != null) {
            result[key.toString()] = parsed;
          }
        });
        return result.isEmpty ? null : result;
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

class DietSummary {
  const DietSummary({
    this.calories,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sodiumMg,
  });

  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final double? fiberG;
  final double? sodiumMg;
}

class DietDaySummary extends DietSummary {
  const DietDaySummary({
    required this.day,
    super.calories,
    super.proteinG,
    super.carbsG,
    super.fatG,
    super.fiberG,
    super.sodiumMg,
  });

  final String day;
}

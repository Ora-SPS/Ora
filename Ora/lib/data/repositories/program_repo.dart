import 'dart:convert';

import '../db/db.dart';

class ProgramRepo {
  ProgramRepo(this._db);

  final AppDatabase _db;

  Future<int> createProgram({required String name, String? notes}) async {
    final db = await _db.database;
    return db.insert('program', {
      'name': name,
      'notes': notes,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> getPrograms() async {
    final db = await _db.database;
    return db.query('program', orderBy: 'created_at DESC');
  }

  Future<void> deleteProgram(int programId) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      await txn.update('workout_session', {
        'program_id': null,
        'program_day_id': null,
      }, where: 'program_id = ?', whereArgs: [programId]);

      final days = await txn.query('program_day', columns: ['id'], where: 'program_id = ?', whereArgs: [programId]);
      for (final day in days) {
        final dayId = day['id'] as int;
        final exercises = await txn.query(
          'program_day_exercise',
          columns: ['id'],
          where: 'program_day_id = ?',
          whereArgs: [dayId],
        );
        for (final ex in exercises) {
          final dayExerciseId = ex['id'] as int;
          await txn.delete('set_plan_block', where: 'program_day_exercise_id = ?', whereArgs: [dayExerciseId]);
        }
        await txn.delete('program_day_exercise', where: 'program_day_id = ?', whereArgs: [dayId]);
      }
      await txn.delete('program_day', where: 'program_id = ?', whereArgs: [programId]);
      await txn.delete('program', where: 'id = ?', whereArgs: [programId]);
    });
  }

  Future<void> updateProgram({required int id, required String name, String? notes}) async {
    final db = await _db.database;
    await db.update(
      'program',
      {'name': name, 'notes': notes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> addProgramDay({
    required int programId,
    required int dayIndex,
    required String dayName,
  }) async {
    final db = await _db.database;
    return db.insert('program_day', {
      'program_id': programId,
      'day_index': dayIndex,
      'day_name': dayName,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> getProgramDays(int programId) async {
    final db = await _db.database;
    return db.query(
      'program_day',
      where: 'program_id = ?',
      whereArgs: [programId],
      orderBy: 'day_index ASC',
    );
  }

  Future<Map<String, Object?>?> getProgramDayByIndex({required int programId, required int dayIndex}) async {
    final db = await _db.database;
    final rows = await db.query(
      'program_day',
      where: 'program_id = ? AND day_index = ?',
      whereArgs: [programId, dayIndex],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> updateProgramDay({required int id, required String dayName}) async {
    final db = await _db.database;
    await db.update(
      'program_day',
      {'day_name': dayName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> addProgramDayExercise({
    required int programDayId,
    required int exerciseId,
    required int orderIndex,
    String? notes,
  }) async {
    final db = await _db.database;
    return db.insert('program_day_exercise', {
      'program_day_id': programDayId,
      'exercise_id': exerciseId,
      'order_index': orderIndex,
      'notes': notes,
    });
  }

  Future<List<Map<String, Object?>>> getProgramDayExerciseDetails(int programDayId) async {
    final db = await _db.database;
    return db.rawQuery('''\nSELECT pde.id as program_day_exercise_id,\n       pde.exercise_id,\n       pde.order_index,\n       pde.notes,\n       e.canonical_name,\n       e.weight_mode_default\nFROM program_day_exercise pde\nJOIN exercise e ON e.id = pde.exercise_id\nWHERE pde.program_day_id = ?\nORDER BY pde.order_index ASC\n''', [programDayId]);
  }

  Future<void> deleteProgramDayExercise(int programDayExerciseId) async {
    final db = await _db.database;
    await db.delete('set_plan_block', where: 'program_day_exercise_id = ?', whereArgs: [programDayExerciseId]);
    await db.delete('program_day_exercise', where: 'id = ?', whereArgs: [programDayExerciseId]);
  }

  Future<int> addSetPlanBlock({
    required int programDayExerciseId,
    required int orderIndex,
    required String role,
    required int setCount,
    int? repsMin,
    int? repsMax,
    int? restSecMin,
    int? restSecMax,
    double? targetRpeMin,
    double? targetRpeMax,
    double? targetRirMin,
    double? targetRirMax,
    required String loadRuleType,
    double? loadRuleMin,
    double? loadRuleMax,
    required bool amrapLastSet,
    int? partialsTargetMin,
    int? partialsTargetMax,
    String? notes,
  }) async {
    final db = await _db.database;
    return db.insert('set_plan_block', {
      'program_day_exercise_id': programDayExerciseId,
      'order_index': orderIndex,
      'role': role,
      'set_count': setCount,
      'reps_min': repsMin,
      'reps_max': repsMax,
      'rest_sec_min': restSecMin,
      'rest_sec_max': restSecMax,
      'target_rpe_min': targetRpeMin,
      'target_rpe_max': targetRpeMax,
      'target_rir_min': targetRirMin,
      'target_rir_max': targetRirMax,
      'load_rule_type': loadRuleType,
      'load_rule_min': loadRuleMin,
      'load_rule_max': loadRuleMax,
      'amrap_last_set': amrapLastSet ? 1 : 0,
      'partials_target_min': partialsTargetMin,
      'partials_target_max': partialsTargetMax,
      'notes': notes,
    });
  }

  Future<List<Map<String, Object?>>> getSetPlanBlocks(int programDayExerciseId) async {
    final db = await _db.database;
    return db.query(
      'set_plan_block',
      where: 'program_day_exercise_id = ?',
      whereArgs: [programDayExerciseId],
      orderBy: 'order_index ASC',
    );
  }

  Future<void> replaceSetPlanBlocks(int programDayExerciseId, List<Map<String, Object?>> blocks) async {
    final db = await _db.database;
    final batch = db.batch();
    batch.delete('set_plan_block', where: 'program_day_exercise_id = ?', whereArgs: [programDayExerciseId]);
    for (final block in blocks) {
      batch.insert('set_plan_block', {
        'program_day_exercise_id': programDayExerciseId,
        'order_index': block['order_index'],
        'role': block['role'],
        'set_count': block['set_count'],
        'reps_min': block['reps_min'],
        'reps_max': block['reps_max'],
        'rest_sec_min': block['rest_sec_min'],
        'rest_sec_max': block['rest_sec_max'],
        'target_rpe_min': block['target_rpe_min'],
        'target_rpe_max': block['target_rpe_max'],
        'target_rir_min': block['target_rir_min'],
        'target_rir_max': block['target_rir_max'],
        'load_rule_type': block['load_rule_type'],
        'load_rule_min': block['load_rule_min'],
        'load_rule_max': block['load_rule_max'],
        'amrap_last_set': block['amrap_last_set'],
        'partials_target_min': block['partials_target_min'],
        'partials_target_max': block['partials_target_max'],
        'notes': block['notes'],
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, Object?>>> getProgramDayExercises(int programDayId) async {
    final db = await _db.database;
    return db.query(
      'program_day_exercise',
      where: 'program_day_id = ?',
      whereArgs: [programDayId],
      orderBy: 'order_index ASC',
    );
  }

  Future<int?> getProgramDayExerciseIdByOrder({
    required int programDayId,
    required int orderIndex,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'program_day_exercise',
      columns: ['id'],
      where: 'program_day_id = ? AND order_index = ?',
      whereArgs: [programDayId, orderIndex],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as int?;
  }

  Future<Map<int, List<String>>> getExerciseNamesByDayForProgram(int programId) async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
SELECT pd.id as day_id,
       e.canonical_name as name
FROM program_day pd
JOIN program_day_exercise pde ON pde.program_day_id = pd.id
JOIN exercise e ON e.id = pde.exercise_id
WHERE pd.program_id = ?
ORDER BY pd.day_index ASC, pde.order_index ASC
''', [programId]);
    final map = <int, List<String>>{};
    for (final row in rows) {
      final dayId = row['day_id'] as int?;
      final name = row['name'] as String?;
      if (dayId == null || name == null || name.trim().isEmpty) continue;
      map.putIfAbsent(dayId, () => []).add(name.trim());
    }
    return map;
  }

  Future<List<String>> getMusclesForProgramDay(int programDayId) async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
SELECT e.primary_muscle, e.secondary_muscles_json
FROM program_day_exercise pde
JOIN exercise e ON e.id = pde.exercise_id
WHERE pde.program_day_id = ?
''', [programDayId]);
    final muscles = <String>{};
    for (final row in rows) {
      final primary = row['primary_muscle'] as String?;
      if (primary != null && primary.trim().isNotEmpty) {
        muscles.add(primary.trim());
      }
      final secondaryJson = row['secondary_muscles_json'] as String?;
      if (secondaryJson != null && secondaryJson.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(secondaryJson);
          if (decoded is List) {
            for (final item in decoded) {
              if (item is String && item.trim().isNotEmpty) {
                muscles.add(item.trim());
              }
            }
          }
        } catch (_) {}
      }
    }
    return muscles.toList()..sort();
  }
}

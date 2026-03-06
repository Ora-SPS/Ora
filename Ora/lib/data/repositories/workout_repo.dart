import 'package:sqflite/sqflite.dart';

import '../db/db.dart';

const _unchangedSetEntryField = Object();

class WorkoutRepo {
  WorkoutRepo(this._db);

  final AppDatabase _db;

  Future<int> startSession({int? programId, int? programDayId}) async {
    final db = await _db.database;
    return db.insert('workout_session', {
      'program_id': programId,
      'program_day_id': programDayId,
      'started_at': DateTime.now().toIso8601String(),
      'ended_at': null,
      'notes': null,
    });
  }

  Future<Map<String, Object?>?> getActiveSession({int? programId}) async {
    final db = await _db.database;
    final rows = await db.query(
      'workout_session',
      where: programId == null
          ? 'ended_at IS NULL'
          : 'ended_at IS NULL AND program_id = ?',
      whereArgs: programId == null ? null : [programId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<bool> hasActiveSession({int? programId}) async {
    final row = await getActiveSession(programId: programId);
    return row != null;
  }

  Future<void> endSession(int sessionId) async {
    final db = await _db.database;
    await db.update(
        'workout_session',
        {
          'ended_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [sessionId]);
  }

  Future<void> updateSessionNotes(
      {required int sessionId, String? notes}) async {
    final db = await _db.database;
    await db.update(
      'workout_session',
      {
        'notes': notes,
      },
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> deleteSession(int sessionId) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final sessionExercises = await txn.query(
        'session_exercise',
        columns: ['id'],
        where: 'workout_session_id = ?',
        whereArgs: [sessionId],
      );
      if (sessionExercises.isNotEmpty) {
        final ids = sessionExercises.map((row) => row['id'] as int).toList();
        final placeholders = List.filled(ids.length, '?').join(',');
        await txn.delete(
          'set_entry',
          where: 'session_exercise_id IN ($placeholders)',
          whereArgs: ids,
        );
        await txn.delete(
          'session_exercise',
          where: 'workout_session_id = ?',
          whereArgs: [sessionId],
        );
      }
      await txn.delete(
        'workout_session',
        where: 'id = ?',
        whereArgs: [sessionId],
      );
    });
  }

  Future<int> addSessionExercise({
    required int workoutSessionId,
    required int exerciseId,
    required int orderIndex,
  }) async {
    final db = await _db.database;
    return db.insert('session_exercise', {
      'workout_session_id': workoutSessionId,
      'exercise_id': exerciseId,
      'order_index': orderIndex,
    });
  }

  Future<void> deleteSessionExercise(int sessionExerciseId) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'session_exercise',
        columns: ['workout_session_id', 'order_index'],
        where: 'id = ?',
        whereArgs: [sessionExerciseId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      final workoutSessionId = row['workout_session_id'] as int?;
      final orderIndex = row['order_index'] as int?;
      await txn.delete(
        'set_entry',
        where: 'session_exercise_id = ?',
        whereArgs: [sessionExerciseId],
      );
      await txn.delete(
        'session_exercise',
        where: 'id = ?',
        whereArgs: [sessionExerciseId],
      );
      if (workoutSessionId != null && orderIndex != null) {
        await txn.rawUpdate(
          '''
UPDATE session_exercise
SET order_index = order_index - 1
WHERE workout_session_id = ? AND order_index > ?
''',
          [workoutSessionId, orderIndex],
        );
      }
    });
  }

  Future<int> addSetEntry({
    required int sessionExerciseId,
    required int setIndex,
    required String setRole,
    required String weightUnit,
    required String weightMode,
    double? weightValue,
    int? reps,
    int partialReps = 0,
    double? rpe,
    double? rir,
    bool flagWarmup = false,
    bool flagPartials = false,
    bool isAmrap = false,
    int? restSecActual,
  }) async {
    final db = await _db.database;
    return db.insert('set_entry', {
      'session_exercise_id': sessionExerciseId,
      'set_index': setIndex,
      'set_role': setRole,
      'weight_value': weightValue,
      'weight_unit': weightUnit,
      'weight_mode': weightMode,
      'reps': reps,
      'partial_reps': partialReps,
      'rpe': rpe,
      'rir': rir,
      'flag_warmup': flagWarmup ? 1 : 0,
      'flag_partials': flagPartials ? 1 : 0,
      'is_amrap': isAmrap ? 1 : 0,
      'rest_sec_actual': restSecActual,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> getSetsForSessionExercise(
      int sessionExerciseId) async {
    final db = await _db.database;
    return db.query(
      'set_entry',
      where: 'session_exercise_id = ?',
      whereArgs: [sessionExerciseId],
      orderBy: 'set_index ASC',
    );
  }

  Future<List<Map<String, Object?>>> getPreviousSetsForExercise({
    required int exerciseId,
    int? excludeSessionId,
  }) async {
    final db = await _db.database;
    final whereExtra = excludeSessionId == null ? '' : 'AND ws.id != ?';
    final args = excludeSessionId == null
        ? [exerciseId]
        : [exerciseId, excludeSessionId];
    final sessionRows = await db.rawQuery(
      '''
SELECT ws.id
FROM workout_session ws
JOIN session_exercise sx ON sx.workout_session_id = ws.id
WHERE sx.exercise_id = ? $whereExtra
ORDER BY ws.started_at DESC
LIMIT 1
''',
      args,
    );
    if (sessionRows.isEmpty) return [];
    final previousSessionId = sessionRows.first['id'] as int?;
    if (previousSessionId == null) return [];
    return db.rawQuery(
      '''
SELECT se.set_index,
       se.weight_value,
       se.weight_unit,
       se.reps
FROM set_entry se
JOIN session_exercise sx ON sx.id = se.session_exercise_id
WHERE sx.exercise_id = ? AND sx.workout_session_id = ?
ORDER BY se.set_index ASC
''',
      [exerciseId, previousSessionId],
    );
  }

  Future<void> updateSetEntry({
    required int id,
    Object? weightValue = _unchangedSetEntryField,
    Object? reps = _unchangedSetEntryField,
    Object? partialReps = _unchangedSetEntryField,
    Object? rpe = _unchangedSetEntryField,
    Object? rir = _unchangedSetEntryField,
    Object? restSecActual = _unchangedSetEntryField,
  }) async {
    final values = <String, Object?>{};
    if (!identical(weightValue, _unchangedSetEntryField)) {
      values['weight_value'] = weightValue as double?;
    }
    if (!identical(reps, _unchangedSetEntryField)) {
      values['reps'] = reps as int?;
    }
    if (!identical(partialReps, _unchangedSetEntryField)) {
      values['partial_reps'] = (partialReps as int?) ?? 0;
    }
    if (!identical(rpe, _unchangedSetEntryField)) {
      values['rpe'] = rpe as double?;
    }
    if (!identical(rir, _unchangedSetEntryField)) {
      values['rir'] = rir as double?;
    }
    if (!identical(restSecActual, _unchangedSetEntryField)) {
      values['rest_sec_actual'] = restSecActual as int?;
    }
    if (values.isEmpty) return;
    final db = await _db.database;
    await db.update(
      'set_entry',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<String, Object?>?> getSetEntryById(int id) async {
    final db = await _db.database;
    final rows =
        await db.query('set_entry', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> deleteSetEntry(int id) async {
    final db = await _db.database;
    await db.delete('set_entry', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> insertSetEntryWithId(Map<String, Object?> row) async {
    final db = await _db.database;
    await db.insert('set_entry', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Object?>?> getLatestSetForSessionExercise(
      int sessionExerciseId) async {
    final db = await _db.database;
    final rows = await db.query(
      'set_entry',
      where: 'session_exercise_id = ?',
      whereArgs: [sessionExerciseId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<double?> getLatestWeightForSessionExercise(
      int sessionExerciseId) async {
    final db = await _db.database;
    final rows = await db.query(
      'set_entry',
      columns: ['weight_value'],
      where: 'session_exercise_id = ? AND weight_value IS NOT NULL',
      whereArgs: [sessionExerciseId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['weight_value'] as double?;
  }

  Future<List<Map<String, Object?>>> getSessionExercises(int sessionId) async {
    final db = await _db.database;
    return db.rawQuery(
        '''\nSELECT sx.id as session_exercise_id,\n       sx.exercise_id,\n       sx.order_index,\n       e.canonical_name,\n       e.weight_mode_default\nFROM session_exercise sx\nJOIN exercise e ON e.id = sx.exercise_id\nWHERE sx.workout_session_id = ?\nORDER BY sx.order_index ASC\n''',
        [sessionId]);
  }

  Future<int?> getLastCompletedDayIndex(int programId) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
        '''\nSELECT pd.day_index\nFROM workout_session ws\nJOIN program_day pd ON pd.id = ws.program_day_id\nWHERE ws.program_id = ? AND ws.ended_at IS NOT NULL\nORDER BY ws.started_at DESC\nLIMIT 1\n''',
        [programId]);
    if (rows.isEmpty) return null;
    return rows.first['day_index'] as int?;
  }

  Future<List<Map<String, Object?>>> getExerciseSetsSince(
      int exerciseId, DateTime since) async {
    final db = await _db.database;
    return db.rawQuery(
        '''\nSELECT se.*\nFROM set_entry se\nJOIN session_exercise sx ON sx.id = se.session_exercise_id\nWHERE sx.exercise_id = ? AND se.created_at >= ?\nORDER BY se.created_at ASC\n''',
        [exerciseId, since.toIso8601String()]);
  }

  Future<List<Map<String, Object?>>> getCompletedSessions(
      {int limit = 200}) async {
    final db = await _db.database;
    return db.rawQuery(
        '''\nSELECT ws.id,\n       ws.started_at,\n       ws.ended_at,\n       ws.program_id,\n       ws.program_day_id,\n       ws.notes,\n       p.name as program_name,\n       pd.day_name,\n       pd.day_index,\n       COUNT(DISTINCT sx.id) as exercise_count,\n       COUNT(se.id) as set_count\nFROM workout_session ws\nLEFT JOIN program p ON p.id = ws.program_id\nLEFT JOIN program_day pd ON pd.id = ws.program_day_id\nLEFT JOIN session_exercise sx ON sx.workout_session_id = ws.id\nLEFT JOIN set_entry se ON se.session_exercise_id = sx.id\nWHERE ws.ended_at IS NOT NULL\nGROUP BY ws.id\nORDER BY ws.started_at DESC\nLIMIT ?\n''',
        [limit]);
  }

  Future<Map<String, Object?>?> getSessionHeader(int sessionId) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
        '''\nSELECT ws.id,\n       ws.started_at,\n       ws.ended_at,\n       ws.program_id,\n       ws.program_day_id,\n       p.name as program_name,\n       pd.day_name,\n       pd.day_index\nFROM workout_session ws\nLEFT JOIN program p ON p.id = ws.program_id\nLEFT JOIN program_day pd ON pd.id = ws.program_day_id\nWHERE ws.id = ?\nLIMIT 1\n''',
        [sessionId]);
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<List<Map<String, Object?>>> getSessionExerciseSummaries(
      int sessionId) async {
    final db = await _db.database;
    return db.rawQuery(
        '''\nSELECT sx.id as session_exercise_id,\n       sx.exercise_id,\n       sx.order_index,\n       e.canonical_name,\n       COUNT(se.id) as set_count,\n       SUM(CASE\n             WHEN se.weight_value IS NOT NULL AND se.reps IS NOT NULL\n             THEN se.weight_value * se.reps\n             ELSE 0\n           END) as volume,\n       MAX(se.weight_value) as max_weight,\n       MAX(se.created_at) as last_set_at\nFROM session_exercise sx\nJOIN exercise e ON e.id = sx.exercise_id\nLEFT JOIN set_entry se ON se.session_exercise_id = sx.id\nWHERE sx.workout_session_id = ?\nGROUP BY sx.id\nORDER BY sx.order_index ASC\n''',
        [sessionId]);
  }

  Future<List<Map<String, Object?>>> getSessionSets(int sessionId) async {
    final db = await _db.database;
    return db.rawQuery(
        '''\nSELECT sx.id as session_exercise_id,\n       sx.order_index,\n       sx.exercise_id,\n       e.canonical_name,\n       se.id as set_id,\n       se.set_index,\n       se.weight_value,\n       se.weight_unit,\n       se.reps,\n       se.rpe,\n       se.rir,\n       se.flag_warmup,\n       se.flag_partials,\n       se.is_amrap,\n       se.rest_sec_actual\nFROM set_entry se\nJOIN session_exercise sx ON sx.id = se.session_exercise_id\nJOIN exercise e ON e.id = sx.exercise_id\nWHERE sx.workout_session_id = ?\nORDER BY sx.order_index ASC, se.set_index ASC\n''',
        [sessionId]);
  }
}

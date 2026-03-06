import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/program_repo.dart';
import '../../../data/repositories/workout_repo.dart';
import '../../../domain/services/session_service.dart';
import '../programs/day_editor_screen.dart';
import '../session/session_screen.dart';
import '../shell/app_shell_controller.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';

class _DayPreviewExercise {
  const _DayPreviewExercise({required this.name, required this.sets});

  final String name;
  final List<_DayPreviewSet> sets;
}

class _DayPreviewSet {
  const _DayPreviewSet({
    required this.setIndex,
    required this.repsMin,
    required this.repsMax,
    required this.rpeMin,
    required this.rpeMax,
  });

  final int setIndex;
  final int? repsMin;
  final int? repsMax;
  final double? rpeMin;
  final double? rpeMax;
}

class DayPickerScreen extends StatefulWidget {
  const DayPickerScreen({super.key, required this.programId, this.initialVoiceInput});

  final int programId;
  final String? initialVoiceInput;

  @override
  State<DayPickerScreen> createState() => _DayPickerScreenState();
}

class _DayPickerScreenState extends State<DayPickerScreen> {
  late final ProgramRepo _programRepo;
  late final WorkoutRepo _workoutRepo;
  late final SessionService _sessionService;
  Future<Map<int, List<String>>>? _exerciseNamesByDayFuture;

  @override
  void initState() {
    super.initState();
    final db = AppDatabase.instance;
    _programRepo = ProgramRepo(db);
    _workoutRepo = WorkoutRepo(db);
    _sessionService = SessionService(db);
    _exerciseNamesByDayFuture = _programRepo.getExerciseNamesByDayForProgram(widget.programId);
  }

  Future<void> _startSession(int programDayId) async {
    final contextData = await _sessionService.startSessionForProgramDay(
      programId: widget.programId,
      programDayId: programDayId,
    );
    if (!mounted) return;
    final voiceInput = widget.initialVoiceInput;
    if (voiceInput != null && voiceInput.trim().isNotEmpty) {
      AppShellController.instance.setPendingSessionVoice(voiceInput.trim());
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SessionScreen(contextData: contextData)),
    );
    await _syncActiveSessionBanner();
  }

  Future<void> _startSmartDay(List<Map<String, Object?>> days) async {
    if (days.isEmpty) return;
    final lastIndex = await _workoutRepo.getLastCompletedDayIndex(widget.programId);
    final nextIndex = lastIndex == null ? 0 : (lastIndex + 1) % days.length;
    final day = days.firstWhere((d) => d['day_index'] == nextIndex, orElse: () => days.first);
    await _startSession(day['id'] as int);
  }

  Future<void> _syncActiveSessionBanner() async {
    final hasActive = await _workoutRepo.hasActiveSession();
    if (!mounted) return;
    AppShellController.instance.setActiveSession(hasActive);
    AppShellController.instance.setActiveSessionIndicatorHidden(false);
    AppShellController.instance.refreshActiveSession();
  }

  Future<void> _openDayEditor(int programDayId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DayEditorScreen(programDayId: programDayId, programId: widget.programId),
      ),
    );
    if (!mounted) return;
    setState(() {
      _exerciseNamesByDayFuture = _programRepo.getExerciseNamesByDayForProgram(widget.programId);
    });
  }

  Future<List<_DayPreviewExercise>> _loadDayPreviewExercises(int programDayId) async {
    final rows = await _programRepo.getProgramDayExerciseDetails(programDayId);
    final previewRows = <_DayPreviewExercise>[];
    for (final row in rows) {
      final dayExerciseId = row['program_day_exercise_id'] as int;
      final name = (row['canonical_name'] as String?)?.trim();
      final blocks = await _programRepo.getSetPlanBlocks(dayExerciseId);
      previewRows.add(
        _DayPreviewExercise(
          name: name == null || name.isEmpty ? 'Exercise' : name,
          sets: _expandPreviewSets(blocks),
        ),
      );
    }
    return previewRows;
  }

  List<_DayPreviewSet> _expandPreviewSets(List<Map<String, Object?>> blocks) {
    if (blocks.isEmpty) {
      return const [
        _DayPreviewSet(setIndex: 1, repsMin: null, repsMax: null, rpeMin: null, rpeMax: null),
      ];
    }
    final ordered = List<Map<String, Object?>>.from(blocks)
      ..sort((a, b) => ((a['order_index'] as int?) ?? 0).compareTo((b['order_index'] as int?) ?? 0));
    final previewSets = <_DayPreviewSet>[];
    var setIndex = 1;
    for (final block in ordered) {
      final setCount = (block['set_count'] as int?) ?? 0;
      final repsMin = block['reps_min'] as int?;
      final repsMax = block['reps_max'] as int?;
      final rpeMin = _asDouble(block['target_rpe_min']);
      final rpeMax = _asDouble(block['target_rpe_max']);
      final safeSetCount = setCount <= 0 ? 1 : setCount;
      for (var i = 0; i < safeSetCount; i++) {
        previewSets.add(
          _DayPreviewSet(
            setIndex: setIndex,
            repsMin: repsMin,
            repsMax: repsMax,
            rpeMin: rpeMin,
            rpeMax: rpeMax,
          ),
        );
        setIndex += 1;
      }
    }
    return previewSets;
  }

  double? _asDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  String _repsLabel(int? min, int? max) {
    if (min == null && max == null) return '—';
    if (min != null && max != null) {
      if (min == max) return '$min';
      return '$min-$max';
    }
    return '${min ?? max}';
  }

  String _rpeLabel(double? min, double? max) {
    if (min == null && max == null) return '—';
    if (min != null && max != null) {
      if ((min - max).abs() < 0.001) return _formatDecimal(min);
      return '${_formatDecimal(min)}-${_formatDecimal(max)}';
    }
    return _formatDecimal(min ?? max!);
  }

  String _formatDecimal(double value) {
    final fixed = value.toStringAsFixed(2);
    return fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  Future<void> _showDayPreview(Map<String, Object?> day) async {
    final dayId = day['id'] as int;
    final dayName = (day['day_name'] as String?)?.trim();
    final dayIndex = (day['day_index'] as int?) ?? 0;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dayName == null || dayName.isEmpty ? 'Day ${dayIndex + 1}' : dayName,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Day ${dayIndex + 1} Preview',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.65),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(dialogContext).pop();
                          await _openDayEditor(dayId);
                        },
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: FutureBuilder<List<_DayPreviewExercise>>(
                      future: _loadDayPreviewExercises(dayId),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final rows = snapshot.data ?? const <_DayPreviewExercise>[];
                        if (rows.isEmpty) {
                          return const Center(child: Text('No exercises in this day yet.'));
                        }
                        return ListView.separated(
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final headerStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                );
                            return GlassCard(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(row.name, style: Theme.of(context).textTheme.titleMedium),
                                      ),
                                      Text(
                                        '${row.sets.length} sets',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.65),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.surface.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 34,
                                          child: Center(child: Text('Set', style: headerStyle)),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text('Reps', style: headerStyle),
                                        ),
                                        SizedBox(
                                          width: 64,
                                          child: Align(
                                            alignment: Alignment.centerRight,
                                            child: Text('RPE', style: headerStyle),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  ...row.sets.map((setRow) {
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.surface.withOpacity(0.12),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: 34,
                                              child: Center(child: Text('${setRow.setIndex}')),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text('${_repsLabel(setRow.repsMin, setRow.repsMax)} reps'),
                                            ),
                                            SizedBox(
                                              width: 64,
                                              child: Align(
                                                alignment: Alignment.centerRight,
                                                child: Text(_rpeLabel(setRow.rpeMin, setRow.rpeMax)),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        _startSession(dayId);
                      },
                      child: const Text('Start Day'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context).colorScheme.surface,
                        minimumSize: const Size.fromHeight(64),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pick Day'),
        actions: const [SizedBox(width: 72)],
      ),
      body: Stack(
        children: [
          const GlassBackground(),
          FutureBuilder<List<Map<String, Object?>>>(
            future: _programRepo.getProgramDays(widget.programId),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final days = snapshot.data ?? [];
              if (days.isEmpty) {
                return const Center(child: Text('No days yet. Add one in the program editor.'));
              }
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: GlassCard(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_awesome),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('Start Smart Day')),
                          TextButton(
                            onPressed: () => _startSmartDay(days),
                            child: const Text('Start'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: FutureBuilder<Map<int, List<String>>>(
                      future: _exerciseNamesByDayFuture ??=
                          _programRepo.getExerciseNamesByDayForProgram(widget.programId),
                      builder: (context, namesSnapshot) {
                        final namesByDay = namesSnapshot.data ?? const <int, List<String>>{};
                        return ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          itemCount: days.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final day = days[index];
                            final dayId = day['id'] as int;
                            final names = namesByDay[dayId] ?? const <String>[];
                            final description = names.isEmpty ? 'No exercises added yet' : names.join(', ');
                            return GlassCard(
                              padding: EdgeInsets.zero,
                              child: ListTile(
                                title: Text(day['day_name'] as String),
                                subtitle: Text(
                                  description,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.62),
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _showDayPreview(day),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

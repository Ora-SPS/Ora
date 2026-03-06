import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/exercise_repo.dart';
import '../../../data/repositories/program_repo.dart';
import '../history/history_screen.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';

class DayEditorScreen extends StatefulWidget {
  const DayEditorScreen({super.key, required this.programDayId, required this.programId});

  final int programDayId;
  final int programId;

  @override
  State<DayEditorScreen> createState() => _DayEditorScreenState();
}

class _DayEditorScreenState extends State<DayEditorScreen> {
  late final ProgramRepo _programRepo;
  late final ExerciseRepo _exerciseRepo;
  final _dayNameController = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final db = AppDatabase.instance;
    _programRepo = ProgramRepo(db);
    _exerciseRepo = ExerciseRepo(db);
    _load();
  }

  Future<void> _load() async {
    final days = await _programRepo.getProgramDays(widget.programId);
    final day = days.firstWhere((d) => d['id'] == widget.programDayId, orElse: () => {});
    if (day.isNotEmpty) {
      _dayNameController.text = day['day_name'] as String? ?? '';
    }
    setState(() {
      _loaded = true;
    });
  }

  Future<void> _saveDayName() async {
    final name = _dayNameController.text.trim();
    if (name.isEmpty) return;
    await _programRepo.updateProgramDay(id: widget.programDayId, dayName: name);
  }

  Future<void> _addExercise() async {
    final result = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ExerciseSearchSheet(exerciseRepo: _exerciseRepo),
    );

    if (result == null) return;
    final exerciseId = result['id'] as int;
    final existing = await _programRepo.getProgramDayExerciseDetails(widget.programDayId);
    final orderIndex = existing.length;
    final programDayExerciseId = await _programRepo.addProgramDayExercise(
      programDayId: widget.programDayId,
      exerciseId: exerciseId,
      orderIndex: orderIndex,
    );

    await _programRepo.replaceSetPlanBlocks(programDayExerciseId, _defaultBlocks());
    setState(() {});
  }

  List<Map<String, Object?>> _defaultBlocks() {
    return [
      {
        'order_index': 0,
        'role': 'WARMUP',
        'set_count': 2,
        'reps_min': 8,
        'reps_max': 10,
        'rest_sec_min': 60,
        'rest_sec_max': 90,
        'target_rpe_min': null,
        'target_rpe_max': null,
        'target_rir_min': null,
        'target_rir_max': null,
        'load_rule_type': 'NONE',
        'load_rule_min': null,
        'load_rule_max': null,
        'amrap_last_set': 0,
        'partials_target_min': null,
        'partials_target_max': null,
        'notes': null,
      },
      {
        'order_index': 1,
        'role': 'TOP',
        'set_count': 1,
        'reps_min': 6,
        'reps_max': 8,
        'rest_sec_min': 120,
        'rest_sec_max': 180,
        'target_rpe_min': null,
        'target_rpe_max': null,
        'target_rir_min': null,
        'target_rir_max': null,
        'load_rule_type': 'NONE',
        'load_rule_min': null,
        'load_rule_max': null,
        'amrap_last_set': 1,
        'partials_target_min': null,
        'partials_target_max': null,
        'notes': null,
      },
      {
        'order_index': 2,
        'role': 'BACKOFF',
        'set_count': 2,
        'reps_min': 8,
        'reps_max': 12,
        'rest_sec_min': 90,
        'rest_sec_max': 120,
        'target_rpe_min': null,
        'target_rpe_max': null,
        'target_rir_min': null,
        'target_rir_max': null,
        'load_rule_type': 'DROP_PERCENT_FROM_TOP',
        'load_rule_min': 10,
        'load_rule_max': 15,
        'amrap_last_set': 0,
        'partials_target_min': null,
        'partials_target_max': null,
        'notes': null,
      },
    ];
  }

  @override
  void dispose() {
    _dayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Day'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: () async {
              await _saveDayName();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Day saved.')),
              );
            },
          ),
          const SizedBox(width: 72),
        ],
      ),
      body: Stack(
        children: [
          const GlassBackground(),
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _dayNameController,
                  decoration: const InputDecoration(labelText: 'Day name'),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Map<String, Object?>>>(
              future: _programRepo.getProgramDayExerciseDetails(widget.programDayId),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final exercises = snapshot.data ?? [];
                if (exercises.isEmpty) {
                  return const Center(child: Text('Add an exercise.'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: exercises.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final row = exercises[index];
                    final name = row['canonical_name'] as String;
                    final programDayExerciseId = row['program_day_exercise_id'] as int;
                    return GlassCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        title: Text(name),
                        subtitle: const Text('Edit blocks or view stats'),
                        onTap: () async {
                          await showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => _SetPlanEditorSheet(
                              programRepo: _programRepo,
                              programDayExerciseId: programDayExerciseId,
                              exerciseName: name,
                            ),
                          );
                          setState(() {});
                        },
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) async {
                            if (value == 'stats') {
                              if (!mounted) return;
                              await Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => HistoryScreen(
                                    initialExerciseId: row['exercise_id'] as int,
                                    mode: HistoryMode.exercise,
                                  ),
                                ),
                              );
                            } else if (value == 'delete') {
                              await _programRepo.deleteProgramDayExercise(programDayExerciseId);
                              setState(() {});
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'stats', child: Text('View stats')),
                            PopupMenuItem(value: 'delete', child: Text('Remove')),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: GlassCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.add_circle_outline),
                      const SizedBox(width: 12),
                      const Expanded(child: Text('Add Exercise')),
                      TextButton(onPressed: _addExercise, child: const Text('Add')),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExerciseSearchSheet extends StatefulWidget {
  const _ExerciseSearchSheet({required this.exerciseRepo});

  final ExerciseRepo exerciseRepo;

  @override
  State<_ExerciseSearchSheet> createState() => _ExerciseSearchSheetState();
}

class _ExerciseSearchSheetState extends State<_ExerciseSearchSheet> {
  final _controller = TextEditingController();
  List<Map<String, Object?>> _results = [];

  @override
  void initState() {
    super.initState();
    _search('');
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) {
      final all = await widget.exerciseRepo.getAll();
      setState(() {
        _results = all.take(50).toList();
      });
      return;
    }
    final results = await widget.exerciseRepo.search(query, limit: 50);
    setState(() {
      _results = results;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Search exercises',
              border: OutlineInputBorder(),
            ),
            onChanged: _search,
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 360,
            child: ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = _results[index];
                return ListTile(
                  title: Text(item['canonical_name'] as String),
                  subtitle: Text(item['equipment_type'] as String),
                  trailing: IconButton(
                    icon: const Icon(Icons.show_chart),
                    onPressed: () async {
                      if (!mounted) return;
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => HistoryScreen(
                            initialExerciseId: item['id'] as int,
                            mode: HistoryMode.exercise,
                          ),
                        ),
                      );
                    },
                  ),
                  onTap: () => Navigator.of(context).pop(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SetPlanEditorSheet extends StatefulWidget {
  const _SetPlanEditorSheet({
    required this.programRepo,
    required this.programDayExerciseId,
    required this.exerciseName,
  });

  final ProgramRepo programRepo;
  final int programDayExerciseId;
  final String exerciseName;

  @override
  State<_SetPlanEditorSheet> createState() => _SetPlanEditorSheetState();
}

class _SetPlanEditorSheetState extends State<_SetPlanEditorSheet> {
  static const roles = ['WARMUP', 'TOP', 'BACKOFF', 'BACKOFF_PARTIALS'];
  static const loadRules = ['NONE', 'DROP_PERCENT_FROM_TOP', 'PERCENT_OF_TOP'];

  List<_BlockModel> _blocks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await widget.programRepo.getSetPlanBlocks(widget.programDayExerciseId);
    setState(() {
      _blocks = rows.map((row) => _BlockModel.fromRow(row)).toList();
      _loading = false;
    });
  }

  void _addBlock() {
    setState(() {
      _blocks.add(_BlockModel(
        orderIndex: _blocks.length,
        role: 'BACKOFF',
        setCount: 1,
        repsMin: null,
        repsMax: null,
        restMin: null,
        restMax: null,
        loadRuleType: 'NONE',
        loadRuleMin: null,
        loadRuleMax: null,
        amrapLastSet: false,
        targetRpeMin: null,
        targetRpeMax: null,
        targetRirMin: null,
        targetRirMax: null,
        partialsTargetMin: null,
        partialsTargetMax: null,
      ));
    });
  }

  Future<void> _save() async {
    final mapped = _blocks
        .asMap()
        .entries
        .map((entry) => entry.value.toMap(orderIndex: entry.key))
        .toList();
    await widget.programRepo.replaceSetPlanBlocks(widget.programDayExerciseId, mapped);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.exerciseName,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            SizedBox(
              height: 420,
              child: ListView.separated(
                itemCount: _blocks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final block = _blocks[index];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: block.role,
                                  decoration: const InputDecoration(labelText: 'Role'),
                                  items: roles
                                      .map((role) => DropdownMenuItem(value: role, child: Text(role)))
                                      .toList(),
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() => block.role = value);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.setCountController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Sets'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: block.repsMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Reps min'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.repsMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Reps max'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: block.restMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Rest min (s)'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.restMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Rest max (s)'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            initialValue: block.loadRuleType,
                            decoration: const InputDecoration(labelText: 'Load rule'),
                            items: loadRules
                                .map((rule) => DropdownMenuItem(value: rule, child: Text(rule)))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => block.loadRuleType = value);
                            },
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: block.loadRuleMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Load min'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.loadRuleMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Load max'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: block.targetRpeMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'RPE min'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.targetRpeMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'RPE max'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: block.targetRirMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'RIR min'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.targetRirMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'RIR max'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: block.partialsTargetMinController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Partials min'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: block.partialsTargetMaxController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(labelText: 'Partials max'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('AMRAP last set'),
                            value: block.amrapLastSet,
                            onChanged: (value) => setState(() => block.amrapLastSet = value),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => setState(() => _blocks.removeAt(index)),
                              child: const Text('Remove block'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(onPressed: _addBlock, child: const Text('Add block')),
              const Spacer(),
              ElevatedButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _BlockModel {
  _BlockModel({
    required this.orderIndex,
    required this.role,
    required this.setCount,
    required this.repsMin,
    required this.repsMax,
    required this.restMin,
    required this.restMax,
    required this.loadRuleType,
    required this.loadRuleMin,
    required this.loadRuleMax,
    required this.amrapLastSet,
    required this.targetRpeMin,
    required this.targetRpeMax,
    required this.targetRirMin,
    required this.targetRirMax,
    required this.partialsTargetMin,
    required this.partialsTargetMax,
  })  : setCountController = TextEditingController(text: setCount.toString()),
        repsMinController = TextEditingController(text: repsMin?.toString() ?? ''),
        repsMaxController = TextEditingController(text: repsMax?.toString() ?? ''),
        restMinController = TextEditingController(text: restMin?.toString() ?? ''),
        restMaxController = TextEditingController(text: restMax?.toString() ?? ''),
        loadRuleMinController = TextEditingController(text: loadRuleMin?.toString() ?? ''),
        loadRuleMaxController = TextEditingController(text: loadRuleMax?.toString() ?? ''),
        targetRpeMinController = TextEditingController(text: targetRpeMin?.toString() ?? ''),
        targetRpeMaxController = TextEditingController(text: targetRpeMax?.toString() ?? ''),
        targetRirMinController = TextEditingController(text: targetRirMin?.toString() ?? ''),
        targetRirMaxController = TextEditingController(text: targetRirMax?.toString() ?? ''),
        partialsTargetMinController = TextEditingController(text: partialsTargetMin?.toString() ?? ''),
        partialsTargetMaxController = TextEditingController(text: partialsTargetMax?.toString() ?? '');

  int orderIndex;
  String role;
  int setCount;
  int? repsMin;
  int? repsMax;
  int? restMin;
  int? restMax;
  String loadRuleType;
  double? loadRuleMin;
  double? loadRuleMax;
  bool amrapLastSet;
  double? targetRpeMin;
  double? targetRpeMax;
  double? targetRirMin;
  double? targetRirMax;
  int? partialsTargetMin;
  int? partialsTargetMax;

  final TextEditingController setCountController;
  final TextEditingController repsMinController;
  final TextEditingController repsMaxController;
  final TextEditingController restMinController;
  final TextEditingController restMaxController;
  final TextEditingController loadRuleMinController;
  final TextEditingController loadRuleMaxController;
  final TextEditingController targetRpeMinController;
  final TextEditingController targetRpeMaxController;
  final TextEditingController targetRirMinController;
  final TextEditingController targetRirMaxController;
  final TextEditingController partialsTargetMinController;
  final TextEditingController partialsTargetMaxController;

  factory _BlockModel.fromRow(Map<String, Object?> row) {
    return _BlockModel(
      orderIndex: row['order_index'] as int,
      role: row['role'] as String,
      setCount: row['set_count'] as int,
      repsMin: row['reps_min'] as int?,
      repsMax: row['reps_max'] as int?,
      restMin: row['rest_sec_min'] as int?,
      restMax: row['rest_sec_max'] as int?,
      loadRuleType: row['load_rule_type'] as String,
      loadRuleMin: row['load_rule_min'] as double?,
      loadRuleMax: row['load_rule_max'] as double?,
      amrapLastSet: (row['amrap_last_set'] as int? ?? 0) == 1,
      targetRpeMin: row['target_rpe_min'] as double?,
      targetRpeMax: row['target_rpe_max'] as double?,
      targetRirMin: row['target_rir_min'] as double?,
      targetRirMax: row['target_rir_max'] as double?,
      partialsTargetMin: row['partials_target_min'] as int?,
      partialsTargetMax: row['partials_target_max'] as int?,
    );
  }

  Map<String, Object?> toMap({required int orderIndex}) {
    final parsedSetCount = int.tryParse(setCountController.text.trim()) ?? 1;
    return {
      'order_index': orderIndex,
      'role': role,
      'set_count': parsedSetCount,
      'reps_min': int.tryParse(repsMinController.text.trim()),
      'reps_max': int.tryParse(repsMaxController.text.trim()),
      'rest_sec_min': int.tryParse(restMinController.text.trim()),
      'rest_sec_max': int.tryParse(restMaxController.text.trim()),
      'target_rpe_min': double.tryParse(targetRpeMinController.text.trim()),
      'target_rpe_max': double.tryParse(targetRpeMaxController.text.trim()),
      'target_rir_min': double.tryParse(targetRirMinController.text.trim()),
      'target_rir_max': double.tryParse(targetRirMaxController.text.trim()),
      'load_rule_type': loadRuleType,
      'load_rule_min': double.tryParse(loadRuleMinController.text.trim()),
      'load_rule_max': double.tryParse(loadRuleMaxController.text.trim()),
      'amrap_last_set': amrapLastSet ? 1 : 0,
      'partials_target_min': int.tryParse(partialsTargetMinController.text.trim()),
      'partials_target_max': int.tryParse(partialsTargetMaxController.text.trim()),
      'notes': null,
    };
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/program_repo.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';
import 'day_editor_screen.dart';

class _EditableProgramDay {
  _EditableProgramDay({
    required this.name,
    this.id,
  });

  _EditableProgramDay.clone(_EditableProgramDay other)
      : id = other.id,
        name = other.name;

  factory _EditableProgramDay.fromRow(Map<String, Object?> row) {
    return _EditableProgramDay(
      id: row['id'] as int?,
      name: row['day_name'] as String? ?? '',
    );
  }

  int? id;
  String name;
}

class ProgramEditorScreen extends StatefulWidget {
  const ProgramEditorScreen({
    super.key,
    required this.programId,
    this.isNewProgram = false,
  });

  final int programId;
  final bool isNewProgram;

  @override
  State<ProgramEditorScreen> createState() => _ProgramEditorScreenState();
}

class _ProgramEditorScreenState extends State<ProgramEditorScreen> {
  late final ProgramRepo _programRepo;
  late final TextEditingController _nameController;
  String _initialProgramName = '';
  List<_EditableProgramDay> _days = [];
  List<_EditableProgramDay> _initialDays = [];
  Set<int> _initialDayIds = <int>{};
  final Map<int, Map<String, Object?>> _daySnapshots = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _programRepo = ProgramRepo(AppDatabase.instance);
    _nameController = TextEditingController();
    _load();
  }

  Future<void> _load() async {
    final programs = await _programRepo.getPrograms();
    final program = programs.firstWhere((p) => p['id'] == widget.programId,
        orElse: () => {});
    final days = await _programRepo.getProgramDays(widget.programId);
    if (program.isNotEmpty) {
      _initialProgramName = program['name'] as String? ?? '';
      _nameController.text = _initialProgramName;
    }
    setState(() {
      _days = days.map(_EditableProgramDay.fromRow).toList();
      _initialDays = _days.map(_EditableProgramDay.clone).toList();
      _initialDayIds = {
        for (final day in _days)
          if (day.id != null) day.id!,
      };
      _loaded = true;
    });
  }

  Future<bool> _saveProgram() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a program name.')),
      );
      return false;
    }
    await _programRepo.updateProgram(id: widget.programId, name: name);
    final existingDays = await _programRepo.getProgramDays(widget.programId);
    final existingById = <int, Map<String, Object?>>{
      for (final row in existingDays)
        if (row['id'] is int) row['id'] as int: row,
    };
    final keptIds =
        _days.where((day) => day.id != null).map((day) => day.id!).toSet();
    for (final dayId in existingById.keys) {
      if (keptIds.contains(dayId)) continue;
      await _programRepo.deleteProgramDay(dayId);
    }
    for (var index = 0; index < _days.length; index++) {
      final day = _days[index];
      if (day.id == null) {
        day.id = await _programRepo.addProgramDay(
          programId: widget.programId,
          dayIndex: index,
          dayName: day.name,
        );
        continue;
      }
      await _programRepo.updateProgramDay(id: day.id!, dayName: day.name);
      await _programRepo.updateProgramDayOrder(id: day.id!, dayIndex: index);
    }
    _initialProgramName = name;
    _initialDays = _days.map(_EditableProgramDay.clone).toList();
    _initialDayIds = {
      for (final day in _days)
        if (day.id != null) day.id!,
    };
    _daySnapshots.clear();
    if (!mounted) return true;
    setState(() {});
    return true;
  }

  Future<void> _addDay() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Day'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Day name'),
            autofocus: true,
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim()),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );

    final dayName = result ?? '';
    if (dayName.isEmpty) return;
    setState(() {
      _days.add(_EditableProgramDay(name: dayName));
    });
  }

  Future<void> _refreshDayName(int dayId) async {
    final rows = await _programRepo.getProgramDays(widget.programId);
    final refreshed = rows.where((row) => row['id'] == dayId);
    if (refreshed.isEmpty || !mounted) return;
    final dayName = refreshed.first['day_name'] as String? ?? '';
    setState(() {
      final localIndex = _days.indexWhere((day) => day.id == dayId);
      if (localIndex == -1) return;
      _days[localIndex].name = dayName;
    });
  }

  Future<int> _ensurePersistedDay(
    _EditableProgramDay day, {
    required int dayIndex,
  }) async {
    final existingId = day.id;
    if (existingId != null) return existingId;
    final persistedId = await _programRepo.addProgramDay(
      programId: widget.programId,
      dayIndex: dayIndex,
      dayName: day.name,
    );
    day.id = persistedId;
    if (!mounted) return persistedId;
    setState(() {});
    return persistedId;
  }

  Future<void> _openDayEditor(_EditableProgramDay day, int index) async {
    final dayId = await _ensurePersistedDay(day, dayIndex: index);
    if (_initialDayIds.contains(dayId)) {
      await _captureDaySnapshot(dayId);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DayEditorScreen(
          programDayId: dayId,
          programId: widget.programId,
        ),
      ),
    );
    await _refreshDayName(dayId);
  }

  Future<void> _captureDaySnapshot(int dayId) async {
    if (_daySnapshots.containsKey(dayId)) return;
    _daySnapshots[dayId] = await _programRepo.createProgramDaySnapshot(dayId);
  }

  Future<void> _restoreCapturedDaySnapshots() async {
    for (final entry in _daySnapshots.entries) {
      await _programRepo.restoreProgramDaySnapshot(entry.key, entry.value);
    }
    final currentDays = await _programRepo.getProgramDays(widget.programId);
    for (final row in currentDays) {
      final dayId = row['id'] as int?;
      if (dayId == null || _initialDayIds.contains(dayId)) continue;
      await _programRepo.deleteProgramDay(dayId);
    }
  }

  bool _hasLocalChanges() {
    if (_nameController.text.trim() != _initialProgramName) return true;
    if (_days.length != _initialDays.length) return true;
    for (var index = 0; index < _days.length; index++) {
      final current = _days[index];
      final initial = _initialDays[index];
      if (current.id != initial.id || current.name != initial.name) return true;
    }
    return false;
  }

  bool _jsonMapsEqual(Map<String, Object?> left, Map<String, Object?> right) {
    return jsonEncode(left) == jsonEncode(right);
  }

  Future<bool> _hasCapturedDayChanges() async {
    for (final entry in _daySnapshots.entries) {
      final current = await _programRepo.createProgramDaySnapshot(entry.key);
      if (!_jsonMapsEqual(entry.value, current)) return true;
    }
    final currentDays = await _programRepo.getProgramDays(widget.programId);
    for (final row in currentDays) {
      final dayId = row['id'] as int?;
      if (dayId != null && !_initialDayIds.contains(dayId)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _hasPendingChanges() async {
    if (_hasLocalChanges()) return true;
    return _hasCapturedDayChanges();
  }

  void _removeDayWithUndo(_EditableProgramDay day, int index) {
    setState(() {
      _days.removeAt(index);
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Day removed'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            if (!mounted) return;
            setState(() {
              final restoreIndex = index.clamp(0, _days.length);
              _days.insert(restoreIndex, day);
            });
          },
        ),
      ),
    );
  }

  Widget _buildAddDayCard() {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _addDay,
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.16),
          foregroundColor: theme.colorScheme.primary,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: const Text(
          'Add Day',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Future<void> _cancelEditing() async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final hasPendingChanges = await _hasPendingChanges();
    if (!hasPendingChanges) {
      if (widget.isNewProgram) {
        await _programRepo.deleteProgram(widget.programId);
      }
      if (!mounted) return;
      Navigator.of(context).pop(false);
      return;
    }
    if (!mounted) return;
    final shouldDiscard = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Discard changes?'),
          content: const Text(
            'This will discard any unsaved program changes made in this editor.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep Editing'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Discard'),
            ),
          ],
        );
      },
    );
    if (shouldDiscard != true) return;
    if (widget.isNewProgram) {
      await _programRepo.deleteProgram(widget.programId);
    } else {
      await _restoreCapturedDaySnapshots();
    }
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        leadingWidth: 92,
        leading: TextButton(
          onPressed: _cancelEditing,
          child: const Text('Cancel'),
        ),
        title: const Text('Edit Program'),
        actions: [
          SizedBox(
            width: 92,
            child: TextButton(
              onPressed: () async {
                final saved = await _saveProgram();
                if (!context.mounted || !saved) return;
                Navigator.of(context).pop(true);
              },
              child: const Text('Save'),
            ),
          ),
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
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Program name'),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (_days.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('Add your first day.'),
                      ),
                    for (var index = 0; index < _days.length; index++) ...[
                      Builder(
                        builder: (context) {
                          final day = _days[index];
                          final dayId = day.id;
                          final tile = GlassCard(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              title: Text(day.name),
                              subtitle: Text(
                                'Day ${index + 1}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.62),
                                      fontSize: 12,
                                    ),
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                await _openDayEditor(day, index);
                              },
                            ),
                          );
                          return Dismissible(
                            key: ValueKey(dayId ?? day),
                            direction: DismissDirection.startToEnd,
                            background: Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Icon(Icons.delete_outline),
                            ),
                            onDismissed: (_) => _removeDayWithUndo(day, index),
                            child: tile,
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    _buildAddDayCard(),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

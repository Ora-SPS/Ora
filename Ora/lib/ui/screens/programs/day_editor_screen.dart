import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/program_repo.dart';
import '../../../domain/services/exercise_matcher.dart';
import '../history/exercise_catalog_screen.dart';
import '../history/history_screen.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';

class _PendingExerciseRemoval {
  _PendingExerciseRemoval({
    required this.row,
    required this.index,
    required this.timer,
  });

  final Map<String, Object?> row;
  final int index;
  final Timer timer;
}

class DayEditorScreen extends StatefulWidget {
  const DayEditorScreen(
      {super.key, required this.programDayId, required this.programId});

  final int programDayId;
  final int programId;

  @override
  State<DayEditorScreen> createState() => _DayEditorScreenState();
}

class _DayEditorScreenState extends State<DayEditorScreen> {
  late final ProgramRepo _programRepo;
  final _dayNameController = TextEditingController();
  List<Map<String, Object?>> _exerciseRows = [];
  _PendingExerciseRemoval? _pendingExerciseRemoval;
  bool _loaded = false;
  bool _isLeaving = false;

  @override
  void initState() {
    super.initState();
    final db = AppDatabase.instance;
    _programRepo = ProgramRepo(db);
    _load();
  }

  Future<void> _load() async {
    final days = await _programRepo.getProgramDays(widget.programId);
    final day = days.firstWhere((d) => d['id'] == widget.programDayId,
        orElse: () => {});
    final exercises =
        await _programRepo.getProgramDayExerciseDetails(widget.programDayId);
    if (day.isNotEmpty) {
      _dayNameController.text = day['day_name'] as String? ?? '';
    }
    setState(() {
      _exerciseRows =
          exercises.map((row) => Map<String, Object?>.from(row)).toList();
      _loaded = true;
    });
  }

  Future<void> _saveDayName() async {
    final name = _dayNameController.text.trim();
    if (name.isEmpty) return;
    await _programRepo.updateProgramDay(id: widget.programDayId, dayName: name);
  }

  Future<void> _addExercise() async {
    final result = await Navigator.of(context).push<ExerciseMatch>(
      MaterialPageRoute(
        builder: (_) => const ExerciseCatalogScreen(selectionMode: true),
      ),
    );

    if (result == null) return;
    final exerciseId = result.id;
    final orderIndex = _exerciseRows.length;
    final programDayExerciseId = await _programRepo.addProgramDayExercise(
      programDayId: widget.programDayId,
      exerciseId: exerciseId,
      orderIndex: orderIndex,
    );

    await _programRepo.replaceSetPlanBlocks(
        programDayExerciseId, _defaultBlocks());
    if (!mounted) return;
    setState(() {
      _exerciseRows.add({
        'program_day_exercise_id': programDayExerciseId,
        'exercise_id': exerciseId,
        'order_index': orderIndex,
        'notes': null,
        'canonical_name': result.name,
        'weight_mode_default': null,
      });
    });
  }

  Widget _buildAddExerciseCard() {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _addExercise,
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
          'Add Exercise',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
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
    _pendingExerciseRemoval?.timer.cancel();
    _dayNameController.dispose();
    super.dispose();
  }

  Future<void> _reindexExercises() async {
    for (var index = 0; index < _exerciseRows.length; index++) {
      final row = Map<String, Object?>.from(_exerciseRows[index]);
      row['order_index'] = index;
      _exerciseRows[index] = row;
      await _programRepo.updateProgramDayExerciseOrder(
        id: row['program_day_exercise_id'] as int,
        orderIndex: index,
      );
    }
  }

  Future<void> _finalizePendingExerciseRemoval() async {
    final pending = _pendingExerciseRemoval;
    if (pending == null) return;
    _pendingExerciseRemoval = null;
    pending.timer.cancel();
    await _programRepo.deleteProgramDayExercise(
        pending.row['program_day_exercise_id'] as int);
    await _reindexExercises();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _scheduleExerciseRemoval(Map<String, Object?> row) async {
    await _finalizePendingExerciseRemoval();
    final currentIndex = _exerciseRows.indexOf(row);
    if (currentIndex == -1) return;
    final removedRow = Map<String, Object?>.from(row);
    setState(() {
      _exerciseRows.removeAt(currentIndex);
    });
    final removal = _PendingExerciseRemoval(
      row: removedRow,
      index: currentIndex,
      timer: Timer(const Duration(seconds: 3), () {
        unawaited(_finalizePendingExerciseRemoval());
      }),
    );
    _pendingExerciseRemoval = removal;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Exercise removed'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            final pending = _pendingExerciseRemoval;
            if (pending == null) return;
            pending.timer.cancel();
            _pendingExerciseRemoval = null;
            if (!mounted) return;
            setState(() {
              final restoreIndex = pending.index.clamp(0, _exerciseRows.length);
              _exerciseRows.insert(restoreIndex, pending.row);
            });
          },
        ),
      ),
    );
  }

  Future<void> _exitAndSave() async {
    if (_isLeaving) {
      // Recover from stale exit state that can survive hot reloads.
      _isLeaving = false;
    }
    _isLeaving = true;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await _finalizePendingExerciseRemoval();
    await _saveDayName();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        centerTitle: true,
        leadingWidth: kToolbarHeight,
        title: const Text('Edit Day'),
        leading: IconButton(
          onPressed: _exitAndSave,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        actions: const [
          SizedBox(width: kToolbarHeight),
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
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (_exerciseRows.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('Add an exercise.'),
                      ),
                    for (var index = 0;
                        index < _exerciseRows.length;
                        index++) ...[
                      Builder(
                        builder: (context) {
                          final row = _exerciseRows[index];
                          final name = row['canonical_name'] as String;
                          final programDayExerciseId =
                              row['program_day_exercise_id'] as int;
                          final tile = GlassCard(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              title: Text(name),
                              subtitle: Text(
                                'Edit Exercise or View Stats',
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
                              onTap: () async {
                                await showDialog<void>(
                                  context: context,
                                  barrierColor: Colors.black54,
                                  builder: (_) => _SetPlanEditorSheet(
                                    programRepo: _programRepo,
                                    programDayExerciseId: programDayExerciseId,
                                    exerciseName: name,
                                  ),
                                );
                                if (!mounted) return;
                                setState(() {});
                              },
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) async {
                                  if (value == 'stats') {
                                    if (!mounted) return;
                                    await Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => HistoryScreen(
                                          initialExerciseId:
                                              row['exercise_id'] as int,
                                          mode: HistoryMode.exercise,
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  await _scheduleExerciseRemoval(row);
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'stats',
                                    child: Text('View stats'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Remove'),
                                  ),
                                ],
                              ),
                            ),
                          );
                          return Dismissible(
                            key: ValueKey(programDayExerciseId),
                            direction: DismissDirection.startToEnd,
                            background: Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withValues(
                                  alpha: 0.28,
                                ),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Icon(Icons.delete_outline),
                            ),
                            onDismissed: (_) {
                              unawaited(_scheduleExerciseRemoval(row));
                            },
                            child: tile,
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    _buildAddExerciseCard(),
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
  static const _numberPadReservedHeight = 460.0;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _scrollViewportKey = GlobalKey();
  final GlobalKey _numberPadKey = GlobalKey();
  final Object _numberPadTapGroup = Object();
  List<_BlockModel> _blocks = [];
  _BlockModel? _pendingRemovedBlock;
  int? _pendingRemovedBlockIndex;
  Timer? _pendingRemovedBlockTimer;
  String? _activeNumberPadFieldKey;
  String _activeNumberPadTitle = '';
  String _activeNumberPadRawValue = '';
  String _activeNumberPadOriginalText = '';
  bool _activeNumberPadAllowDecimal = false;
  bool _numberPadReplacePending = false;
  final TextEditingController _inlineEditDisplayController =
      TextEditingController();
  final FocusNode _inlineEditDisplayFocusNode = FocusNode();
  TextEditingController? _activeNumberPadController;
  void Function(String rawValue)? _activeNumberPadApply;
  Timer? _numberPadCaretTimer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pendingRemovedBlockTimer?.cancel();
    _numberPadCaretTimer?.cancel();
    _inlineEditDisplayFocusNode.dispose();
    _inlineEditDisplayController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final rows =
        await widget.programRepo.getSetPlanBlocks(widget.programDayExerciseId);
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
        restSeconds: 90,
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
    await widget.programRepo
        .replaceSetPlanBlocks(widget.programDayExerciseId, mapped);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _removeBlockWithUndo(int index) {
    if (index < 0 || index >= _blocks.length) return;
    final removed = _blocks[index];
    _pendingRemovedBlockTimer?.cancel();
    setState(() {
      _blocks.removeAt(index);
      _pendingRemovedBlock = removed;
      _pendingRemovedBlockIndex = index;
    });
    _pendingRemovedBlockTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _pendingRemovedBlock = null;
        _pendingRemovedBlockIndex = null;
        _pendingRemovedBlockTimer = null;
      });
    });
  }

  void _undoBlockRemoval() {
    final removed = _pendingRemovedBlock;
    final removedIndex = _pendingRemovedBlockIndex;
    if (removed == null || removedIndex == null) return;
    _pendingRemovedBlockTimer?.cancel();
    setState(() {
      final restoreIndex = removedIndex.clamp(0, _blocks.length);
      _blocks.insert(restoreIndex, removed);
      _pendingRemovedBlock = null;
      _pendingRemovedBlockIndex = null;
      _pendingRemovedBlockTimer = null;
    });
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'WARMUP':
        return 'Warm-up';
      case 'TOP':
        return 'Top';
      case 'BACKOFF':
        return 'Back-off';
      case 'BACKOFF_PARTIALS':
        return 'Partials';
      default:
        return role;
    }
  }

  TextStyle? _sectionLabelStyle(ThemeData theme) {
    return theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
      fontSize: 12,
      fontWeight: FontWeight.w600,
    );
  }

  String? _formatRpeSummary(_BlockModel block) {
    final min = double.tryParse(block.targetRpeMinController.text.trim());
    final max = double.tryParse(block.targetRpeMaxController.text.trim());
    final start = min ?? max;
    final end = max ?? min;
    if (start == null || end == null) return null;
    String formatValue(double value) {
      return value == value.roundToDouble()
          ? value.toStringAsFixed(0)
          : value.toString();
    }

    if (start == end) {
      return 'RPE ${formatValue(start)}';
    }
    return 'RPE ${formatValue(start)}-${formatValue(end)}';
  }

  void _handleRestInputChanged(_BlockModel block, String value) {
    final formatted = _BlockModel.formatEditableRestInput(value);
    if (block.restController.text == formatted) return;
    block.restController.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }

  Future<void> _bringFieldIntoView(BuildContext fieldContext) async {
    if (Scrollable.maybeOf(fieldContext) == null) return;
    final mediaQuery = MediaQuery.of(context);
    await WidgetsBinding.instance.endOfFrame;
    if (!fieldContext.mounted) return;
    try {
      if (_activeNumberPadFieldKey == null) {
        await Scrollable.ensureVisible(
          fieldContext,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: 0.16,
        );
        return;
      }
      final fieldRenderObject = fieldContext.findRenderObject();
      final viewportRenderObject =
          _scrollViewportKey.currentContext?.findRenderObject();
      if (fieldRenderObject is! RenderBox ||
          !fieldRenderObject.attached ||
          viewportRenderObject is! RenderBox ||
          !viewportRenderObject.attached) {
        return;
      }
      final fieldBottomRight = fieldRenderObject.localToGlobal(
        Offset(fieldRenderObject.size.width, fieldRenderObject.size.height),
      );
      final viewportTopLeft = viewportRenderObject.localToGlobal(Offset.zero);
      final viewportBottomRight = viewportRenderObject.localToGlobal(
        Offset(
          viewportRenderObject.size.width,
          viewportRenderObject.size.height,
        ),
      );
      final numberPadRenderObject =
          _numberPadKey.currentContext?.findRenderObject();
      final numpadTop =
          numberPadRenderObject is RenderBox && numberPadRenderObject.attached
              ? numberPadRenderObject.localToGlobal(Offset.zero).dy
              : mediaQuery.size.height -
                  (mediaQuery.padding.bottom + _numberPadReservedHeight);
      final visibleTop = viewportTopLeft.dy + 8;
      final visibleBottom = math.min(
            viewportBottomRight.dy,
            numpadTop,
          ) -
          24;
      if (visibleBottom <= visibleTop) {
        return;
      }
      const fieldBottomMargin = 12.0;
      final targetFieldBottom = visibleBottom - fieldBottomMargin;
      final position = _scrollController.position;
      final delta = fieldBottomRight.dy - targetFieldBottom;
      if (delta.abs() <= 1) return;
      final targetOffset = (_scrollController.offset + delta).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if ((targetOffset - _scrollController.offset).abs() <= 1) return;
      await _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    } catch (_) {
      // Ignore visibility failures from detached contexts.
    }
  }

  void _startNumberPadCaret() {
    _numberPadCaretTimer?.cancel();
    _syncInlineEditDisplayState();
  }

  void _syncInlineEditDisplayState() {
    final fieldKey = _activeNumberPadFieldKey;
    if (fieldKey == null) {
      if (_inlineEditDisplayController.text.isNotEmpty ||
          _inlineEditDisplayController.selection.baseOffset != 0 ||
          _inlineEditDisplayController.selection.extentOffset != 0) {
        _inlineEditDisplayController.value = const TextEditingValue();
      }
      if (_inlineEditDisplayFocusNode.hasFocus) {
        _inlineEditDisplayFocusNode.unfocus();
      }
      return;
    }
    final value = _activeNumberPadController?.text ?? '';
    final nextValue = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    if (_inlineEditDisplayController.value != nextValue) {
      _inlineEditDisplayController.value = nextValue;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _activeNumberPadFieldKey != fieldKey) return;
      if (!_inlineEditDisplayFocusNode.hasFocus) {
        _inlineEditDisplayFocusNode.requestFocus();
      }
    });
  }

  void _closeNumberPad({bool revertCurrentField = false}) {
    if (_activeNumberPadFieldKey == null) return;
    if (revertCurrentField) {
      _activeNumberPadController?.text = _activeNumberPadOriginalText;
    }
    _numberPadCaretTimer?.cancel();
    setState(() {
      _activeNumberPadFieldKey = null;
      _activeNumberPadTitle = '';
      _activeNumberPadRawValue = '';
      _activeNumberPadOriginalText = '';
      _activeNumberPadAllowDecimal = false;
      _numberPadReplacePending = false;
      _activeNumberPadController = null;
      _activeNumberPadApply = null;
    });
    _syncInlineEditDisplayState();
  }

  void _activateNumberPad({
    required String title,
    required String fieldKey,
    required TextEditingController controller,
    required String initialRawValue,
    required void Function(String rawValue) applyRawValue,
    required BuildContext fieldContext,
    bool allowDecimal = false,
  }) {
    final rawValue = initialRawValue.trim();
    if (_activeNumberPadFieldKey == fieldKey) {
      setState(() {
        _numberPadReplacePending = _numberPadReplacePending
            ? false
            : _activeNumberPadRawValue.isNotEmpty;
      });
      _startNumberPadCaret();
      unawaited(_bringFieldIntoView(fieldContext));
      return;
    }
    setState(() {
      _activeNumberPadFieldKey = fieldKey;
      _activeNumberPadTitle = title;
      _activeNumberPadRawValue = rawValue;
      _activeNumberPadOriginalText = controller.text;
      _activeNumberPadAllowDecimal = allowDecimal;
      _numberPadReplacePending = rawValue.isNotEmpty;
      _activeNumberPadController = controller;
      _activeNumberPadApply = applyRawValue;
    });
    _startNumberPadCaret();
    unawaited(_bringFieldIntoView(fieldContext));
  }

  void _applyNumberPadRawValue(String rawValue) {
    _activeNumberPadApply?.call(rawValue);
    if (!mounted) return;
    setState(() {});
    _syncInlineEditDisplayState();
  }

  void _appendNumberPadChar(String value) {
    if (_activeNumberPadFieldKey == null) return;
    var nextRaw = _numberPadReplacePending ? '' : _activeNumberPadRawValue;
    if (_activeNumberPadAllowDecimal && value == '.') {
      if (nextRaw.contains('.')) return;
      nextRaw = nextRaw.isEmpty ? '0.' : '$nextRaw.';
    } else {
      nextRaw = '$nextRaw$value';
    }
    setState(() {
      _numberPadReplacePending = false;
      _activeNumberPadRawValue = nextRaw;
    });
    _applyNumberPadRawValue(nextRaw);
  }

  void _backspaceNumberPad() {
    if (_activeNumberPadFieldKey == null) return;
    var nextRaw = _activeNumberPadRawValue;
    if (_numberPadReplacePending) {
      nextRaw = '';
    } else if (nextRaw.isNotEmpty) {
      nextRaw = nextRaw.substring(0, nextRaw.length - 1);
    } else {
      return;
    }
    setState(() {
      _numberPadReplacePending = false;
      _activeNumberPadRawValue = nextRaw;
    });
    _applyNumberPadRawValue(nextRaw);
  }

  void _clearNumberPad() {
    if (_activeNumberPadFieldKey == null) return;
    setState(() {
      _numberPadReplacePending = false;
      _activeNumberPadRawValue = '';
    });
    _applyNumberPadRawValue('');
  }

  void _confirmNumberPad() {
    _closeNumberPad();
  }

  void _activateIntegerField({
    required String title,
    required String fieldKey,
    required TextEditingController controller,
    required BuildContext fieldContext,
  }) {
    _activateNumberPad(
      title: title,
      fieldKey: fieldKey,
      controller: controller,
      initialRawValue: controller.text,
      fieldContext: fieldContext,
      applyRawValue: (rawValue) {
        controller.text = rawValue;
      },
    );
  }

  void _activateDecimalField({
    required String title,
    required String fieldKey,
    required TextEditingController controller,
    required BuildContext fieldContext,
  }) {
    _activateNumberPad(
      title: title,
      fieldKey: fieldKey,
      controller: controller,
      initialRawValue: controller.text,
      fieldContext: fieldContext,
      allowDecimal: true,
      applyRawValue: (rawValue) {
        controller.text = rawValue;
      },
    );
  }

  void _activateRestField(
    _BlockModel block, {
    required String fieldKey,
    required BuildContext fieldContext,
  }) {
    _activateNumberPad(
      title: 'Rest Time',
      fieldKey: fieldKey,
      controller: block.restController,
      initialRawValue:
          block.restController.text.replaceAll(RegExp(r'[^0-9]'), ''),
      fieldContext: fieldContext,
      applyRawValue: (rawValue) {
        _handleRestInputChanged(block, rawValue);
      },
    );
  }

  InputDecoration _fieldDecoration(
    BuildContext context, {
    String? hintText,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        color: scheme.onSurface.withValues(alpha: 0.42),
      ),
      isDense: true,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.44),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.24)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.24)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.7)),
      ),
    );
  }

  BoxDecoration _tapFieldDecoration(BuildContext context, String fieldKey) {
    final scheme = Theme.of(context).colorScheme;
    final isActive = _activeNumberPadFieldKey == fieldKey;
    return BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.44),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: isActive
            ? scheme.primary.withValues(alpha: 0.7)
            : scheme.outline.withValues(alpha: 0.24),
      ),
    );
  }

  Widget _buildInlineEditingField({
    required TextStyle? style,
    required Color cursorColor,
  }) {
    return IgnorePointer(
      child: EditableText(
        controller: _inlineEditDisplayController,
        focusNode: _inlineEditDisplayFocusNode,
        readOnly: true,
        showCursor: true,
        backgroundCursorColor: Colors.transparent,
        selectionColor: Colors.transparent,
        selectionControls: null,
        rendererIgnoresPointer: true,
        maxLines: 1,
        textAlign: TextAlign.left,
        style: style ?? const TextStyle(),
        cursorColor: cursorColor,
        keyboardType: TextInputType.none,
      ),
    );
  }

  Widget _buildSelectedInlineLabel({
    required String value,
    required TextStyle? style,
    required Color textColor,
    required Color highlightColor,
  }) {
    return Text(
      value.isEmpty ? ' ' : value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.left,
      softWrap: false,
      style: style?.copyWith(
        color: textColor,
        backgroundColor: highlightColor,
      ),
    );
  }

  Widget _buildTapFieldText({
    required BuildContext context,
    required String fieldKey,
    required String value,
    required String hintText,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final hasValue = value.isNotEmpty;
    final isActive = _activeNumberPadFieldKey == fieldKey;
    final isSelected = isActive && _numberPadReplacePending && hasValue;
    final baseStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: hasValue
              ? scheme.onSurface
              : scheme.onSurface.withValues(alpha: 0.42),
        );

    if (isSelected) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _buildSelectedInlineLabel(
          value: value,
          style: baseStyle,
          textColor: scheme.onSurface,
          highlightColor: scheme.primary.withValues(alpha: 0.2),
        ),
      );
    }

    if (isActive) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _buildInlineEditingField(
          style: baseStyle?.copyWith(
            color: scheme.onSurface,
          ),
          cursorColor: scheme.primary,
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        hasValue ? value : hintText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.left,
        softWrap: false,
        style: baseStyle,
      ),
    );
  }

  Widget _buildFieldLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: _sectionLabelStyle(Theme.of(context))),
    );
  }

  Widget _buildNumberField(
    BuildContext context, {
    required TextEditingController controller,
    required String label,
    required String hintText,
    required String fieldKey,
    required void Function(BuildContext fieldContext) onTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(context, label),
        Builder(
          builder: (fieldContext) => TapRegion(
            groupId: _numberPadTapGroup,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onTap(fieldContext),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: _tapFieldDecoration(context, fieldKey),
                child: _buildTapFieldText(
                  context: context,
                  fieldKey: fieldKey,
                  value: controller.text,
                  hintText: hintText,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRangeFields(
    BuildContext context, {
    required String title,
    required TextEditingController startController,
    required TextEditingController endController,
    required String startHint,
    required String endHint,
    required String startFieldKey,
    required String endFieldKey,
    required void Function(BuildContext fieldContext) onStartTap,
    required void Function(BuildContext fieldContext) onEndTap,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(context, title),
        Row(
          children: [
            Expanded(
              child: Builder(
                builder: (fieldContext) => TapRegion(
                  groupId: _numberPadTapGroup,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onStartTap(fieldContext),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: _tapFieldDecoration(context, startFieldKey),
                      child: _buildTapFieldText(
                        context: context,
                        fieldKey: startFieldKey,
                        value: startController.text,
                        hintText: startHint,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Builder(
                builder: (fieldContext) => TapRegion(
                  groupId: _numberPadTapGroup,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onEndTap(fieldContext),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: _tapFieldDecoration(context, endFieldKey),
                      child: _buildTapFieldText(
                        context: context,
                        fieldKey: endFieldKey,
                        value: endController.text,
                        hintText: endHint,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRoleField(BuildContext context, _BlockModel block) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(context, 'Role of Set'),
        DropdownButtonFormField<String>(
          initialValue: block.role,
          isExpanded: true,
          decoration: _fieldDecoration(context),
          selectedItemBuilder: (context) {
            return roles
                .map(
                  (role) => Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _roleLabel(role),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList();
          },
          items: roles
              .map(
                (role) => DropdownMenuItem<String>(
                  value: role,
                  child:
                      Text(_roleLabel(role), overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => block.role = value);
          },
        ),
      ],
    );
  }

  Widget _buildBlockCard(
    BuildContext context,
    _BlockModel block,
    int index,
  ) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(16),
      radius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Set Variation ${index + 1}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        _roleLabel(block.role),
                        _formatRpeSummary(block),
                      ].whereType<String>().join(' • '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.62),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _removeBlockWithUndo(index),
                tooltip: 'Remove set variation',
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildRoleField(context, block),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _buildNumberField(
                  context,
                  controller: block.setCountController,
                  label: '# of Sets',
                  hintText: '1',
                  fieldKey: 'set-count-$index',
                  onTap: (fieldContext) => _activateIntegerField(
                    title: '# of Sets',
                    fieldKey: 'set-count-$index',
                    controller: block.setCountController,
                    fieldContext: fieldContext,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildNumberField(
                  context,
                  controller: block.restController,
                  label: 'Rest Time',
                  hintText: '1:30',
                  fieldKey: 'rest-$index',
                  onTap: (fieldContext) => _activateRestField(
                    block,
                    fieldKey: 'rest-$index',
                    fieldContext: fieldContext,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _buildRangeFields(
            context,
            title: 'Rep Range',
            startController: block.repsMinController,
            endController: block.repsMaxController,
            startHint: 'Min reps',
            endHint: 'Max reps',
            startFieldKey: 'reps-min-$index',
            endFieldKey: 'reps-max-$index',
            onStartTap: (fieldContext) => _activateIntegerField(
              title: 'Rep Range Min',
              fieldKey: 'reps-min-$index',
              controller: block.repsMinController,
              fieldContext: fieldContext,
            ),
            onEndTap: (fieldContext) => _activateIntegerField(
              title: 'Rep Range Max',
              fieldKey: 'reps-max-$index',
              controller: block.repsMaxController,
              fieldContext: fieldContext,
            ),
          ),
          const SizedBox(height: 14),
          _buildRangeFields(
            context,
            title: 'RPE Range',
            startController: block.targetRpeMinController,
            endController: block.targetRpeMaxController,
            startHint: 'Min RPE',
            endHint: 'Max RPE',
            startFieldKey: 'rpe-min-$index',
            endFieldKey: 'rpe-max-$index',
            onStartTap: (fieldContext) => _activateDecimalField(
              title: 'RPE Min',
              fieldKey: 'rpe-min-$index',
              controller: block.targetRpeMinController,
              fieldContext: fieldContext,
            ),
            onEndTap: (fieldContext) => _activateDecimalField(
              title: 'RPE Max',
              fieldKey: 'rpe-max-$index',
              controller: block.targetRpeMaxController,
              fieldContext: fieldContext,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddSetVariationButton(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _addBlock,
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
          'Add Set Variation',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildNumberPad() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final keypadPanelTopColor = scheme.surface.withValues(alpha: 0.66);
    final keypadPanelBottomColor =
        scheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final keypadPanelBorderColor = scheme.outline.withValues(alpha: 0.18);
    final keypadKeyColor = scheme.surface.withValues(alpha: 0.74);
    final keypadKeyBorderColor = scheme.onSurface.withValues(alpha: 0.12);

    Widget keyButton(
      String label, {
      required VoidCallback onPressed,
      Color? backgroundColor,
      Color? foregroundColor,
    }) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                elevation: 0,
                backgroundColor: backgroundColor ?? keypadKeyColor,
                foregroundColor: foregroundColor ?? scheme.onSurface,
                shadowColor: Colors.transparent,
                side: BorderSide(color: keypadKeyBorderColor),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: label == '⌫'
                  ? const Icon(Icons.backspace_outlined, size: 20)
                  : Text(
                      label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ),
      );
    }

    return TapRegion(
      groupId: _numberPadTapGroup,
      onTapOutside: (_) => _closeNumberPad(),
      child: SafeArea(
        top: false,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(28),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(color: keypadPanelBorderColor),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    keypadPanelTopColor,
                    keypadPanelBottomColor,
                  ],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _activeNumberPadTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      keyButton('1',
                          onPressed: () => _appendNumberPadChar('1')),
                      keyButton('2',
                          onPressed: () => _appendNumberPadChar('2')),
                      keyButton('3',
                          onPressed: () => _appendNumberPadChar('3')),
                    ],
                  ),
                  Row(
                    children: [
                      keyButton('4',
                          onPressed: () => _appendNumberPadChar('4')),
                      keyButton('5',
                          onPressed: () => _appendNumberPadChar('5')),
                      keyButton('6',
                          onPressed: () => _appendNumberPadChar('6')),
                    ],
                  ),
                  Row(
                    children: [
                      keyButton('7',
                          onPressed: () => _appendNumberPadChar('7')),
                      keyButton('8',
                          onPressed: () => _appendNumberPadChar('8')),
                      keyButton('9',
                          onPressed: () => _appendNumberPadChar('9')),
                    ],
                  ),
                  Row(
                    children: [
                      keyButton(
                        _activeNumberPadAllowDecimal ? '.' : 'C',
                        onPressed: _activeNumberPadAllowDecimal
                            ? () => _appendNumberPadChar('.')
                            : _clearNumberPad,
                      ),
                      keyButton('0',
                          onPressed: () => _appendNumberPadChar('0')),
                      keyButton('⌫', onPressed: _backspaceNumberPad),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      keyButton(
                        'Cancel',
                        onPressed: () =>
                            _closeNumberPad(revertCurrentField: true),
                      ),
                      keyButton(
                        'OK',
                        onPressed: _confirmNumberPad,
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.surface,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final dialogCard = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.of(context).size.height * 0.82,
      ),
      child: GlassCard(
        padding: EdgeInsets.zero,
        radius: 26,
        borderOpacity: 0.26,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 10, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.exerciseName,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Edit Set Variations',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.62),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Container(
              height: 1,
              color: scheme.outline.withValues(alpha: 0.18),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: KeyedSubtree(
                        key: _scrollViewportKey,
                        child: ListView(
                          controller: _scrollController,
                          children: [
                            if (_blocks.isEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  'No set variations yet. Add one to start building this exercise.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.68,
                                    ),
                                  ),
                                ),
                              ),
                            ] else ...[
                              for (var index = 0;
                                  index < _blocks.length;
                                  index++) ...[
                                _buildBlockCard(
                                  context,
                                  _blocks[index],
                                  index,
                                ),
                                const SizedBox(height: 12),
                              ],
                            ],
                            _buildAddSetVariationButton(context),
                            if (_activeNumberPadFieldKey != null)
                              const SizedBox(height: _numberPadReservedHeight),
                          ],
                        ),
                      ),
                    ),
            ),
            if (_pendingRemovedBlock != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: scheme.outline.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Set variation removed'),
                      ),
                      TextButton(
                        onPressed: _undoBlockRemoval,
                        child: const Text('Undo'),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _save,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('Save'),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: TapRegionSurface(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_activeNumberPadFieldKey != null) {
                    _closeNumberPad();
                    return;
                  }
                  Navigator.of(context).pop();
                },
              ),
            ),
            Center(child: dialogCard),
            if (_activeNumberPadFieldKey != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: KeyedSubtree(
                  key: _numberPadKey,
                  child: _buildNumberPad(),
                ),
              ),
          ],
        ),
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
    required this.restSeconds,
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
        repsMinController =
            TextEditingController(text: repsMin?.toString() ?? ''),
        repsMaxController =
            TextEditingController(text: repsMax?.toString() ?? ''),
        restController =
            TextEditingController(text: formatRestSeconds(restSeconds)),
        targetRpeMinController =
            TextEditingController(text: targetRpeMin?.toString() ?? ''),
        targetRpeMaxController =
            TextEditingController(text: targetRpeMax?.toString() ?? '');

  int orderIndex;
  String role;
  int setCount;
  int? repsMin;
  int? repsMax;
  int? restSeconds;
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
  final TextEditingController restController;
  final TextEditingController targetRpeMinController;
  final TextEditingController targetRpeMaxController;

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    return null;
  }

  static String _encodeSecondsToHmsInput(int seconds) {
    final clamped = seconds.clamp(0, 359999);
    final hours = clamped ~/ 3600;
    final minutes = (clamped % 3600) ~/ 60;
    final secs = clamped % 60;
    final raw =
        '${hours.toString().padLeft(2, '0')}${minutes.toString().padLeft(2, '0')}${secs.toString().padLeft(2, '0')}';
    final trimmed = raw.replaceFirst(RegExp(r'^0+'), '');
    return trimmed.isEmpty ? '0' : trimmed;
  }

  static String formatEditableRestInput(String rawValue) {
    final digits = rawValue.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '0:00';
    final limited =
        digits.length <= 6 ? digits : digits.substring(digits.length - 6);
    if (limited.length <= 2) {
      return '0:${limited.padLeft(2, '0')}';
    }
    if (limited.length <= 4) {
      final head = limited.substring(0, limited.length - 2);
      final seconds = limited.substring(limited.length - 2);
      final minutes = int.tryParse(head) ?? 0;
      return '$minutes:$seconds';
    }
    final hoursText = limited.substring(0, limited.length - 4);
    final minutes = limited.substring(limited.length - 4, limited.length - 2);
    final seconds = limited.substring(limited.length - 2);
    final hours = int.tryParse(hoursText) ?? 0;
    return '$hours:$minutes:$seconds';
  }

  static String formatRestSeconds(int? seconds) {
    final safe = seconds ?? 0;
    return formatEditableRestInput(_encodeSecondsToHmsInput(safe));
  }

  static int? parseRestInput(String rawValue) {
    final digits = rawValue.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    final limited =
        digits.length <= 6 ? digits : digits.substring(digits.length - 6);
    final padded = limited.padLeft(6, '0');
    final hours = int.tryParse(padded.substring(0, 2)) ?? 0;
    final minutes = int.tryParse(padded.substring(2, 4)) ?? 0;
    final seconds = int.tryParse(padded.substring(4, 6)) ?? 0;
    final total = (hours * 3600) + (minutes * 60) + seconds;
    return total <= 0 ? null : total;
  }

  factory _BlockModel.fromRow(Map<String, Object?> row) {
    return _BlockModel(
      orderIndex: row['order_index'] as int,
      role: row['role'] as String,
      setCount: row['set_count'] as int,
      repsMin: row['reps_min'] as int?,
      repsMax: row['reps_max'] as int?,
      restSeconds: row['rest_sec_min'] as int? ?? row['rest_sec_max'] as int?,
      loadRuleType: row['load_rule_type'] as String,
      loadRuleMin: _toDouble(row['load_rule_min']),
      loadRuleMax: _toDouble(row['load_rule_max']),
      amrapLastSet: (row['amrap_last_set'] as int? ?? 0) == 1,
      targetRpeMin: _toDouble(row['target_rpe_min']),
      targetRpeMax: _toDouble(row['target_rpe_max']),
      targetRirMin: _toDouble(row['target_rir_min']),
      targetRirMax: _toDouble(row['target_rir_max']),
      partialsTargetMin: row['partials_target_min'] as int?,
      partialsTargetMax: row['partials_target_max'] as int?,
    );
  }

  Map<String, Object?> toMap({required int orderIndex}) {
    final parsedSetCount = int.tryParse(setCountController.text.trim()) ?? 1;
    final parsedRestSeconds = parseRestInput(restController.text.trim());
    return {
      'order_index': orderIndex,
      'role': role,
      'set_count': parsedSetCount,
      'reps_min': int.tryParse(repsMinController.text.trim()),
      'reps_max': int.tryParse(repsMaxController.text.trim()),
      'rest_sec_min': parsedRestSeconds,
      'rest_sec_max': parsedRestSeconds,
      'target_rpe_min': double.tryParse(targetRpeMinController.text.trim()),
      'target_rpe_max': double.tryParse(targetRpeMaxController.text.trim()),
      'target_rir_min': targetRirMin,
      'target_rir_max': targetRirMax,
      'load_rule_type': loadRuleType,
      'load_rule_min': loadRuleMin,
      'load_rule_max': loadRuleMax,
      'amrap_last_set': amrapLastSet ? 1 : 0,
      'partials_target_min': partialsTargetMin,
      'partials_target_max': partialsTargetMax,
      'notes': null,
    };
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/command_bus/command.dart';
import '../../../core/command_bus/dispatcher.dart';
import '../../../core/command_bus/session_command_reducer.dart';
import '../../../core/command_bus/undo_redo.dart';
import '../../../core/voice/gemini_parser.dart';
import '../../../core/voice/llm_parser.dart';
import '../../../core/voice/openai_parser.dart';
import '../../../core/voice/wake_word.dart';
import '../../../core/voice/voice_models.dart';
import '../../../core/voice/nlu_parser.dart';
import '../../../core/voice/stt.dart';
import '../../../core/voice/muscle_enricher.dart';
import '../../../data/db/db.dart';
import '../../../data/repositories/exercise_repo.dart';
import '../../../data/repositories/program_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../data/repositories/workout_repo.dart';
import '../../../domain/models/last_logged_set.dart';
import '../../../domain/models/session_context.dart';
import '../../../domain/models/session_exercise_info.dart';
import '../../../domain/services/exercise_matcher.dart';
import '../../../domain/services/set_plan_service.dart';
import '../shell/app_shell_controller.dart';
import '../history/history_screen.dart';
import '../history/exercise_catalog_screen.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen(
      {super.key, required this.contextData, this.isEditing = false});

  final SessionContext contextData;
  final bool isEditing;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _DraftSet {
  _DraftSet({
    this.repsHint,
    int? initialReps,
    this.restSeconds,
    this.targetSetIndex,
  }) {
    if (initialReps != null && initialReps > 0) {
      reps.text = initialReps.toString();
    }
  }

  final String? repsHint;
  int? restSeconds;
  int? targetSetIndex;
  final TextEditingController weight = TextEditingController();
  final TextEditingController reps = TextEditingController();
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    weight.dispose();
    reps.dispose();
  }
}

class _InlineSetData {
  _InlineSetData({required this.sets, required this.previousSets});

  final List<Map<String, Object?>> sets;
  final List<Map<String, Object?>> previousSets;
}

class _NumberPadResult {
  const _NumberPadResult({
    required this.value,
    required this.confirmed,
  });

  final String value;
  final bool confirmed;
}

const _numberPadTapRegionGroup = 'session-number-pad';

enum _PendingField { weight, reps }

class _PendingLogSet {
  _PendingLogSet({
    required this.exerciseInfo,
    required this.missingField,
    this.reps,
    this.weight,
    this.weightUnit,
    this.partials,
    this.rpe,
    this.rir,
  });

  final SessionExerciseInfo exerciseInfo;
  final _PendingField missingField;
  final int? reps;
  final double? weight;
  final String? weightUnit;
  final int? partials;
  final double? rpe;
  final double? rir;
}

const double _sessionMatchThreshold = 0.4;
const double _sessionGuessThreshold = 0.4;

class _SessionMatchScore {
  _SessionMatchScore(this.info, this.score);

  final SessionExerciseInfo info;
  final double score;
}

class _ExerciseMuscles {
  _ExerciseMuscles({required this.primary, required this.secondary});

  final String? primary;
  final List<String> secondary;
}

class _AnimatedRestPill extends StatefulWidget {
  const _AnimatedRestPill({
    required this.isActive,
    required this.isComplete,
    required this.restSeconds,
    required this.activeStartedAt,
    required this.activeDurationSeconds,
    required this.barColor,
    required this.barBorderColor,
    required this.fillColor,
    required this.textColor,
    required this.textStyle,
    this.overrideLabel,
  });

  final bool isActive;
  final bool isComplete;
  final int restSeconds;
  final DateTime? activeStartedAt;
  final int activeDurationSeconds;
  final Color barColor;
  final Color barBorderColor;
  final Color fillColor;
  final Color textColor;
  final TextStyle? textStyle;
  final String? overrideLabel;

  @override
  State<_AnimatedRestPill> createState() => _AnimatedRestPillState();
}

class _AnimatedRestPillState extends State<_AnimatedRestPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _localComplete = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addStatusListener(_handleAnimationStatus);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _AnimatedRestPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    final configChanged = widget.isActive != oldWidget.isActive ||
        widget.isComplete != oldWidget.isComplete ||
        widget.activeStartedAt != oldWidget.activeStartedAt ||
        widget.activeDurationSeconds != oldWidget.activeDurationSeconds ||
        widget.restSeconds != oldWidget.restSeconds;
    if (configChanged) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_handleAnimationStatus)
      ..dispose();
    super.dispose();
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted && !_localComplete) {
      setState(() {
        _localComplete = true;
      });
    }
  }

  void _syncAnimation() {
    if (widget.isComplete) {
      _controller.stop();
      _controller.value = 1.0;
      _localComplete = true;
      return;
    }
    if (!widget.isActive ||
        widget.activeStartedAt == null ||
        widget.activeDurationSeconds <= 0) {
      _controller.stop();
      _controller.value = 0.0;
      _localComplete = false;
      return;
    }
    final totalMs = widget.activeDurationSeconds * 1000;
    final elapsedMs = DateTime.now()
        .difference(widget.activeStartedAt!)
        .inMilliseconds
        .clamp(0, totalMs);
    final progress = totalMs <= 0 ? 1.0 : elapsedMs / totalMs;
    final remainingMs = totalMs - elapsedMs;
    _controller.stop();
    _controller.value = progress.clamp(0.0, 1.0);
    _localComplete = remainingMs <= 0;
    if (_localComplete) {
      _controller.value = 1.0;
      return;
    }
    _controller.animateTo(
      1.0,
      duration: Duration(milliseconds: remainingMs),
      curve: Curves.linear,
    );
  }

  int _remainingSeconds() {
    if (!widget.isActive || _localComplete) return widget.restSeconds;
    final totalMs = widget.activeDurationSeconds * 1000;
    if (totalMs <= 0) return widget.restSeconds;
    final elapsedMs = (totalMs * _controller.value).floor().clamp(0, totalMs);
    final remainingMs = (totalMs - elapsedMs).clamp(0, totalMs);
    if (remainingMs <= 0) return 0;
    return ((remainingMs - 1) ~/ 1000) + 1;
  }

  String _formatRestShort(int seconds) {
    if (seconds <= 0) return '0:00';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${mins}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final showComplete = widget.isComplete || _localComplete;
        final widthFactor = showComplete
            ? 1.0
            : (widget.isActive ? (1.0 - _controller.value) : 0.0);
        final label = widget.overrideLabel ??
            (showComplete
                ? _formatRestShort(widget.restSeconds)
                : widget.isActive
                    ? _formatRestShort(_remainingSeconds())
                    : _formatRestShort(widget.restSeconds));
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth * widthFactor.clamp(0.0, 1.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.barColor,
                    border: Border.all(color: widget.barBorderColor),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                if (width > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: width,
                      height: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.fillColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Text(
                    label,
                    style: widget.textStyle?.copyWith(color: widget.textColor),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SessionScreenState extends State<SessionScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _voiceController = TextEditingController();
  final _parser = NluParser();
  final _llmParser = LlmParser();
  final _geminiParser = GeminiParser();
  final _openAiParser = OpenAiParser();
  final _wakeWordEngine = WakeWordEngine();
  late final WorkoutRepo _workoutRepo;
  late final ExerciseMatcher _matcher;
  late final ExerciseRepo _exerciseRepo;
  late final ProgramRepo _programRepo;
  late final SettingsRepo _settingsRepo;
  late final Map<int, SessionExerciseInfo> _exerciseById;
  late final Map<int, SessionExerciseInfo> _sessionExerciseById;
  late final Map<String, int> _cacheRefToExerciseId;
  late final CommandDispatcher _dispatcher;
  late final List<SessionExerciseInfo> _sessionExercises;
  final Map<int, _ExerciseMuscles> _musclesByExerciseId = {};
  List<String> _currentDayExerciseNames = [];
  List<String> _otherDayExerciseNames = [];
  List<String> _catalogExerciseNames = [];
  final UndoRedoStack _undoRedo = UndoRedoStack();
  bool _isLoggingSet = false;
  final List<String> _setDebugNotes = [];
  bool _showSetDebug = false;
  final Map<int, _InlineSetData> _inlineSetCache = {};
  final Map<int, Future<_InlineSetData>> _inlineSetFutures = {};
  final Map<int, String> _inlineDebugSnapshot = {};
  final Map<int, int> _restSecondsByExerciseId = {};
  final Set<int> _completedRestSetIds = <int>{};
  Timer? _inlineRestTicker;
  PersistentBottomSheetController? _numberPadSheetController;
  Completer<_NumberPadResult?>? _numberPadResultCompleter;
  StateSetter? _numberPadSheetSetState;
  String _numberPadTitle = '';
  String _numberPadRawValue = '';
  bool _numberPadAllowDecimal = false;
  bool _numberPadReplacePending = false;
  bool _numberPadDiscardChanges = false;
  String Function(String value)? _numberPadDisplayFormatter;
  DateTime _inlineRestNow = DateTime.now();
  int? _lastObservedInlineRestSetId;
  String? _activeNumberPadFieldKey;
  String _activeNumberPadValue = '';
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndedAt;
  String? _sessionProgramName;
  String? _sessionDayName;
  bool _listening = false;
  String? _voicePartial;
  final Map<int, List<_DraftSet>> _draftSetsByExerciseId = {};

  _PendingLogSet? _pending;
  LastLoggedSet? _lastLogged;
  SessionExerciseInfo? _lastExerciseInfo;
  String? _prompt;
  bool _showVoiceDebug = false;
  String? _debugTranscript;
  String? _debugRule;
  String? _debugLlm;
  String? _debugGemini;
  String? _debugOpenAi;
  String? _debugCloud;
  String? _debugDecision;
  String? _debugParts;
  String? _debugLlmRaw;
  String? _debugGeminiRaw;
  String? _debugOpenAiRaw;
  String? _debugResolved;

  bool _cloudEnabled = false;
  String? _cloudApiKey;
  String _cloudModel = 'gemini-2.5-pro';
  String _cloudProvider = 'gemini';
  bool _wakeWordEnabled = false;
  bool _sessionEnded = false;
  String _weightUnit = 'lb';
  bool _handlingPendingSessionVoice = false;

  @override
  void initState() {
    super.initState();
    final db = AppDatabase.instance;
    if (!widget.isEditing) {
      AppShellController.instance.setActiveSession(true);
      AppShellController.instance.setActiveSessionIndicatorHidden(false);
    }
    AppShellController.instance.pendingSessionVoice
        .addListener(_handlePendingSessionVoice);
    _workoutRepo = WorkoutRepo(db);
    _exerciseRepo = ExerciseRepo(db);
    _programRepo = ProgramRepo(db);
    _settingsRepo = SettingsRepo(db);
    _matcher = ExerciseMatcher(_exerciseRepo);
    _sessionExercises =
        List<SessionExerciseInfo>.from(widget.contextData.exercises);
    _exerciseById = {
      for (final info in _sessionExercises) info.exerciseId: info
    };
    _sessionExerciseById = {
      for (final info in _sessionExercises) info.sessionExerciseId: info
    };
    _cacheRefToExerciseId = {};
    _dispatcher = CommandDispatcher(
      SessionCommandReducer(
        workoutRepo: _workoutRepo,
        sessionExerciseById: _sessionExerciseById,
      ).call,
    );
    _currentDayExerciseNames =
        _sessionExercises.map((e) => e.exerciseName).toList();
    // Defer local LLM initialization until it is actually needed.
    Future.microtask(_loadCloudSettings);
    Future.microtask(_loadExerciseHints);
    Future.microtask(_loadSessionMuscles);
    Future.microtask(_loadUnitPref);
    Future.microtask(_loadSessionHeader);
    Future.microtask(_seedInitialDraftSets);
    _inlineRestNow = DateTime.now();
    _lastObservedInlineRestSetId = AppShellController.instance.restActiveSetId;
    _inlineRestTicker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      final restController = AppShellController.instance;
      final now = DateTime.now();
      final resolvedActiveRestSetId = restController.restActiveSetId;
      if (_lastObservedInlineRestSetId != null &&
          resolvedActiveRestSetId == null) {
        _completedRestSetIds.add(_lastObservedInlineRestSetId!);
      }
      _lastObservedInlineRestSetId = resolvedActiveRestSetId;
      setState(() {
        _inlineRestNow = now;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handlePendingSessionVoice();
    });
  }

  @override
  void dispose() {
    _voiceController.dispose();
    _inlineRestTicker?.cancel();
    AppShellController.instance.pendingSessionVoice
        .removeListener(_handlePendingSessionVoice);
    for (final drafts in _draftSetsByExerciseId.values) {
      for (final draft in drafts) {
        draft.dispose();
      }
    }
    if (!widget.isEditing && !_sessionEnded) {
      AppShellController.instance.setActiveSession(true);
      AppShellController.instance.setActiveSessionIndicatorHidden(false);
      AppShellController.instance.refreshActiveSession();
    }
    if (_sessionEnded && !widget.isEditing) {
      AppShellController.instance.setActiveSession(false);
    }
    super.dispose();
  }

  Future<void> _loadCloudSettings() async {
    final enabled = await _settingsRepo.getCloudEnabled();
    final apiKey = await _settingsRepo.getCloudApiKey();
    final model = await _settingsRepo.getCloudModel();
    final provider = await _settingsRepo.getCloudProvider();
    final wakeWordEnabled = await _settingsRepo.getWakeWordEnabled();
    if (!mounted) return;
    setState(() {
      _cloudEnabled = enabled;
      _cloudApiKey = apiKey;
      _cloudModel = model;
      _cloudProvider = provider;
      _wakeWordEnabled = wakeWordEnabled;
    });
    _wakeWordEngine.enabled = wakeWordEnabled;
    if (wakeWordEnabled) {
      await _wakeWordEngine.start();
    } else {
      await _wakeWordEngine.stop();
    }
  }

  Future<void> _loadSessionHeader() async {
    final header =
        await _workoutRepo.getSessionHeader(widget.contextData.sessionId);
    if (!mounted) return;
    setState(() {
      _sessionStartedAt =
          DateTime.tryParse(header?['started_at'] as String? ?? '');
      _sessionEndedAt = DateTime.tryParse(header?['ended_at'] as String? ?? '');
      _sessionProgramName = header?['program_name'] as String?;
      _sessionDayName = header?['day_name'] as String?;
    });
  }

  Future<void> _seedInitialDraftSets() async {
    if (widget.isEditing) return;
    if (widget.contextData.programDayId == null) return;
    var added = false;
    for (final info in _sessionExercises) {
      if (_draftSetsByExerciseId.containsKey(info.sessionExerciseId)) continue;
      final sets =
          await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
      if (sets.isNotEmpty) continue;
      _draftSetsByExerciseId[info.sessionExerciseId] =
          _buildPlannedDrafts(info);
      added = true;
    }
    if (!mounted || !added) return;
    setState(() {});
  }

  List<_DraftSet> _buildPlannedDrafts(SessionExerciseInfo info) {
    if (info.planBlocks.isEmpty) {
      return [
        _DraftSet(
          restSeconds: _restSecondsForExercise(info),
          targetSetIndex: 1,
        ),
      ];
    }
    final ordered = List<SetPlanBlock>.from(info.planBlocks)
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    final drafts = <_DraftSet>[];
    final defaultRestSeconds = _restSecondsForExercise(info);
    var nextSetIndex = 1;
    for (final block in ordered) {
      final hint = _formatRepsHint(block.repsMin, block.repsMax);
      final lowerBoundReps = block.repsMin ?? block.repsMax;
      final count = block.setCount <= 0 ? 1 : block.setCount;
      for (var i = 0; i < count; i++) {
        drafts.add(
          _DraftSet(
            repsHint: hint,
            initialReps: lowerBoundReps,
            restSeconds: defaultRestSeconds,
            targetSetIndex: nextSetIndex,
          ),
        );
        nextSetIndex += 1;
      }
    }
    return drafts.isEmpty
        ? [
            _DraftSet(
              restSeconds: _restSecondsForExercise(info),
              targetSetIndex: 1,
            ),
          ]
        : drafts;
  }

  String? _formatRepsHint(int? min, int? max) {
    if (min == null && max == null) return null;
    if (min != null && max != null) {
      if (min == max) return '$min';
      return '$min-$max';
    }
    return '${min ?? max}';
  }

  int _nextDraftSetIndex(SessionExerciseInfo info) {
    var maxIndex = 0;
    final cachedSets =
        _inlineSetCache[info.sessionExerciseId]?.sets ?? const [];
    for (final row in cachedSets) {
      final value = row['set_index'] as int?;
      if (value != null && value > maxIndex) {
        maxIndex = value;
      }
    }
    final drafts = _draftSetsByExerciseId[info.sessionExerciseId] ?? const [];
    for (final draft in drafts) {
      final value = draft.targetSetIndex;
      if (value != null && value > maxIndex) {
        maxIndex = value;
      }
    }
    return maxIndex + 1;
  }

  Future<void> _loadExerciseHints() async {
    try {
      final programId = widget.contextData.programId;
      final programDayId = widget.contextData.programDayId;
      if (programId == null) return;
      final byDay =
          await _programRepo.getExerciseNamesByDayForProgram(programId);
      final other = <String>[];
      byDay.forEach((dayId, names) {
        if (programDayId == null || dayId != programDayId) {
          other.addAll(names);
        }
      });
      final catalogRows = await _exerciseRepo.getAll();
      final catalog = catalogRows
          .map((row) => row['canonical_name'] as String?)
          .whereType<String>()
          .where((name) => name.trim().isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _otherDayExerciseNames = _limitList(_dedupeList(other), 120);
        _catalogExerciseNames = _limitList(_dedupeList(catalog), 200);
      });
    } catch (_) {
      // ignore hint failures
    }
  }

  Future<void> _loadSessionMuscles() async {
    try {
      final cloudEnabled = await _settingsRepo.getCloudEnabled();
      final apiKey = await _settingsRepo.getCloudApiKey();
      final provider = await _settingsRepo.getCloudProvider();
      final model = await _settingsRepo.getCloudModel();
      final canEnrich =
          cloudEnabled && apiKey != null && apiKey.trim().isNotEmpty;
      final enricher = canEnrich ? MuscleEnricher() : null;
      for (final info in _sessionExercises) {
        final row = await _exerciseRepo.getById(info.exerciseId);
        if (row == null) continue;
        final primary = (row['primary_muscle'] as String?)?.trim();
        final secondaryJson = row['secondary_muscles_json'] as String?;
        final secondary = <String>[];
        if (secondaryJson != null && secondaryJson.isNotEmpty) {
          try {
            final decoded = jsonDecode(secondaryJson);
            if (decoded is List) {
              secondary.addAll(
                decoded
                    .map((e) => e.toString())
                    .where((e) => e.trim().isNotEmpty),
              );
            }
          } catch (_) {}
        }
        _musclesByExerciseId[info.exerciseId] = _ExerciseMuscles(
          primary: primary,
          secondary: secondary,
        );
        if ((primary == null || primary.isEmpty) && enricher != null) {
          final result = await enricher.enrich(
            exerciseName: info.exerciseName,
            provider: provider,
            apiKey: apiKey!.trim(),
            model: model,
          );
          if (result != null) {
            await _exerciseRepo.updateMuscles(
              exerciseId: info.exerciseId,
              primaryMuscle: result.primary,
              secondaryMuscles: result.secondary,
            );
            _musclesByExerciseId[info.exerciseId] = _ExerciseMuscles(
              primary: result.primary,
              secondary: result.secondary,
            );
          }
        }
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _loadUnitPref() async {
    final unit = await _settingsRepo.getUnit();
    if (!mounted) return;
    setState(() {
      _weightUnit = unit;
    });
  }

  Future<void> _showQuickAddSet(SessionExerciseInfo info) async {
    final list =
        _draftSetsByExerciseId.putIfAbsent(info.sessionExerciseId, () => []);
    list.add(
      _DraftSet(
        restSeconds: _restSecondsForExercise(info),
        targetSetIndex: _nextDraftSetIndex(info),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  String _formatSetWeight(num? weight) {
    if (weight == null) return '—';
    final value = weight.toDouble();
    return value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  }

  String _formatPrevious(Map<String, Object?>? row) {
    if (row == null) return '—';
    final weight = row['weight_value'] as num?;
    final reps = row['reps'] as int?;
    if (weight == null || reps == null) return '—';
    final unit = (row['weight_unit'] as String?)?.trim();
    final unitLabel = unit == null || unit.isEmpty ? '' : ' $unit';
    return '${_formatSetWeight(weight)}$unitLabel × $reps';
  }

  int? _planRestSeconds(SessionExerciseInfo info) {
    int? restMax;
    int? restMin;
    for (final block in info.planBlocks) {
      if (block.restSecMax != null) {
        if (restMax == null || block.restSecMax! > restMax) {
          restMax = block.restSecMax;
        }
      }
      if (block.restSecMin != null) {
        if (restMin == null || block.restSecMin! < restMin!) {
          restMin = block.restSecMin;
        }
      }
    }
    return restMax ?? restMin;
  }

  int _restSecondsForExercise(SessionExerciseInfo info) {
    final cached = _restSecondsByExerciseId[info.exerciseId];
    if (cached != null) return cached;
    const fallback = 90;
    final value = _planRestSeconds(info) ?? fallback;
    _restSecondsByExerciseId[info.exerciseId] = value;
    return value;
  }

  String _formatRestShort(int seconds) {
    if (seconds <= 0) return '0:00';
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${mins}:${secs.toString().padLeft(2, '0')}';
  }

  String _encodeSecondsToHmsInput(int seconds) {
    final clamped = seconds.clamp(0, 359999);
    final hours = clamped ~/ 3600;
    final minutes = (clamped % 3600) ~/ 60;
    final secs = clamped % 60;
    final raw =
        '${hours.toString().padLeft(2, '0')}${minutes.toString().padLeft(2, '0')}${secs.toString().padLeft(2, '0')}';
    final trimmed = raw.replaceFirst(RegExp(r'^0+'), '');
    return trimmed.isEmpty ? '0' : trimmed;
  }

  String _formatEditableDurationInput(String rawDigits) {
    final digits = rawDigits.replaceAll(RegExp(r'[^0-9]'), '');
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

  int _parseHmsInputToSeconds(String rawDigits) {
    final digits = rawDigits.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 0;
    final limited =
        digits.length <= 6 ? digits : digits.substring(digits.length - 6);
    final padded = limited.padLeft(6, '0');
    final hours = int.tryParse(padded.substring(0, 2)) ?? 0;
    final minutes = int.tryParse(padded.substring(2, 4)) ?? 0;
    final seconds = int.tryParse(padded.substring(4, 6)) ?? 0;
    return (hours * 3600) + (minutes * 60) + seconds;
  }

  bool get _showInlineEditCaret =>
      (_inlineRestNow.millisecondsSinceEpoch ~/ 500).isEven;

  String _inlineEditingLabel(String value) {
    final caret = _showInlineEditCaret ? '|' : '';
    if (value.isEmpty) {
      return caret.isEmpty ? ' ' : caret;
    }
    return '$value$caret';
  }

  Future<void> _bringFieldIntoView(BuildContext fieldContext) async {
    if (Scrollable.maybeOf(fieldContext) == null) return;
    try {
      await Scrollable.ensureVisible(
        fieldContext,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: 0.42,
      );
    } catch (_) {
      // Ignore visibility failures from detached contexts.
    }
  }

  String _formatNumberPadDisplay(String raw) {
    final formatter = _numberPadDisplayFormatter;
    return formatter == null ? raw : formatter(raw);
  }

  void _refreshNumberPadUi() {
    _numberPadSheetSetState?.call(() {});
    if (!mounted) return;
    setState(() {
      _activeNumberPadValue = _formatNumberPadDisplay(_numberPadRawValue);
    });
  }

  void _configureNumberPadRequest({
    required String title,
    required String fieldKey,
    required String initialValue,
    required bool allowDecimal,
    required String Function(String value)? displayFormatter,
    required bool replaceOnFirstInput,
  }) {
    _numberPadTitle = title;
    _numberPadRawValue = initialValue.trim();
    _numberPadAllowDecimal = allowDecimal;
    _numberPadReplacePending =
        replaceOnFirstInput && _numberPadRawValue.isNotEmpty;
    _numberPadDiscardChanges = false;
    _numberPadDisplayFormatter = displayFormatter;
    _numberPadResultCompleter = Completer<_NumberPadResult?>();
    if (!mounted) return;
    setState(() {
      _activeNumberPadFieldKey = fieldKey;
      _activeNumberPadValue = _formatNumberPadDisplay(_numberPadRawValue);
    });
  }

  void _commitActiveNumberPad({
    bool closeSheet = false,
    bool confirmed = false,
  }) {
    final completer = _numberPadResultCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        _NumberPadResult(
          value: _numberPadRawValue.trim(),
          confirmed: confirmed,
        ),
      );
    }
    if (closeSheet) {
      _numberPadSheetController?.close();
    }
  }

  void _cancelActiveNumberPad() {
    _numberPadDiscardChanges = true;
    final completer = _numberPadResultCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
    _numberPadSheetController?.close();
  }

  void _appendNumberPadChar(String char) {
    if (char == '.' && !_numberPadAllowDecimal) return;
    if (_numberPadReplacePending) {
      _numberPadRawValue = '';
      _numberPadReplacePending = false;
    }
    if (char == '.') {
      if (_numberPadRawValue.contains('.')) return;
      _numberPadRawValue =
          _numberPadRawValue.isEmpty ? '0.' : '$_numberPadRawValue.';
      _refreshNumberPadUi();
      return;
    }
    if (_numberPadRawValue == '0') {
      _numberPadRawValue = char;
      _refreshNumberPadUi();
      return;
    }
    _numberPadRawValue = '$_numberPadRawValue$char';
    _refreshNumberPadUi();
  }

  void _backspaceNumberPad() {
    if (_numberPadRawValue.isEmpty) return;
    _numberPadRawValue =
        _numberPadRawValue.substring(0, _numberPadRawValue.length - 1);
    _numberPadReplacePending = false;
    _refreshNumberPadUi();
  }

  void _clearNumberPad() {
    _numberPadRawValue = '';
    _numberPadReplacePending = false;
    _refreshNumberPadUi();
  }

  bool _isTimerCompleteForRow(
    Map<String, Object?> row, {
    DateTime? now,
  }) {
    final setId = row['id'] as int?;
    if (setId == null) return false;
    if (_completedRestSetIds.contains(setId)) return true;
    if (AppShellController.instance.restActiveSetId == setId) return false;
    final restSeconds = (row['rest_sec_actual'] as int?) ?? 0;
    if (restSeconds <= 0) return false;
    final createdAt = DateTime.tryParse((row['created_at'] as String?) ?? '');
    if (createdAt == null) return false;
    final effectiveNow = now ?? DateTime.now();
    return effectiveNow.difference(createdAt).inMilliseconds >=
        restSeconds * 1000;
  }

  void _showUndoSnackBar({
    required String message,
    required Future<void> Function() onUndo,
  }) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            unawaited(onUndo());
          },
        ),
      ),
    );
  }

  String _formatSessionTimer(Duration elapsed) {
    final totalSeconds = elapsed.inSeconds.clamp(0, 86400 * 7);
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatSessionDate(DateTime? value) {
    if (value == null) return 'Today';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[value.month - 1]} ${value.day}, ${value.year}';
  }

  String _sessionTitle() {
    final day = _sessionDayName?.trim();
    if (day != null && day.isNotEmpty) return day;
    final program = _sessionProgramName?.trim();
    if (program != null && program.isNotEmpty) return program;
    return 'Workout Session';
  }

  String? _currentVoiceStatus() {
    if (_voicePartial != null && _voicePartial!.trim().isNotEmpty) {
      return 'Listening: $_voicePartial';
    }
    if (_prompt != null && _prompt!.trim().isNotEmpty) {
      return _prompt;
    }
    if (_wakeWordEnabled) {
      return 'Listening for "Hey Ora"';
    }
    return null;
  }

  void _startInlineRest({
    required int setId,
    required int restSeconds,
    required int exerciseId,
  }) {
    final previousActiveSetId = AppShellController.instance.restActiveSetId;
    if (previousActiveSetId != null && previousActiveSetId != setId) {
      _completedRestSetIds.add(previousActiveSetId);
    }
    if (restSeconds <= 0) {
      if (previousActiveSetId != null) {
        AppShellController.instance.completeRestTimer();
        _lastObservedInlineRestSetId = null;
      }
      _completedRestSetIds.add(setId);
      if (!mounted) return;
      setState(() {});
      return;
    }
    _completedRestSetIds.remove(setId);
    AppShellController.instance.startRestTimer(
      seconds: restSeconds,
      setId: setId,
      exerciseId: exerciseId,
    );
    _lastObservedInlineRestSetId = setId;
    if (!mounted) return;
    setState(() {});
  }

  void _completeInlineRest() {
    final completedSetId = AppShellController.instance.restActiveSetId;
    if (completedSetId == null) return;
    AppShellController.instance.completeRestTimer();
    _completedRestSetIds.add(completedSetId);
    _lastObservedInlineRestSetId = null;
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _undoCompletedSet(
    SessionExerciseInfo info,
    Map<String, Object?> row,
  ) async {
    final id = row['id'] as int?;
    if (id == null) return;
    _completedRestSetIds.remove(id);
    final weight = row['weight_value'] as num?;
    final reps = row['reps'] as int?;
    await _deleteSet(id, info);
    final draft = _DraftSet(
      restSeconds:
          (row['rest_sec_actual'] as int?) ?? _restSecondsForExercise(info),
      targetSetIndex: row['set_index'] as int?,
    );
    if (weight != null) {
      draft.weight.text = _formatSetWeight(weight);
    }
    if (reps != null) {
      draft.reps.text = reps.toString();
    }
    _draftSetsByExerciseId
        .putIfAbsent(info.sessionExerciseId, () => [])
        .add(draft);
    if (!mounted) return;
    setState(() {});
  }

  Future<_NumberPadResult?> _showNumberPad({
    required String title,
    required String fieldKey,
    String initialValue = '',
    bool allowDecimal = false,
    String Function(String value)? displayFormatter,
    bool replaceOnFirstInput = false,
  }) async {
    if (_numberPadSheetController != null) {
      if (_activeNumberPadFieldKey == fieldKey) {
        return null;
      }
      _commitActiveNumberPad();
      _configureNumberPadRequest(
        title: title,
        fieldKey: fieldKey,
        initialValue: initialValue,
        allowDecimal: allowDecimal,
        displayFormatter: displayFormatter,
        replaceOnFirstInput: replaceOnFirstInput,
      );
      _refreshNumberPadUi();
      return _numberPadResultCompleter?.future;
    }
    if (_scaffoldKey.currentState == null) {
      return null;
    }
    _configureNumberPadRequest(
      title: title,
      fieldKey: fieldKey,
      initialValue: initialValue,
      allowDecimal: allowDecimal,
      displayFormatter: displayFormatter,
      replaceOnFirstInput: replaceOnFirstInput,
    );
    final completer = _numberPadResultCompleter!;
    final scaffoldState = _scaffoldKey.currentState!;
    final theme = Theme.of(context);
    final keypadPanelTopColor = theme.colorScheme.surface.withOpacity(0.66);
    final keypadPanelBottomColor =
        theme.colorScheme.surfaceContainerHighest.withOpacity(0.5);
    final keypadPanelBorderColor = theme.colorScheme.outline.withOpacity(0.18);
    final keypadKeyColor = theme.colorScheme.surface.withOpacity(0.74);
    final keypadKeyBorderColor = theme.colorScheme.onSurface.withOpacity(0.12);
    late PersistentBottomSheetController controller;

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
                foregroundColor: foregroundColor ?? theme.colorScheme.onSurface,
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

    controller = scaffoldState.showBottomSheet(
      (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            _numberPadSheetSetState = setModalState;
            return TapRegion(
              groupId: _numberPadTapRegionGroup,
              onTapOutside: (_) {
                if (_numberPadSheetController == null) return;
                _commitActiveNumberPad(closeSheet: true);
              },
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(28),
                    ),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(
                        sigmaX: 18,
                        sigmaY: 18,
                      ),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              keypadPanelTopColor,
                              keypadPanelBottomColor,
                            ],
                          ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(28),
                          ),
                          border: Border.all(color: keypadPanelBorderColor),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _numberPadTitle,
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
                                  _numberPadAllowDecimal ? '.' : 'C',
                                  onPressed: () => _numberPadAllowDecimal
                                      ? _appendNumberPadChar('.')
                                      : _clearNumberPad(),
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
                                  onPressed: _cancelActiveNumberPad,
                                ),
                                keyButton(
                                  'OK',
                                  onPressed: () => _commitActiveNumberPad(
                                    closeSheet: true,
                                    confirmed: true,
                                  ),
                                  backgroundColor: theme.colorScheme.primary,
                                  foregroundColor: theme.colorScheme.surface,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      backgroundColor: Colors.transparent,
      elevation: 0,
      enableDrag: false,
    );
    _numberPadSheetController = controller;
    controller.closed.whenComplete(() {
      final activeCompleter = _numberPadResultCompleter;
      if (activeCompleter != null && !activeCompleter.isCompleted) {
        activeCompleter.complete(
          _numberPadDiscardChanges
              ? null
              : _NumberPadResult(
                  value: _numberPadRawValue.trim(),
                  confirmed: false,
                ),
        );
      }
      if (identical(_numberPadSheetController, controller)) {
        _numberPadSheetController = null;
        _numberPadSheetSetState = null;
        _numberPadResultCompleter = null;
        _numberPadTitle = '';
        _numberPadRawValue = '';
        _numberPadAllowDecimal = false;
        _numberPadReplacePending = false;
        _numberPadDiscardChanges = false;
        _numberPadDisplayFormatter = null;
      }
      if (!mounted) return;
      setState(() {
        _activeNumberPadFieldKey = null;
        _activeNumberPadValue = '';
      });
    });
    return completer.future;
  }

  Future<int?> _promptRestSeconds(
    int currentSeconds, {
    required String fieldKey,
  }) async {
    final result = await _showNumberPad(
      title: 'Rest Timer',
      fieldKey: fieldKey,
      initialValue: _encodeSecondsToHmsInput(currentSeconds),
      displayFormatter: _formatEditableDurationInput,
    );
    if (result == null) return null;
    return _parseHmsInputToSeconds(result.value);
  }

  Future<void> _editLoggedSetRest(
    SessionExerciseInfo info, {
    required int setId,
    required int currentSeconds,
  }) async {
    final wasActive = AppShellController.instance.restActiveSetId == setId;
    final selected = await _promptRestSeconds(
      currentSeconds,
      fieldKey: 'logged-rest-$setId',
    );
    if (selected == null) return;
    await _workoutRepo.updateSetEntry(
      id: setId,
      restSecActual: selected,
    );
    if (wasActive) {
      _completeInlineRest();
    } else {
      _completedRestSetIds.add(setId);
    }
    _refreshInlineSetData(info);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _editLoggedSetWeight(
    SessionExerciseInfo info, {
    required int setId,
    required num? currentWeight,
  }) async {
    final result = await _showNumberPad(
      title: 'Weight ($_weightUnit)',
      fieldKey: 'logged-weight-$setId',
      initialValue:
          currentWeight == null ? '' : _formatSetWeight(currentWeight),
      allowDecimal: true,
    );
    if (result == null) return;
    final trimmed = result.value.trim();
    final parsed = trimmed.isEmpty ? null : double.tryParse(trimmed);
    if (trimmed.isNotEmpty && parsed == null) {
      _showMessage('Enter a valid weight.');
      return;
    }
    await _workoutRepo.updateSetEntry(
      id: setId,
      weightValue: parsed,
    );
    _refreshInlineSetData(info);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _editLoggedSetReps(
    SessionExerciseInfo info, {
    required int setId,
    required int? currentReps,
  }) async {
    final result = await _showNumberPad(
      title: 'Reps',
      fieldKey: 'logged-reps-$setId',
      initialValue: currentReps?.toString() ?? '',
    );
    if (result == null) return;
    final parsed = int.tryParse(result.value.trim());
    if (parsed == null || parsed <= 0) {
      _showMessage('Enter valid reps.');
      return;
    }
    await _workoutRepo.updateSetEntry(
      id: setId,
      reps: parsed,
    );
    _refreshInlineSetData(info);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _editDraftRest(SessionExerciseInfo info, _DraftSet draft) async {
    final currentSeconds = draft.restSeconds ?? _restSecondsForExercise(info);
    final selected = await _promptRestSeconds(
      currentSeconds,
      fieldKey: 'draft-rest-${info.sessionExerciseId}-${draft.hashCode}',
    );
    if (selected == null || !mounted) return;
    setState(() {
      draft.restSeconds = selected;
    });
  }

  void _removeDraftRest(SessionExerciseInfo info, _DraftSet draft) {
    final previousSeconds = draft.restSeconds ?? _restSecondsForExercise(info);
    if (previousSeconds <= 0) return;
    setState(() {
      draft.restSeconds = 0;
    });
    _showUndoSnackBar(
      message: 'Timer removed',
      onUndo: () async {
        if (!mounted) return;
        final list = _draftSetsByExerciseId[info.sessionExerciseId];
        if (list == null || !list.contains(draft)) return;
        setState(() {
          draft.restSeconds = previousSeconds;
        });
      },
    );
  }

  Future<void> _removeLoggedSetRest(
    SessionExerciseInfo info, {
    required int setId,
    required int currentSeconds,
  }) async {
    if (currentSeconds <= 0) return;
    final wasComplete = _completedRestSetIds.contains(setId);
    final wasActive = AppShellController.instance.restActiveSetId == setId;
    if (wasActive) {
      AppShellController.instance.completeRestTimer();
      _lastObservedInlineRestSetId = null;
    }
    _completedRestSetIds.remove(setId);
    await _workoutRepo.updateSetEntry(
      id: setId,
      restSecActual: 0,
    );
    _refreshInlineSetData(info);
    if (mounted) {
      setState(() {});
    }
    _showUndoSnackBar(
      message: 'Timer removed',
      onUndo: () async {
        final row = await _workoutRepo.getSetEntryById(setId);
        if (row == null) return;
        await _workoutRepo.updateSetEntry(
          id: setId,
          restSecActual: currentSeconds,
        );
        if (wasComplete) {
          _completedRestSetIds.add(setId);
        }
        _refreshInlineSetData(info);
        if (!mounted) return;
        setState(() {});
      },
    );
  }

  Future<void> _editExerciseRestTimers(SessionExerciseInfo info) async {
    final currentSeconds = _restSecondsForExercise(info);
    final selected = await _promptRestSeconds(
      currentSeconds,
      fieldKey: 'exercise-rest-${info.sessionExerciseId}',
    );
    if (selected == null) return;
    final rows =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    final now = DateTime.now();
    final activeSetId = AppShellController.instance.restActiveSetId;
    var shouldRestartActive = false;
    for (final row in rows) {
      final setId = row['id'] as int?;
      final rowRestSeconds = (row['rest_sec_actual'] as int?) ?? 0;
      if (setId == null || rowRestSeconds <= 0) continue;
      if (_isTimerCompleteForRow(row, now: now)) continue;
      await _workoutRepo.updateSetEntry(
        id: setId,
        restSecActual: selected,
      );
      if (setId == activeSetId) {
        shouldRestartActive = true;
      }
    }
    final drafts = _draftSetsByExerciseId[info.sessionExerciseId];
    if (drafts != null) {
      for (final draft in drafts) {
        final draftRest = draft.restSeconds ?? currentSeconds;
        if (draftRest > 0) {
          draft.restSeconds = selected;
        }
      }
    }
    _restSecondsByExerciseId[info.exerciseId] = selected;
    if (shouldRestartActive && activeSetId != null) {
      if (selected > 0) {
        AppShellController.instance.startRestTimer(
          seconds: selected,
          setId: activeSetId,
          exerciseId: info.exerciseId,
        );
        _completedRestSetIds.remove(activeSetId);
        _lastObservedInlineRestSetId = activeSetId;
      } else {
        AppShellController.instance.completeRestTimer();
        _completedRestSetIds.remove(activeSetId);
        _lastObservedInlineRestSetId = null;
      }
    }
    _refreshInlineSetData(info);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _editDraftWeight(
    SessionExerciseInfo info,
    _DraftSet draft, {
    required int setNumber,
  }) async {
    final result = await _showNumberPad(
      title: 'Weight ($_weightUnit)',
      fieldKey: 'draft-weight-${info.sessionExerciseId}-${draft.hashCode}',
      initialValue: draft.weight.text,
      allowDecimal: true,
    );
    if (result == null || draft.isDisposed) return;
    final trimmed = result.value.trim();
    final parsed = trimmed.isEmpty ? null : double.tryParse(trimmed);
    if (trimmed.isNotEmpty && parsed == null) {
      _showMessage('Enter a valid weight.');
      return;
    }
    draft.weight.text = parsed == null ? '' : _formatSetWeight(parsed);
    if (!result.confirmed) {
      if (!mounted) return;
      setState(() {});
      return;
    }
    final reps = int.tryParse(draft.reps.text.trim());
    if (reps != null && reps > 0) {
      await _commitDraftSet(info, draft, setNumber: setNumber);
      return;
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _editDraftReps(
    SessionExerciseInfo info,
    _DraftSet draft, {
    required int setNumber,
  }) async {
    final result = await _showNumberPad(
      title: 'Reps',
      fieldKey: 'draft-reps-${info.sessionExerciseId}-${draft.hashCode}',
      initialValue: draft.reps.text,
    );
    if (result == null || draft.isDisposed) return;
    final trimmed = result.value.trim();
    draft.reps.text = trimmed;
    final reps = int.tryParse(trimmed);
    if (reps == null || reps <= 0) {
      if (!mounted) return;
      setState(() {});
      return;
    }
    if (!result.confirmed) {
      if (!mounted) return;
      setState(() {});
      return;
    }
    await _commitDraftSet(info, draft, setNumber: setNumber);
  }

  Future<_InlineSetData> _loadInlineSetData(SessionExerciseInfo info) async {
    try {
      final sets = List<Map<String, Object?>>.from(
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId),
      );
      sets.sort((a, b) {
        final aIndex = (a['set_index'] as int?) ?? 0;
        final bIndex = (b['set_index'] as int?) ?? 0;
        if (aIndex != bIndex) return aIndex.compareTo(bIndex);
        final aId = (a['id'] as int?) ?? 0;
        final bId = (b['id'] as int?) ?? 0;
        return aId.compareTo(bId);
      });
      final previousSets = List<Map<String, Object?>>.from(
        await _workoutRepo.getPreviousSetsForExercise(
          exerciseId: info.exerciseId,
          excludeSessionId: widget.contextData.sessionId,
        ),
      );
      final drafts = _draftSetsByExerciseId[info.sessionExerciseId] ?? const [];
      _logInlineSnapshot(info, sets, previousSets, drafts, source: 'load');
      return _InlineSetData(sets: sets, previousSets: previousSets);
    } catch (error, stack) {
      _pushSetDebug(
        '[load] ex=${info.sessionExerciseId} error=${error.runtimeType} '
        '${error.toString().split('\n').first}',
      );
      debugPrint(stack.toString());
      final cached = _inlineSetCache[info.sessionExerciseId];
      if (cached != null) return cached;
      return _InlineSetData(sets: const [], previousSets: const []);
    }
  }

  Future<_InlineSetData> _getInlineSetFuture(SessionExerciseInfo info) {
    final existing = _inlineSetFutures[info.sessionExerciseId];
    if (existing != null) {
      _pushSetDebug(
        '[future] ex=${info.sessionExerciseId} reuse future=${existing.hashCode}',
      );
      return existing;
    }
    late final Future<_InlineSetData> future;
    future = _loadInlineSetData(info).then((data) {
      if (identical(_inlineSetFutures[info.sessionExerciseId], future)) {
        _inlineSetCache[info.sessionExerciseId] = data;
      }
      return data;
    });
    _inlineSetFutures[info.sessionExerciseId] = future;
    _pushSetDebug(
      '[future] ex=${info.sessionExerciseId} create future=${future.hashCode}',
    );
    return future;
  }

  void _refreshInlineSetData(SessionExerciseInfo info) {
    final previous = _inlineSetFutures[info.sessionExerciseId];
    late final Future<_InlineSetData> future;
    future = _loadInlineSetData(info).then((data) {
      if (identical(_inlineSetFutures[info.sessionExerciseId], future)) {
        _inlineSetCache[info.sessionExerciseId] = data;
        _pushSetDebug(
          '[refresh] ex=${info.sessionExerciseId} done sets=${data.sets.length} '
          'rows=${_summarizeSetRows(data.sets)}',
        );
      } else {
        _pushSetDebug(
          '[refresh] ex=${info.sessionExerciseId} stale future=${future.hashCode}',
        );
      }
      return data;
    });
    _inlineSetFutures[info.sessionExerciseId] = future;
    _pushSetDebug(
      '[refresh] ex=${info.sessionExerciseId} start future=${future.hashCode} '
      'prev=${previous?.hashCode}',
    );
  }

  Future<void> _commitDraftSet(
    SessionExerciseInfo info,
    _DraftSet draft, {
    int? setNumber,
  }) async {
    final reps = int.tryParse(draft.reps.text.trim());
    if (reps == null || reps <= 0) {
      _showMessage('Enter valid reps.');
      return;
    }
    final weightRaw = draft.weight.text.trim();
    final weight = weightRaw.isEmpty ? null : double.tryParse(weightRaw);
    _pushSetDebug(
      '[commit] start ex=${info.sessionExerciseId} reps=$reps weight=$weight',
    );
    _isLoggingSet = true;
    try {
      final beforeSets =
          await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
      _pushSetDebug(
          '[commit] beforeCount=${beforeSets.length} rows=${_summarizeSetRows(beforeSets)}');
      await _logInlineSet(
        info,
        reps: reps,
        weight: weight,
        restSeconds: draft.restSeconds ?? _restSecondsForExercise(info),
        setIndex: setNumber ?? draft.targetSetIndex,
      );
      final afterSets =
          await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
      _pushSetDebug(
          '[commit] afterCount=${afterSets.length} rows=${_summarizeSetRows(afterSets)}');
      if (afterSets.length <= beforeSets.length) {
        _showMessage('Set not saved. Try again.');
        return;
      }
      final list = _draftSetsByExerciseId[info.sessionExerciseId];
      list?.remove(draft);
      draft.dispose();
      _refreshInlineSetData(info);
      if (!mounted) return;
      setState(() {});
    } finally {
      _isLoggingSet = false;
    }
  }

  void _pushSetDebug(String message) {
    if (!_showSetDebug) return;
    final stamp = DateTime.now().toIso8601String().split('T').last;
    final entry = '$stamp $message';
    _setDebugNotes.add(entry);
    if (_setDebugNotes.length > 12) {
      _setDebugNotes.removeRange(0, _setDebugNotes.length - 12);
    }
    debugPrint(entry);
  }

  String _summarizeParts(List<String> parts, {int max = 6}) {
    if (parts.isEmpty) return '—';
    if (parts.length <= max) return parts.join(', ');
    final preview = parts.take(max).join(', ');
    return '$preview, …+${parts.length - max}';
  }

  String _summarizeSetRows(List<Map<String, Object?>> rows) {
    final parts = <String>[];
    for (final row in rows) {
      final id = row['id'] as int?;
      final index = row['set_index'] as int?;
      final reps = row['reps'] as int?;
      final weight = row['weight_value'] as num?;
      final weightLabel = _formatSetWeight(weight);
      parts.add('${id ?? '?'}:${index ?? '?'} ${weightLabel}x${reps ?? '?'}');
    }
    return _summarizeParts(parts);
  }

  String _summarizePreviousRows(List<Map<String, Object?>> rows) {
    final parts = <String>[];
    for (final row in rows) {
      final index = row['set_index'] as int?;
      final reps = row['reps'] as int?;
      final weight = row['weight_value'] as num?;
      final weightLabel = _formatSetWeight(weight);
      parts.add('${index ?? '?'}:${weightLabel}x${reps ?? '?'}');
    }
    return _summarizeParts(parts);
  }

  void _logInlineSnapshot(
    SessionExerciseInfo info,
    List<Map<String, Object?>> sets,
    List<Map<String, Object?>> previousSets,
    List<_DraftSet> drafts, {
    required String source,
  }) {
    if (!_showSetDebug) return;
    final draftCount = drafts.length;
    final summary =
        '[snapshot:$source] ex=${info.sessionExerciseId} sets=${sets.length} '
        '(${_summarizeSetRows(sets)}) '
        'prev=${previousSets.length} (${_summarizePreviousRows(previousSets)}) '
        'drafts=$draftCount';
    final last = _inlineDebugSnapshot[info.sessionExerciseId];
    if (last == summary) return;
    _inlineDebugSnapshot[info.sessionExerciseId] = summary;
    _pushSetDebug(summary);
  }

  Widget _buildLoggedRestRow(
    BuildContext context,
    SessionExerciseInfo info, {
    required int setId,
    required int restSeconds,
    required bool isActive,
    required bool isComplete,
    required DateTime? activeStartedAt,
    required int activeDurationSeconds,
  }) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final completeAccent = Colors.green.shade700;
    final barColor =
        isComplete ? Colors.green.withOpacity(0.14) : accent.withOpacity(0.08);
    final barBorderColor =
        isComplete ? Colors.green.withOpacity(0.26) : accent.withOpacity(0.12);
    final fillColor =
        isComplete ? Colors.green.withOpacity(0.28) : accent.withOpacity(0.22);
    final textColor = isComplete ? completeAccent : accent;
    final fieldKey = 'logged-rest-$setId';
    final isEditing = _activeNumberPadFieldKey == fieldKey;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Builder(
        builder: (rowContext) => GestureDetector(
          onTap: () async {
            await _bringFieldIntoView(rowContext);
            if (!mounted) return;
            _editLoggedSetRest(
              info,
              setId: setId,
              currentSeconds: restSeconds,
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: 28,
              child: _AnimatedRestPill(
                isActive: isActive,
                isComplete: isComplete,
                restSeconds: restSeconds,
                activeStartedAt: activeStartedAt,
                activeDurationSeconds: activeDurationSeconds,
                barColor: barColor,
                barBorderColor: barBorderColor,
                fillColor: fillColor,
                textColor: textColor,
                textStyle: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                overrideLabel: isEditing
                    ? _inlineEditingLabel(_activeNumberPadValue)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
    return Dismissible(
      key: ValueKey('rest-$setId-$restSeconds'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.45,
      },
      confirmDismiss: (_) async => !_isLoggingSet,
      background: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.28),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.timer_off_outlined),
      ),
      onDismissed: (_) => unawaited(
        _removeLoggedSetRest(
          info,
          setId: setId,
          currentSeconds: restSeconds,
        ),
      ),
      child: row,
    );
  }

  Widget _buildDraftRestRow(
    BuildContext context,
    SessionExerciseInfo info,
    _DraftSet draft,
  ) {
    final restSeconds = draft.restSeconds ?? _restSecondsForExercise(info);
    if (restSeconds <= 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final fieldKey = 'draft-rest-${info.sessionExerciseId}-${draft.hashCode}';
    final isEditing = _activeNumberPadFieldKey == fieldKey;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Builder(
        builder: (rowContext) => GestureDetector(
          onTap: () async {
            await _bringFieldIntoView(rowContext);
            if (!mounted) return;
            _editDraftRest(info, draft);
          },
          child: Container(
            height: 28,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accent.withOpacity(0.12)),
            ),
            alignment: Alignment.center,
            child: Text(
              isEditing
                  ? _inlineEditingLabel(_activeNumberPadValue)
                  : _formatRestShort(restSeconds),
              style: theme.textTheme.titleSmall?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
    return Dismissible(
      key: ValueKey('draft-rest-${info.sessionExerciseId}-${draft.hashCode}'),
      direction: DismissDirection.startToEnd,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.45,
      },
      confirmDismiss: (_) async => !_isLoggingSet,
      background: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.28),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.timer_off_outlined),
      ),
      onDismissed: (_) => _removeDraftRest(info, draft),
      child: row,
    );
  }

  Widget _buildInlineSets(
    BuildContext context,
    SessionExerciseInfo info,
    List<Map<String, Object?>> sets,
    List<Map<String, Object?>> previousSets,
    List<_DraftSet> drafts, {
    String renderSource = 'render',
  }) {
    var volume = 0.0;
    for (final row in sets) {
      final weight = row['weight_value'] as num?;
      final reps = row['reps'] as int?;
      if (weight != null && reps != null) {
        volume += weight.toDouble() * reps;
      }
    }
    _logInlineSnapshot(info, sets, previousSets, drafts, source: renderSource);
    final theme = Theme.of(context);
    final volumeLabel = volume == 0 ? '—' : volume.toStringAsFixed(0);
    const setFlex = 12;
    const prevFlex = 28;
    const weightFlex = 18;
    const repsFlex = 18;
    const checkFlex = 10;
    const colGap = 8.0;
    final headerStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurface.withOpacity(0.86),
    );
    final summaryStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withOpacity(0.64),
      fontWeight: FontWeight.w600,
    );
    final fieldFill = theme.colorScheme.surface.withOpacity(0.62);
    final draftRowFill = theme.colorScheme.surface.withOpacity(0.34);
    final borderColor = theme.colorScheme.onSurface.withOpacity(0.06);
    final completeRowFill = Colors.green.withOpacity(0.14);
    final completeBorderColor = Colors.green.withOpacity(0.26);
    final restController = AppShellController.instance;
    final activeRestSetId = restController.restActiveSetId;
    final activeRestStartedAt = restController.restStartedAt;
    final activeRestDuration = restController.restDurationSeconds;
    final orderedSets = List<Map<String, Object?>>.from(sets)
      ..sort((a, b) {
        final aIndex = (a['set_index'] as int?) ?? 0;
        final bIndex = (b['set_index'] as int?) ?? 0;
        if (aIndex != bIndex) return aIndex.compareTo(bIndex);
        final aId = (a['id'] as int?) ?? 0;
        final bId = (b['id'] as int?) ?? 0;
        return aId.compareTo(bId);
      });

    Widget valueChip(
      String label, {
      bool emphasize = false,
      Color? foregroundColor,
      Color? fillColor,
      Color? outlineColor,
    }) {
      return Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: fillColor ?? fieldFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: outlineColor ?? borderColor),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
            color: foregroundColor,
          ),
        ),
      );
    }

    Widget editableValueChip({
      required String label,
      required VoidCallback onTap,
      String? placeholder,
      bool emphasize = false,
      Color? foregroundColor,
      String? fieldKey,
    }) {
      final isEditing =
          fieldKey != null && _activeNumberPadFieldKey == fieldKey;
      final hasValue = label.trim().isNotEmpty;
      final displayLabel = isEditing
          ? _inlineEditingLabel(_activeNumberPadValue)
          : (hasValue ? label : (placeholder ?? '—'));
      final chip = Builder(
        builder: (chipContext) => Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () async {
              await _bringFieldIntoView(chipContext);
              if (!mounted) return;
              onTap();
            },
            borderRadius: BorderRadius.circular(12),
            child: valueChip(
              displayLabel,
              emphasize: emphasize,
              foregroundColor: isEditing || hasValue
                  ? foregroundColor
                  : theme.colorScheme.onSurface.withOpacity(0.35),
            ),
          ),
        ),
      );
      if (fieldKey == null) return chip;
      return TapRegion(
        groupId: _numberPadTapRegionGroup,
        child: chip,
      );
    }

    Widget actionChip({
      required IconData icon,
      required Color color,
      VoidCallback? onPressed,
      String? tooltip,
    }) {
      final iconWidget = Icon(icon, size: 20, color: color);
      if (onPressed == null) {
        return SizedBox(
          width: 28,
          height: 28,
          child: Center(child: iconWidget),
        );
      }
      return SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          visualDensity: VisualDensity.compact,
          tooltip: tooltip,
          icon: iconWidget,
        ),
      );
    }

    Widget flexCell({
      required int flex,
      required Widget child,
      AlignmentGeometry alignment = Alignment.center,
    }) {
      return Expanded(
        flex: flex,
        child: Align(
          alignment: alignment,
          child: child,
        ),
      );
    }

    Widget headerCell(String label, int flex) {
      return flexCell(
        flex: flex,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: headerStyle,
        ),
      );
    }

    Widget savedRowWidget(
      Map<String, Object?> row,
      int displayNumber,
      Map<String, Object?>? previousRow,
    ) {
      final restSecondsActual =
          (row['rest_sec_actual'] as int?) ?? _restSecondsForExercise(info);
      final createdAt = DateTime.tryParse((row['created_at'] as String?) ?? '');
      final rowId = row['id'] as int?;
      final rowHasActiveTimer = rowId != null && rowId == activeRestSetId;
      final effectiveRestSeconds = rowHasActiveTimer && activeRestDuration > 0
          ? activeRestDuration
          : restSecondsActual;
      final hasRest = effectiveRestSeconds > 0;
      final startedAt =
          rowHasActiveTimer ? activeRestStartedAt ?? createdAt : null;
      final effectiveRestMs = effectiveRestSeconds * 1000;
      final elapsedMs = startedAt == null
          ? 0
          : _inlineRestNow.difference(startedAt).inMilliseconds;
      final rawRemainingMs =
          rowHasActiveTimer && hasRest ? (effectiveRestMs - elapsedMs) : 0;
      final justFinished = rowHasActiveTimer && hasRest && rawRemainingMs <= 0;
      final isActive = rowHasActiveTimer && !justFinished;
      final isTimerComplete = rowId != null &&
          (_completedRestSetIds.contains(rowId) ||
              justFinished ||
              _isTimerCompleteForRow(row, now: _inlineRestNow));
      final rowContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: completeRowFill,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: completeBorderColor),
            ),
            child: Row(
              children: [
                flexCell(
                  flex: setFlex,
                  child: valueChip(
                    '$displayNumber',
                    emphasize: true,
                    foregroundColor: Colors.green.shade900,
                  ),
                ),
                const SizedBox(width: colGap),
                flexCell(
                  flex: prevFlex,
                  child: Text(
                    _formatPrevious(previousRow),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: colGap),
                flexCell(
                  flex: weightFlex,
                  child: editableValueChip(
                    label: _formatSetWeight(row['weight_value'] as num?),
                    onTap: () => _editLoggedSetWeight(
                      info,
                      setId: rowId!,
                      currentWeight: row['weight_value'] as num?,
                    ),
                    fieldKey: rowId == null ? null : 'logged-weight-$rowId',
                    placeholder: '—',
                    foregroundColor: Colors.green.shade900,
                  ),
                ),
                const SizedBox(width: colGap),
                flexCell(
                  flex: repsFlex,
                  child: editableValueChip(
                    label: (row['reps'] as int?)?.toString() ?? '',
                    onTap: () => _editLoggedSetReps(
                      info,
                      setId: rowId!,
                      currentReps: row['reps'] as int?,
                    ),
                    fieldKey: rowId == null ? null : 'logged-reps-$rowId',
                    placeholder: '—',
                    foregroundColor: Colors.green.shade900,
                  ),
                ),
                const SizedBox(width: colGap),
                flexCell(
                  flex: checkFlex,
                  child: actionChip(
                    icon: Icons.undo_rounded,
                    color: Colors.green.shade700,
                    onPressed: () => _undoCompletedSet(info, row),
                    tooltip: 'Mark incomplete',
                  ),
                ),
              ],
            ),
          ),
          if (rowId != null && restSecondsActual > 0)
            _buildLoggedRestRow(
              context,
              info,
              setId: rowId,
              restSeconds: restSecondsActual,
              isActive: isActive,
              isComplete: isTimerComplete,
              activeStartedAt: startedAt,
              activeDurationSeconds: effectiveRestSeconds,
            ),
        ],
      );
      if (rowId == null) return rowContent;
      return Dismissible(
        key: ValueKey('set-$rowId'),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {
          DismissDirection.startToEnd: 0.35,
        },
        confirmDismiss: (_) async {
          _pushSetDebug('[swipe] saved id=$rowId');
          return !_isLoggingSet;
        },
        background: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.28),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.delete_outline),
        ),
        onDismissed: (_) => _deleteSet(rowId, info),
        child: rowContent,
      );
    }

    Widget draftRowWidget(
      _DraftSet draft,
      int draftIndex,
      int displayNumber,
      Map<String, Object?>? previousRow,
    ) {
      final weightFieldKey =
          'draft-weight-${info.sessionExerciseId}-${draft.hashCode}';
      final repsFieldKey =
          'draft-reps-${info.sessionExerciseId}-${draft.hashCode}';
      final rowContent = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: draftRowFill.withOpacity(0.82),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            flexCell(
              flex: setFlex,
              child: valueChip('$displayNumber', emphasize: true),
            ),
            const SizedBox(width: colGap),
            flexCell(
              flex: prevFlex,
              child: Text(
                _formatPrevious(previousRow),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: colGap),
            flexCell(
              flex: weightFlex,
              child: editableValueChip(
                label: draft.weight.text,
                onTap: () {
                  _setActiveExercise(info);
                  _editDraftWeight(info, draft, setNumber: displayNumber);
                },
                fieldKey: weightFieldKey,
                placeholder: _weightUnit,
              ),
            ),
            const SizedBox(width: colGap),
            flexCell(
              flex: repsFlex,
              child: editableValueChip(
                label: draft.reps.text,
                onTap: () {
                  _setActiveExercise(info);
                  _editDraftReps(info, draft, setNumber: displayNumber);
                },
                fieldKey: repsFieldKey,
                placeholder: draft.repsHint ?? 'Reps',
              ),
            ),
            const SizedBox(width: colGap),
            flexCell(
              flex: checkFlex,
              child: actionChip(
                icon: Icons.check_rounded,
                color: theme.colorScheme.primary,
                onPressed: _isLoggingSet
                    ? null
                    : () {
                        final activeFieldKey = _activeNumberPadFieldKey;
                        if (activeFieldKey == weightFieldKey ||
                            activeFieldKey == repsFieldKey) {
                          _commitActiveNumberPad(
                            closeSheet: true,
                            confirmed: true,
                          );
                          return;
                        }
                        unawaited(
                          _commitDraftSet(
                            info,
                            draft,
                            setNumber: displayNumber,
                          ),
                        );
                      },
                tooltip: 'Mark complete',
              ),
            ),
          ],
        ),
      );
      return Dismissible(
        key: ValueKey(
            'draft-${info.sessionExerciseId}-$draftIndex-${draft.hashCode}'),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {
          DismissDirection.startToEnd: 0.45,
        },
        confirmDismiss: (_) async {
          _pushSetDebug(
              '[swipe] draft ex=${info.sessionExerciseId} idx=$draftIndex');
          return !_isLoggingSet;
        },
        background: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: Colors.redAccent.withOpacity(0.28),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.delete_outline),
        ),
        onDismissed: (_) => _removeDraftSet(info, draft),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            rowContent,
            _buildDraftRestRow(context, info, draft),
          ],
        ),
      );
    }

    final usedSlots = <int>{};
    for (final row in orderedSets) {
      final slot = row['set_index'] as int?;
      if (slot != null && slot > 0) {
        usedSlots.add(slot);
      }
    }
    final draftSlots = <_DraftSet, int>{};
    for (final draft in drafts) {
      final slot = draft.targetSetIndex;
      if (slot != null && slot > 0 && !usedSlots.contains(slot)) {
        draftSlots[draft] = slot;
        usedSlots.add(slot);
      }
    }
    var nextFallbackSlot = 1;
    for (final draft in drafts) {
      if (draftSlots.containsKey(draft)) continue;
      while (usedSlots.contains(nextFallbackSlot)) {
        nextFallbackSlot += 1;
      }
      draftSlots[draft] = nextFallbackSlot;
      usedSlots.add(nextFallbackSlot);
      nextFallbackSlot += 1;
    }

    final renderedRows = <Widget>[];
    final orderedDraftIndices = List<int>.generate(drafts.length, (i) => i)
      ..sort((a, b) {
        final aSlot = draftSlots[drafts[a]] ?? ((1 << 20) + a);
        final bSlot = draftSlots[drafts[b]] ?? ((1 << 20) + b);
        if (aSlot != bSlot) return aSlot.compareTo(bSlot);
        return a.compareTo(b);
      });
    var savedCursor = 0;
    var draftCursor = 0;
    while (savedCursor < orderedSets.length ||
        draftCursor < orderedDraftIndices.length) {
      final nextSaved =
          savedCursor < orderedSets.length ? orderedSets[savedCursor] : null;
      final nextDraftIndex = draftCursor < orderedDraftIndices.length
          ? orderedDraftIndices[draftCursor]
          : null;
      final nextDraft = nextDraftIndex == null ? null : drafts[nextDraftIndex];
      final savedSlot = (nextSaved?['set_index'] as int?) ?? (1 << 20);
      final draftSlot = nextDraft == null
          ? (1 << 20)
          : (draftSlots[nextDraft] ?? ((1 << 20) + draftCursor + 1));
      if (nextDraft != null && (nextSaved == null || draftSlot <= savedSlot)) {
        final slot = draftSlot <= 0 ? 1 : draftSlot;
        final previousRow =
            slot - 1 < previousSets.length ? previousSets[slot - 1] : null;
        renderedRows.add(
          draftRowWidget(nextDraft, nextDraftIndex!, slot, previousRow),
        );
        draftCursor += 1;
        continue;
      }
      if (nextSaved != null) {
        final slot = savedSlot <= 0 ? savedCursor + 1 : savedSlot;
        final previousRow =
            slot - 1 < previousSets.length ? previousSets[slot - 1] : null;
        renderedRows.add(savedRowWidget(nextSaved, slot, previousRow));
        savedCursor += 1;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${sets.length + drafts.length} sets  •  Volume $volumeLabel',
          style: summaryStyle,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            headerCell('Set', setFlex),
            const SizedBox(width: colGap),
            headerCell('Previous', prevFlex),
            const SizedBox(width: colGap),
            headerCell(_weightUnit, weightFlex),
            const SizedBox(width: colGap),
            headerCell('Reps', repsFlex),
            const SizedBox(width: colGap),
            flexCell(
              flex: checkFlex,
              child: const SizedBox.shrink(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (sets.isEmpty && drafts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No sets yet.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          )
        else
          ...renderedRows,
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () {
              _setActiveExercise(info);
              _showQuickAddSet(info);
            },
            style: OutlinedButton.styleFrom(
              backgroundColor: theme.colorScheme.surface.withOpacity(0.45),
              foregroundColor: theme.colorScheme.onSurface,
              side: BorderSide(color: borderColor),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(
              '+ Add Set (${_formatRestShort(_restSecondsForExercise(info))})',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _logInlineSet(
    SessionExerciseInfo info, {
    required int reps,
    required int restSeconds,
    double? weight,
    int? setIndex,
  }) async {
    final existing =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    var maxIndex = 0;
    for (final row in existing) {
      final value = row['set_index'] as int?;
      if (value != null && value > maxIndex) {
        maxIndex = value;
      }
    }
    final resolvedSetIndex =
        setIndex == null || setIndex <= 0 ? maxIndex + 1 : setIndex;
    final planResult = SetPlanService().nextExpected(
      blocks: info.planBlocks,
      existingSets: existing,
    );
    final role = planResult?.nextRole ?? 'TOP';
    final isAmrap = planResult?.isAmrap ?? false;
    _pushSetDebug(
      '[log] ex=${info.sessionExerciseId} setIndex=$resolvedSetIndex role=$role reps=$reps weight=$weight',
    );
    final id = await _workoutRepo.addSetEntry(
      sessionExerciseId: info.sessionExerciseId,
      setIndex: resolvedSetIndex,
      setRole: role,
      weightValue: weight,
      weightUnit: _weightUnit,
      weightMode: info.weightModeDefault,
      reps: reps,
      partialReps: 0,
      rpe: null,
      rir: null,
      flagWarmup: role == 'WARMUP',
      flagPartials: false,
      isAmrap: isAmrap,
      restSecActual: restSeconds,
    );
    _startInlineRest(
        setId: id, restSeconds: restSeconds, exerciseId: info.exerciseId);
    _pushSetDebug('[log] inserted id=$id');
    final latest = await _workoutRepo.getSetEntryById(id);
    final setsForExercise =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    _pushSetDebug(
      '[log] ex=${info.sessionExerciseId} nowCount=${setsForExercise.length} '
      'rows=${_summarizeSetRows(setsForExercise)}',
    );
    final roleLabel = latest?['set_role'] as String? ?? 'TOP';
    final isAmrapLabel = (latest?['is_amrap'] as int? ?? 0) == 1;
    if (!mounted) return;
    setState(() {
      _lastLogged = LastLoggedSet(
        exerciseName: info.exerciseName,
        reps: reps,
        weight: weight,
        role: roleLabel,
        isAmrap: isAmrapLabel,
        sessionSetCount: setsForExercise.length,
      );
      _lastExerciseInfo = info;
      _prompt = null;
      _pending = null;
    });
  }

  List<String> _dedupeList(List<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      final key = trimmed.toLowerCase();
      if (trimmed.isEmpty || seen.contains(key)) continue;
      seen.add(key);
      result.add(trimmed);
    }
    return result;
  }

  List<String> _limitList(List<String> values, int max) {
    if (values.length <= max) return values;
    return values.sublist(0, max);
  }

  Future<void> _refreshCloudSettingsForVoice() async {
    final enabled = await _settingsRepo.getCloudEnabled();
    final apiKey = await _settingsRepo.getCloudApiKey();
    final model = await _settingsRepo.getCloudModel();
    final provider = await _settingsRepo.getCloudProvider();
    if (!mounted) return;
    if (enabled != _cloudEnabled ||
        apiKey != _cloudApiKey ||
        model != _cloudModel ||
        provider != _cloudProvider) {
      setState(() {
        _cloudEnabled = enabled;
        _cloudApiKey = apiKey;
        _cloudModel = model;
        _cloudProvider = provider;
      });
    }
  }

  Future<void> _handleVoiceInput(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    await _refreshCloudSettingsForVoice();
    final cloudKeyPresent =
        _cloudApiKey != null && _cloudApiKey!.trim().isNotEmpty;
    final cloudStatus = _cloudEnabled
        ? (cloudKeyPresent
            ? 'On (${_cloudProvider}/${_cloudModel})'
            : 'On (missing key)')
        : 'Off';
    _setVoiceDebug(
      transcript: trimmed,
      rule: '-',
      llm: '-',
      gemini: '-',
      openai: '-',
      cloud: cloudStatus,
      decision: 'Listening...',
      parts: null,
      llmRaw: null,
      geminiRaw: null,
      openaiRaw: null,
      resolved: null,
    );

    if (await _handlePendingVoice(trimmed)) return;

    if (_cloudEnabled && cloudKeyPresent) {
      if (_cloudProvider == 'openai') {
        final openAiCommand = await _runOpenAiParse(trimmed);
        if (openAiCommand != null) {
          final normalized =
              _normalizeLogSetFromTranscript(openAiCommand, trimmed);
          _setVoiceDebug(
            openai: _describeCommand(normalized),
            decision: 'OpenAI primary',
          );
          await _handleParsedCommand(
            normalized,
            transcript: trimmed,
            source: 'openai',
          );
          return;
        }
        if (_openAiParser.lastError != null) {
          _setVoiceDebug(
            decision: 'OpenAI failed: ${_openAiParser.lastError}',
          );
        }
      } else {
        final geminiCommand = await _runGeminiParse(trimmed);
        if (geminiCommand != null) {
          final normalized =
              _normalizeLogSetFromTranscript(geminiCommand, trimmed);
          _setVoiceDebug(
            gemini: _describeCommand(normalized),
            decision: 'Gemini primary',
          );
          await _handleParsedCommand(
            normalized,
            transcript: trimmed,
            source: 'gemini',
          );
          return;
        }
        if (_geminiParser.lastError != null) {
          _setVoiceDebug(
            decision: 'Gemini failed: ${_geminiParser.lastError}',
          );
        }
      }
    } else if (_cloudEnabled) {
      _setVoiceDebug(decision: 'Cloud enabled but missing API key');
    }

    final llmCommand = _llmParser.enabled ? await _runLlmParse(trimmed) : null;
    if (llmCommand != null) {
      final normalized = _normalizeLogSetFromTranscript(llmCommand, trimmed);
      _setVoiceDebug(
        llm: _describeCommand(normalized),
        decision: 'Local LLM',
      );
      await _handleParsedCommand(
        normalized,
        transcript: trimmed,
        source: 'local_llm',
      );
      return;
    }

    final ruleCommand = _parser.parse(trimmed);
    if (ruleCommand != null) {
      final normalized = _normalizeLogSetFromTranscript(ruleCommand, trimmed);
      _setVoiceDebug(
        rule: _describeCommand(normalized),
        decision: 'Rule fallback',
      );
      await _handleParsedCommand(
        normalized,
        transcript: trimmed,
        source: 'rule',
      );
      return;
    }

    if (_llmParser.enabled && _llmParser.lastError != null) {
      _setVoiceDebug(
        decision: 'LLM failed: ${_llmParser.lastError}',
      );
      _showMessage('LLM parse failed: ${_llmParser.lastError}');
      return;
    }

    final fallbackParts = _parser.parseLogPartsWithOrderHints(trimmed);
    if (fallbackParts.reps != null || fallbackParts.weight != null) {
      final exerciseInfo = await _resolveExercise(trimmed);
      if (exerciseInfo != null) {
        await _logSetWithFill(
          exerciseInfo,
          reps: fallbackParts.reps,
          weight: fallbackParts.weight,
          weightUnit: fallbackParts.weightUnit,
          partials: fallbackParts.partials,
          rpe: fallbackParts.rpe,
          rir: fallbackParts.rir,
          source: 'fallback',
          transcript: trimmed,
        );
        return;
      }
    }

    _setVoiceDebug(decision: 'No parse matched');
    _showMessage('Could not parse command: "$trimmed"');
  }

  Future<bool> _handlePendingVoice(String input) async {
    final pending = _pending;
    if (pending == null) return false;
    final wantsSame = _wantsSameAsLast(input);
    final latest = await _workoutRepo
        .getLatestSetForSessionExercise(pending.exerciseInfo.sessionExerciseId);
    final lastReps = latest?['reps'] as int?;
    final lastWeight = latest?['weight_value'] as double?;
    final lastUnit = latest?['weight_unit'] as String?;

    if (wantsSame && latest != null) {
      if (lastReps != null && lastWeight != null) {
        await _logSetFromVoice(
          pending.exerciseInfo,
          reps: lastReps,
          weight: lastWeight,
          weightUnit: lastUnit ?? 'lb',
          partials: pending.partials,
          rpe: pending.rpe,
          rir: pending.rir,
        );
        setState(() {
          _pending = null;
          _prompt = null;
        });
        _setVoiceDebug(decision: 'Pending resolved via last set');
        return true;
      }
    }

    final parts = _parser.parseLogPartsWithOrderHints(input);
    if (pending.missingField == _PendingField.weight) {
      final weight = parts.weight ?? _parser.parseWeightOnly(input);
      if (weight == null) {
        _showMessage('Need weight.');
        return true;
      }
      final reps = pending.reps ?? lastReps;
      if (reps == null) {
        _showMessage('Need reps.');
        return true;
      }
      await _logSetFromVoice(
        pending.exerciseInfo,
        reps: reps,
        weight: weight,
        weightUnit: parts.weightUnit ?? pending.weightUnit ?? lastUnit ?? 'lb',
        partials: pending.partials,
        rpe: pending.rpe,
        rir: pending.rir,
      );
    } else {
      final reps = parts.reps;
      if (reps == null) {
        _showMessage('Need reps.');
        return true;
      }
      final weight = pending.weight ?? lastWeight;
      if (weight == null) {
        _showMessage('Need weight.');
        return true;
      }
      await _logSetFromVoice(
        pending.exerciseInfo,
        reps: reps,
        weight: weight,
        weightUnit: pending.weightUnit ?? parts.weightUnit ?? lastUnit ?? 'lb',
        partials: pending.partials,
        rpe: pending.rpe,
        rir: pending.rir,
      );
    }
    setState(() {
      _pending = null;
      _prompt = null;
    });
    _setVoiceDebug(decision: 'Pending resolved');
    return true;
  }

  bool _wantsSameAsLast(String input) {
    final normalized = _parser.normalize(input);
    return normalized.contains('same as last') ||
        normalized.contains('same as previous') ||
        normalized.contains('repeat last') ||
        normalized.contains('same as before') ||
        normalized.contains('copy last') ||
        normalized == 'same set';
  }

  Future<void> _handleParsedCommand(
    NluCommand parsed, {
    String? transcript,
    String source = 'rule',
  }) async {
    switch (parsed.type) {
      case 'undo':
        await _undo();
        _setVoiceDebug(decision: 'Undo ($source)');
        return;
      case 'redo':
        await _redo();
        _setVoiceDebug(decision: 'Redo ($source)');
        return;
      case 'switch':
        if (parsed.exerciseRef == null) return;
        final exerciseInfo = await _resolveExercise(parsed.exerciseRef!);
        if (exerciseInfo != null) {
          _setActiveExercise(exerciseInfo);
          _setVoiceDebug(
            decision: 'Switch ($source)',
            resolved: 'exercise=${exerciseInfo.exerciseName}',
          );
        }
        return;
      case 'show_stats':
        _showMessage('Stats view not in demo.');
        _setVoiceDebug(decision: 'Show stats ($source)');
        return;
      case 'log_set':
        await _handleLogSetCommand(
          parsed,
          transcript ?? '',
          source: source,
        );
        return;
    }
  }

  Future<void> _handleLogSetCommand(
    NluCommand command,
    String transcript, {
    required String source,
  }) async {
    final normalized = _normalizeLogSetFromTranscript(command, transcript);
    final wantsSame = _wantsSameAsLast(transcript);
    final exerciseInfo = await _resolveExerciseForLogSet(normalized, transcript,
        wantsSame: wantsSame);
    if (exerciseInfo == null) {
      _setVoiceDebug(decision: 'No exercise match ($source)');
      _prompt = 'Which exercise?';
      _showMessage('No exercise match.');
      return;
    }

    await _logSetWithFill(
      exerciseInfo,
      reps: normalized.reps,
      weight: normalized.weight,
      weightUnit: normalized.weightUnit,
      partials: normalized.partials,
      rpe: normalized.rpe,
      rir: normalized.rir,
      source: source,
      transcript: transcript,
      wantsSame: wantsSame,
    );
  }

  Future<SessionExerciseInfo?> _resolveExerciseForLogSet(
    NluCommand command,
    String transcript, {
    required bool wantsSame,
  }) async {
    final ref = command.exerciseRef?.trim();
    if (ref != null && ref.isNotEmpty) {
      return _resolveExercise(ref);
    }
    if (wantsSame && _lastExerciseInfo != null) {
      return _lastExerciseInfo;
    }
    if (_lastExerciseInfo == null && _sessionExercises.length == 1) {
      return _sessionExercises.first;
    }
    final inferred = await _resolveExercise(transcript);
    return inferred ?? _lastExerciseInfo;
  }

  Future<void> _logSetWithFill(
    SessionExerciseInfo exerciseInfo, {
    required int? reps,
    required double? weight,
    required String? weightUnit,
    required int? partials,
    required double? rpe,
    required double? rir,
    required String source,
    required String transcript,
    bool wantsSame = false,
  }) async {
    final latest = await _workoutRepo
        .getLatestSetForSessionExercise(exerciseInfo.sessionExerciseId);
    final lastReps = latest?['reps'] as int?;
    final lastWeight = latest?['weight_value'] as double?;
    final lastUnit = latest?['weight_unit'] as String?;

    var resolvedReps = reps;
    var resolvedWeight = weight;
    var resolvedUnit = weightUnit ?? lastUnit ?? 'lb';

    if (wantsSame && latest != null) {
      resolvedReps ??= lastReps;
      resolvedWeight ??= lastWeight;
      resolvedUnit = weightUnit ?? lastUnit ?? resolvedUnit;
    }

    if (latest != null) {
      if (resolvedWeight == null && resolvedReps != null) {
        resolvedWeight = lastWeight;
        resolvedUnit = weightUnit ?? lastUnit ?? resolvedUnit;
      }
      if (resolvedReps == null && resolvedWeight != null) {
        resolvedReps = lastReps;
      }
    }

    if (resolvedReps == null && resolvedWeight == null && latest == null) {
      final numbers = _parser.extractNumbers(transcript);
      if (numbers.length >= 2) {
        final sorted = List<double>.from(numbers)..sort();
        resolvedReps = sorted.first.round();
        resolvedWeight = sorted.last;
        resolvedUnit = weightUnit ?? resolvedUnit;
        _setVoiceDebug(decision: 'Assumed larger=weight ($source)');
      }
    }

    if (resolvedReps == null) {
      setState(() {
        _pending = _PendingLogSet(
          exerciseInfo: exerciseInfo,
          missingField: _PendingField.reps,
          weight: resolvedWeight,
          weightUnit: resolvedUnit,
          partials: partials,
          rpe: rpe,
          rir: rir,
        );
        _prompt = 'What reps?';
      });
      _setVoiceDebug(decision: 'Awaiting reps ($source)');
      return;
    }

    if (resolvedWeight == null) {
      setState(() {
        _pending = _PendingLogSet(
          exerciseInfo: exerciseInfo,
          missingField: _PendingField.weight,
          reps: resolvedReps,
          partials: partials,
          rpe: rpe,
          rir: rir,
        );
        _prompt = 'What weight?';
      });
      _setVoiceDebug(decision: 'Awaiting weight ($source)');
      return;
    }

    await _logSetFromVoice(
      exerciseInfo,
      reps: resolvedReps,
      weight: resolvedWeight,
      weightUnit: resolvedUnit,
      partials: partials,
      rpe: rpe,
      rir: rir,
    );
    _setVoiceDebug(
      decision: 'Logged ($source)',
      resolved:
          'exercise=${exerciseInfo.exerciseName} reps=$resolvedReps weight=$resolvedWeight unit=$resolvedUnit',
    );
  }

  Future<void> _logSetFromVoice(
    SessionExerciseInfo info, {
    required int reps,
    double? weight,
    String weightUnit = 'lb',
    int? partials,
    double? rpe,
    double? rir,
  }) async {
    final drafts = _draftSetsByExerciseId[info.sessionExerciseId];
    final canUseDraft = (drafts != null && drafts.isNotEmpty) &&
        (partials == null && rpe == null && rir == null) &&
        (weight == null || weightUnit == _weightUnit);
    if (canUseDraft) {
      final draft = drafts!.first;
      draft.reps.text = reps.toString();
      draft.weight.text = weight == null ? '' : _formatSetWeight(weight);
      await _commitDraftSet(info, draft);
      return;
    }
    await _logSet(
      info,
      reps: reps,
      weight: weight,
      weightUnit: weightUnit,
      partials: partials,
      rpe: rpe,
      rir: rir,
    );
  }

  Future<NluCommand?> _runLlmParse(String transcript) async {
    setState(() {
      _prompt = 'Thinking...';
    });
    final result = await _llmParser.parse(transcript);
    setState(() {
      _prompt = null;
    });
    if (_llmParser.lastRawOutput != null) {
      _setVoiceDebug(llmRaw: _llmParser.lastRawOutput);
    }
    return result;
  }

  Future<NluCommand?> _runGeminiParse(String transcript) async {
    setState(() {
      _prompt = 'Thinking (cloud)...';
    });
    final apiKey = _cloudApiKey;
    if (apiKey == null || apiKey.isEmpty) {
      setState(() {
        _prompt = null;
      });
      return null;
    }
    final result = await _geminiParser.parse(
      transcript: transcript,
      apiKey: apiKey,
      model: _cloudModel,
      currentDayExercises: _currentDayExerciseNames,
      otherDayExercises: _otherDayExerciseNames,
      catalogExercises: _catalogExerciseNames,
    );
    setState(() {
      _prompt = null;
    });
    if (_geminiParser.lastRawOutput != null) {
      _setVoiceDebug(geminiRaw: _geminiParser.lastRawOutput);
    }
    return result;
  }

  Future<NluCommand?> _runOpenAiParse(String transcript) async {
    setState(() {
      _prompt = 'Thinking (cloud)...';
    });
    final apiKey = _cloudApiKey;
    if (apiKey == null || apiKey.isEmpty) {
      setState(() {
        _prompt = null;
      });
      return null;
    }
    final result = await _openAiParser.parse(
      transcript: transcript,
      apiKey: apiKey,
      model: _cloudModel,
      currentDayExercises: _currentDayExerciseNames,
      otherDayExercises: _otherDayExerciseNames,
      catalogExercises: _catalogExerciseNames,
    );
    setState(() {
      _prompt = null;
    });
    if (_openAiParser.lastRawOutput != null) {
      _setVoiceDebug(openaiRaw: _openAiParser.lastRawOutput);
    }
    return result;
  }

  bool _shouldTryLlm(NluCommand parsed) {
    if (!_llmParser.isReady) return false;
    if (_commandQuality(parsed) < 2) return true;
    if (parsed.type == 'log_set' && !_hasSessionMatch(parsed.exerciseRef)) {
      return true;
    }
    if (parsed.type == 'log_set') {
      return true;
    }
    return false;
  }

  bool _preferLlm(NluCommand rule, NluCommand llm) {
    final ruleQuality = _commandQuality(rule);
    final llmQuality = _commandQuality(llm);
    if (llmQuality > ruleQuality) return true;
    if (llmQuality == ruleQuality &&
        llm.type == 'log_set' &&
        _hasSessionMatch(llm.exerciseRef) &&
        !_hasSessionMatch(rule.exerciseRef)) {
      return true;
    }
    return false;
  }

  int _commandQuality(NluCommand command) {
    switch (command.type) {
      case 'undo':
      case 'redo':
      case 'rest':
        return 2;
      case 'switch':
      case 'show_stats':
        return command.exerciseRef == null ? 1 : 2;
      case 'log_set':
        if (command.exerciseRef == null || command.reps == null) return 1;
        return 2;
    }
    return 0;
  }

  bool _hasSessionMatch(String? exerciseRef) {
    if (exerciseRef == null || exerciseRef.trim().isEmpty) return false;
    return _matchSessionExercises(exerciseRef).isNotEmpty;
  }

  void _setVoiceDebug({
    String? transcript,
    String? rule,
    String? llm,
    String? gemini,
    String? openai,
    String? cloud,
    String? decision,
    String? parts,
    String? llmRaw,
    String? geminiRaw,
    String? openaiRaw,
    String? resolved,
  }) {
    final hints = _parser
        .parseLogPartsWithOrderHints(_debugTranscript ?? transcript ?? '');
    setState(() {
      _debugTranscript = transcript ?? _debugTranscript;
      _debugRule = rule ?? _debugRule;
      _debugLlm = llm ?? _debugLlm;
      _debugGemini = gemini ?? _debugGemini;
      _debugOpenAi = openai ?? _debugOpenAi;
      _debugCloud = cloud ?? _debugCloud;
      _debugDecision = decision ?? _debugDecision;
      _debugParts = parts ??
          'hints: weight=${hints.weight}, reps=${hints.reps}, unit=${hints.weightUnit}, partials=${hints.partials}';
      _debugLlmRaw = llmRaw ?? _debugLlmRaw;
      _debugGeminiRaw = geminiRaw ?? _debugGeminiRaw;
      _debugOpenAiRaw = openaiRaw ?? _debugOpenAiRaw;
      _debugResolved = resolved ?? _debugResolved;
    });
  }

  String _describeCommand(NluCommand command) {
    return 'type=${command.type} ex=${command.exerciseRef} weight=${command.weight} '
        'unit=${command.weightUnit} reps=${command.reps} partials=${command.partials} '
        'rpe=${command.rpe} rir=${command.rir} rest=${command.restSeconds}';
  }

  NluCommand _normalizeLogSetFromTranscript(
      NluCommand command, String transcript) {
    if (command.type != 'log_set') return command;
    final parts = _parser.parseLogPartsWithOrderHints(transcript);
    var weight = command.weight ?? parts.weight;
    var reps = command.reps ?? parts.reps;
    final normalized = _parser.normalize(transcript);
    final hasRepsKeyword = normalized.contains('reps');
    final hasUnitKeyword =
        RegExp(r'\b(kg|kilograms|kilo|lbs|lb|pounds)\b').hasMatch(normalized);
    if (hasRepsKeyword &&
        hasUnitKeyword &&
        parts.reps != null &&
        parts.weight != null) {
      weight = parts.weight;
      reps = parts.reps;
    }
    if (weight != null &&
        reps != null &&
        parts.weight != null &&
        parts.reps != null) {
      final partsWeight = parts.weight!;
      final partsReps = parts.reps!;
      final swapped = weight < reps && partsWeight > partsReps;
      final extreme = reps >= 80 && partsReps < reps && partsWeight > partsReps;
      if (swapped || extreme) {
        weight = partsWeight;
        reps = partsReps;
      }
    }
    return NluCommand(
      type: command.type,
      exerciseRef: command.exerciseRef,
      weight: weight,
      weightUnit: command.weightUnit ?? parts.weightUnit,
      reps: reps,
      partials: command.partials ?? parts.partials,
      rpe: command.rpe ?? parts.rpe,
      rir: command.rir ?? parts.rir,
      restSeconds: command.restSeconds,
    );
  }

  Future<SessionExerciseInfo?> _resolveExercise(String exerciseRef) async {
    final normalized = _matcher.normalizeForCache(exerciseRef);
    final cached = _cacheRefToExerciseId[normalized];
    if (cached != null) {
      final info = _exerciseById[cached];
      if (info != null) return info;
      _cacheRefToExerciseId.remove(normalized);
    }

    final sessionMatches = _matchSessionExercises(exerciseRef);
    if (sessionMatches.isNotEmpty) {
      final info = sessionMatches.length == 1
          ? sessionMatches.first
          : await _showSessionDisambiguation(sessionMatches);
      if (info == null) return null;
      _cacheRefToExerciseId[normalized] = info.exerciseId;
      return info;
    }

    final match = await _matcher.match(exerciseRef);
    if (match.isNone) {
      _showMessage('No exercise match.');
      return null;
    }

    final ExerciseMatch? selected = match.isSingle
        ? match.matches.first
        : await _showDisambiguation(match.matches);
    if (selected == null) return null;

    final existing = _exerciseById[selected.id];
    if (existing != null) {
      _cacheRefToExerciseId[normalized] = selected.id;
      return existing;
    }

    final add = await _confirmAddExercise(selected.name);
    if (!add) return null;

    final added = await _addExerciseToSession(selected);
    if (added == null) return null;
    _cacheRefToExerciseId[normalized] = selected.id;
    return added;
  }

  Future<void> _logSet(
    SessionExerciseInfo info, {
    required int reps,
    double? weight,
    String weightUnit = 'lb',
    int? partials,
    double? rpe,
    double? rir,
  }) async {
    final restSeconds = _restSecondsForExercise(info);
    final result = await _dispatcher.dispatch(
      LogSetEntry(
        sessionExerciseId: info.sessionExerciseId,
        weightUnit: weightUnit,
        weightMode: info.weightModeDefault,
        weight: weight,
        reps: reps,
        partials: partials,
        rpe: rpe,
        rir: rir,
        restSecActual: restSeconds,
      ),
    );
    if (result.inverse != null) {
      _undoRedo.pushUndo(result.inverse!);
    }
    final latest = await _workoutRepo
        .getLatestSetForSessionExercise(info.sessionExerciseId);
    final setsForExercise =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    final role = latest?['set_role'] as String? ?? 'TOP';
    final isAmrap = (latest?['is_amrap'] as int? ?? 0) == 1;
    final latestId = latest?['id'] as int?;
    if (latestId != null) {
      _startInlineRest(
        setId: latestId,
        restSeconds: restSeconds,
        exerciseId: info.exerciseId,
      );
    }
    _refreshInlineSetData(info);
    setState(() {
      _lastLogged = LastLoggedSet(
        exerciseName: info.exerciseName,
        reps: reps,
        weight: weight,
        role: role,
        isAmrap: isAmrap,
        sessionSetCount: setsForExercise.length,
      );
      _lastExerciseInfo = info;
      _prompt = null;
      _pending = null;
    });
  }

  Future<void> _updateSet(
    int id, {
    double? weight,
    int? reps,
    int? partials,
    double? rpe,
    double? rir,
    int? restSecActual,
  }) async {
    final result = await _dispatcher.dispatch(
      UpdateSetEntry(
        id: id,
        weight: weight,
        reps: reps,
        partials: partials,
        rpe: rpe,
        rir: rir,
        restSecActual: restSecActual,
      ),
    );
    if (result.inverse != null) {
      _undoRedo.pushUndo(result.inverse!);
    }
    setState(() {});
  }

  Future<void> _deleteSet(int id, SessionExerciseInfo info) async {
    if (_isLoggingSet) return;
    final beforeSets =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    _pushSetDebug(
      '[delete] ex=${info.sessionExerciseId} id=$id beforeCount=${beforeSets.length} '
      'rows=${_summarizeSetRows(beforeSets)}',
    );
    final result = await _dispatcher.dispatch(DeleteSetEntry(id));
    if (result.inverse != null) {
      _undoRedo.pushUndo(result.inverse!);
    }
    final afterSets =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    _pushSetDebug(
      '[delete] ex=${info.sessionExerciseId} id=$id afterCount=${afterSets.length} '
      'rows=${_summarizeSetRows(afterSets)}',
    );
    final cached = _inlineSetCache[info.sessionExerciseId];
    if (cached != null) {
      final updatedSets = List<Map<String, Object?>>.from(cached.sets)
        ..removeWhere((row) => row['id'] == id);
      _inlineSetCache[info.sessionExerciseId] = _InlineSetData(
        sets: updatedSets,
        previousSets: cached.previousSets,
      );
    }
    _completedRestSetIds.remove(id);
    _refreshInlineSetData(info);
    if (AppShellController.instance.restActiveSetId == id) {
      _completeInlineRest();
      _completedRestSetIds.remove(id);
    }
    if (!mounted) return;
    setState(() {});
  }

  void _removeDraftSet(SessionExerciseInfo info, _DraftSet draft) {
    final list = _draftSetsByExerciseId[info.sessionExerciseId];
    if (list == null) return;
    _pushSetDebug('[draft-delete] ex=${info.sessionExerciseId}');
    list.remove(draft);
    draft.dispose();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _undo() async {
    final cmd = _undoRedo.popUndo();
    if (cmd == null) return;
    final result = await _dispatcher.dispatch(cmd);
    if (result.inverse != null) {
      _undoRedo.pushRedo(result.inverse!);
    }
    setState(() {});
  }

  Future<void> _redo() async {
    final cmd = _undoRedo.popRedo();
    if (cmd == null) return;
    final result = await _dispatcher.dispatch(cmd);
    if (result.inverse != null) {
      _undoRedo.pushUndo(result.inverse!);
    }
    setState(() {});
  }

  void _setActiveExercise(SessionExerciseInfo info) {
    if (_lastExerciseInfo?.sessionExerciseId == info.sessionExerciseId) return;
    _lastExerciseInfo = info;
  }

  void _startRestTimer([int seconds = 120]) {
    AppShellController.instance.startRestTimer(seconds: seconds);
  }

  void _stopRestTimer() {
    AppShellController.instance.completeRestTimer();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _handlePendingSessionVoice() async {
    if (!mounted || _handlingPendingSessionVoice) return;
    final pending = AppShellController.instance.pendingSessionVoice.value;
    if (pending == null || pending.trim().isEmpty) return;
    _handlingPendingSessionVoice = true;
    AppShellController.instance.clearPendingSessionVoice();
    try {
      await _handleVoiceInput(pending.trim());
    } finally {
      _handlingPendingSessionVoice = false;
    }
  }

  Future<void> _runVoice() async {
    if (_listening) {
      await _stopVoiceListening();
      return;
    }
    if (!SpeechToTextEngine.instance.isAvailable) {
      final text = await _promptVoiceText();
      if (text == null || text.trim().isEmpty) return;
      await _handleVoiceInput(text);
      return;
    }
    await _startVoiceListening();
  }

  Future<void> _startVoiceListening() async {
    if (_listening) return;
    setState(() {
      _listening = true;
      _voicePartial = null;
    });
    try {
      await SpeechToTextEngine.instance.startListening(
        onPartial: (text) {
          setState(() => _voicePartial = text);
        },
        onResult: (text) async {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _voicePartial = null;
          });
          await _handleVoiceInput(text);
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _voicePartial = null;
          });
          final text = error.toString();
          if (text.contains('Microphone permission denied')) {
            _showMessage(
                'Microphone access is disabled. Enable it in Settings > Ora.');
          } else {
            _showMessage('Voice error: $error');
          }
        },
      );
    } catch (e) {
      setState(() {
        _listening = false;
        _voicePartial = null;
      });
      _showMessage('Voice unavailable: $e');
    }
  }

  Future<void> _stopVoiceListening() async {
    await SpeechToTextEngine.instance.stopListening();
    setState(() {
      _listening = false;
      _voicePartial = null;
    });
  }

  Future<String?> _promptVoiceText() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Voice input (fallback)'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Type command'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).pop(controller.text.trim()),
                child: const Text('Send')),
          ],
        );
      },
    );
    return result;
  }

  Future<ExerciseMatch?> _showDisambiguation(
      List<ExerciseMatch> matches) async {
    return showModalBottomSheet<ExerciseMatch>(
      context: context,
      builder: (context) {
        return ListView.separated(
          shrinkWrap: true,
          itemCount: matches.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final match = matches[index];
            return ListTile(
              title: Text(match.name),
              onTap: () => Navigator.of(context).pop(match),
            );
          },
        );
      },
    );
  }

  Future<SessionExerciseInfo?> _showSessionDisambiguation(
      List<SessionExerciseInfo> matches) async {
    return showModalBottomSheet<SessionExerciseInfo>(
      context: context,
      builder: (context) {
        return ListView.separated(
          shrinkWrap: true,
          itemCount: matches.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final match = matches[index];
            return ListTile(
              title: Text(match.exerciseName),
              subtitle: const Text('In current session'),
              onTap: () => Navigator.of(context).pop(match),
            );
          },
        );
      },
    );
  }

  Future<bool> _confirmAddExercise(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add to session?'),
        content: Text('$name is not in this session. Add it now?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Add')),
        ],
      ),
    );
    return result ?? false;
  }

  Future<SessionExerciseInfo?> _addExerciseToSession(
      ExerciseMatch match) async {
    final row = await _exerciseRepo.getById(match.id);
    if (row == null) return null;
    final orderIndex = _sessionExercises.length;
    final sessionExerciseId = await _workoutRepo.addSessionExercise(
      workoutSessionId: widget.contextData.sessionId,
      exerciseId: match.id,
      orderIndex: orderIndex,
    );
    final info = SessionExerciseInfo(
      sessionExerciseId: sessionExerciseId,
      exerciseId: match.id,
      exerciseName: row['canonical_name'] as String? ?? match.name,
      weightModeDefault: row['weight_mode_default'] as String? ?? 'TOTAL',
      planBlocks: const [],
    );
    setState(() {
      _sessionExercises.add(info);
      _exerciseById[info.exerciseId] = info;
      _sessionExerciseById[info.sessionExerciseId] = info;
      _draftSetsByExerciseId.putIfAbsent(info.sessionExerciseId, () => []).add(
            _DraftSet(
              restSeconds: _restSecondsForExercise(info),
              targetSetIndex: 1,
            ),
          );
      _currentDayExerciseNames =
          _sessionExercises.map((e) => e.exerciseName).toList();
      _lastExerciseInfo = info;
    });
    return info;
  }

  List<SessionExerciseInfo> _matchSessionExercises(String exerciseRef) {
    final refTokens = _matcher.tokenize(exerciseRef);
    if (refTokens.isEmpty) return [];
    final scored = <_SessionMatchScore>[];
    for (final info in _sessionExercises) {
      final score = _matcher.scoreName(exerciseRef, info.exerciseName);
      if (score >= _sessionMatchThreshold) {
        scored.add(_SessionMatchScore(info, score));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((entry) => entry.info).toList();
  }

  SessionExerciseInfo? _guessSessionExercise(String utterance) {
    SessionExerciseInfo? best;
    double bestScore = 0.0;
    for (final info in _sessionExercises) {
      final score = _matcher.scoreName(utterance, info.exerciseName);
      if (score > bestScore) {
        bestScore = score;
        best = info;
      }
    }
    return bestScore >= _sessionGuessThreshold ? best : null;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _deleteExerciseFromSession(SessionExerciseInfo info) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Exercise'),
          content: Text('Remove ${info.exerciseName} from this session?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (shouldDelete != true) return;
    final existingSets =
        await _workoutRepo.getSetsForSessionExercise(info.sessionExerciseId);
    if (AppShellController.instance.restActiveExerciseId == info.exerciseId) {
      _completeInlineRest();
    }
    for (final row in existingSets) {
      final setId = row['id'] as int?;
      if (setId != null) {
        _completedRestSetIds.remove(setId);
      }
    }
    await _workoutRepo.deleteSessionExercise(info.sessionExerciseId);
    _sessionExercises.removeWhere(
      (entry) => entry.sessionExerciseId == info.sessionExerciseId,
    );
    _exerciseById.remove(info.exerciseId);
    _sessionExerciseById.remove(info.sessionExerciseId);
    _draftSetsByExerciseId.remove(info.sessionExerciseId)?.forEach(
          (draft) => draft.dispose(),
        );
    _inlineSetCache.remove(info.sessionExerciseId);
    _inlineSetFutures.remove(info.sessionExerciseId);
    _inlineDebugSnapshot.remove(info.sessionExerciseId);
    _currentDayExerciseNames =
        _sessionExercises.map((e) => e.exerciseName).toList();
    if (_lastExerciseInfo?.sessionExerciseId == info.sessionExerciseId) {
      _lastExerciseInfo =
          _sessionExercises.isEmpty ? null : _sessionExercises.last;
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openExerciseHistory(SessionExerciseInfo info) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryScreen(
          initialExerciseId: info.exerciseId,
          mode: HistoryMode.exercise,
        ),
      ),
    );
  }

  Future<void> _cancelSession() async {
    if (widget.isEditing) {
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }
    await _workoutRepo.deleteSession(widget.contextData.sessionId);
    _sessionEnded = true;
    AppShellController.instance.setActiveSession(false);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _finishSession() async {
    if (!widget.isEditing) {
      await _workoutRepo.endSession(widget.contextData.sessionId);
      _sessionEnded = true;
      AppShellController.instance.setActiveSession(false);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _promptAddExercise() async {
    final match = await Navigator.of(context).push<ExerciseMatch>(
      MaterialPageRoute(
        builder: (_) => const ExerciseCatalogScreen(selectionMode: true),
      ),
    );
    if (match == null || !mounted) return;
    final existing = _exerciseById[match.id];
    if (existing != null) {
      return;
    }
    await _addExerciseToSession(match);
  }

  Widget _buildSessionTopBar(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceColor = theme.colorScheme.surface.withOpacity(0.82);
    final borderColor = theme.colorScheme.onSurface.withOpacity(0.08);
    return Row(
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: surfaceColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
            ),
            child: IconButton(
              onPressed: _cancelSession,
              icon: const Icon(Icons.close_rounded),
              tooltip: widget.isEditing ? 'Close' : 'Cancel session',
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Container(
              width: 56,
              height: 6,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withOpacity(0.18),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
        ElevatedButton(
          onPressed: _finishSession,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: const Text('Finish'),
        ),
      ],
    );
  }

  Widget _buildSessionMetaChip(
      BuildContext context, IconData icon, String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.45),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurface.withOpacity(0.7),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.8),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionSummaryCard(
    BuildContext context, {
    required DateTime? startedAt,
    required String sessionTimer,
  }) {
    final theme = Theme.of(context);
    final voiceStatus = _currentVoiceStatus();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.72),
        borderRadius: BorderRadius.circular(24),
        border:
            Border.all(color: theme.colorScheme.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _sessionTitle(),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  onPressed: () {
                    setState(() {
                      _showVoiceDebug = !_showVoiceDebug;
                    });
                  },
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                  tooltip: 'More',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildSessionMetaChip(
                context,
                Icons.calendar_today_rounded,
                _formatSessionDate(startedAt),
              ),
              _buildSessionMetaChip(
                context,
                Icons.schedule_rounded,
                sessionTimer,
              ),
            ],
          ),
          if (voiceStatus != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                voiceStatus,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildExerciseChips(
      BuildContext context, SessionExerciseInfo info) {
    final muscles = _musclesByExerciseId[info.exerciseId];
    final tags = <String>[];
    if (info.planBlocks.any((b) => b.amrapLastSet)) {
      tags.add('AMRAP');
    }
    final chips = <Widget>[];
    final primary = muscles?.primary;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final secondaryColor = Theme.of(context).colorScheme.secondary;
    if (primary != null && primary.isNotEmpty) {
      chips.add(
        Chip(
          label: Text(primary),
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          backgroundColor: primaryColor.withOpacity(0.18),
          labelStyle: TextStyle(
            color: primaryColor,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
          side: BorderSide(color: primaryColor.withOpacity(0.35)),
          labelPadding: const EdgeInsets.symmetric(horizontal: 6),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    for (final secondary in muscles?.secondary ?? const []) {
      chips.add(
        Chip(
          label: Text(secondary),
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          backgroundColor: secondaryColor.withOpacity(0.12),
          labelStyle: TextStyle(
            color: secondaryColor,
            fontWeight: FontWeight.w500,
            fontSize: 11,
          ),
          side: BorderSide(color: secondaryColor.withOpacity(0.28)),
          labelPadding: const EdgeInsets.symmetric(horizontal: 6),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    for (final tag in tags) {
      chips.add(
        Chip(
          label: Text(tag, style: const TextStyle(fontSize: 11)),
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          backgroundColor: primaryColor.withOpacity(0.12),
          labelPadding: const EdgeInsets.symmetric(horizontal: 6),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return chips;
  }

  Widget _buildExerciseCard(BuildContext context, SessionExerciseInfo info) {
    final theme = Theme.of(context);
    final muscleChips = _buildExerciseChips(context, info);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.72),
        borderRadius: BorderRadius.circular(24),
        border:
            Border.all(color: theme.colorScheme.onSurface.withOpacity(0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  info.exerciseName,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                width: 38,
                height: 38,
                margin: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: IconButton(
                  onPressed: () => _openExerciseHistory(info),
                  icon: const Icon(Icons.history_rounded, size: 18),
                  tooltip: 'Exercise history',
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Container(
                width: 38,
                height: 38,
                margin: const EdgeInsets.only(left: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_horiz_rounded, size: 18),
                  tooltip: 'Exercise actions',
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onSelected: (value) {
                    if (value == 'timer') {
                      _editExerciseRestTimers(info);
                      return;
                    }
                    if (value == 'delete') {
                      _deleteExerciseFromSession(info);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'timer',
                      child: Text('Edit Exercise Timers'),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('Delete Exercise'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (muscleChips.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: muscleChips,
            ),
          ],
          const SizedBox(height: 12),
          FutureBuilder<_InlineSetData>(
            future: _getInlineSetFuture(info),
            builder: (context, snapshot) {
              final cached = _inlineSetCache[info.sessionExerciseId];
              if (snapshot.hasError) {
                _pushSetDebug(
                  '[builder] ex=${info.sessionExerciseId} error=${snapshot.error}',
                );
              }
              final useCache =
                  (snapshot.connectionState != ConnectionState.done ||
                          snapshot.hasError ||
                          snapshot.data == null) &&
                      cached != null;
              final sets = useCache ? cached!.sets : snapshot.data?.sets ?? [];
              final previousSets = useCache
                  ? cached!.previousSets
                  : snapshot.data?.previousSets ?? [];
              final drafts = _draftSetsByExerciseId[info.sessionExerciseId] ??
                  const <_DraftSet>[];
              return _buildInlineSets(
                context,
                info,
                sets,
                previousSets,
                drafts,
                renderSource: useCache ? 'render-cache' : 'render-snapshot',
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAddExerciseButton(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _promptAddExercise,
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: theme.colorScheme.primary.withOpacity(0.16),
          foregroundColor: theme.colorScheme.primary,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: const Text(
          'Add Exercises',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final startedAt = _sessionStartedAt;
    final endedAt = _sessionEndedAt;
    final sessionTimer = startedAt == null
        ? '0:00'
        : _formatSessionTimer(
            (endedAt ?? _inlineRestNow).difference(startedAt));
    return TapRegionSurface(
      child: Scaffold(
        key: _scaffoldKey,
        floatingActionButton: GestureDetector(
          onLongPressStart: (_) => _startVoiceListening(),
          onLongPressEnd: (_) => _stopVoiceListening(),
          child: FloatingActionButton(
            onPressed: _runVoice,
            child: Icon(_listening ? Icons.mic : Icons.mic_none),
          ),
        ),
        body: Stack(
          children: [
            const GlassBackground(),
            SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  _buildSessionTopBar(context),
                  const SizedBox(height: 18),
                  _buildSessionSummaryCard(
                    context,
                    startedAt: startedAt,
                    sessionTimer: sessionTimer,
                  ),
                  if (_sessionExercises.isNotEmpty) const SizedBox(height: 18),
                  for (var i = 0; i < _sessionExercises.length; i++) ...[
                    _buildExerciseCard(context, _sessionExercises[i]),
                    if (i != _sessionExercises.length - 1)
                      const SizedBox(height: 16),
                  ],
                  const SizedBox(height: 20),
                  _buildAddExerciseButton(context),
                  if (_showVoiceDebug) ...[
                    const SizedBox(height: 16),
                    GlassCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Transcript: ${_debugTranscript ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Rule: ${_debugRule ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('LLM: ${_debugLlm ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Gemini: ${_debugGemini ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('OpenAI: ${_debugOpenAi ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Cloud: ${_debugCloud ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Hints: ${_debugParts ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Decision: ${_debugDecision ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Resolved: ${_debugResolved ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('LLM raw: ${_debugLlmRaw ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('Gemini raw: ${_debugGeminiRaw ?? '-'}'),
                          const SizedBox(height: 6),
                          Text('OpenAI raw: ${_debugOpenAiRaw ?? '-'}'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

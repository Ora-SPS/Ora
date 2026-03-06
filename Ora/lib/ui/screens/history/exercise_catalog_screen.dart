import 'package:flutter/material.dart';

import '../../../data/db/db.dart';
import '../../../data/repositories/exercise_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../core/voice/muscle_enricher.dart';
import '../../../domain/services/exercise_matcher.dart';
import 'history_screen.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';

class ExerciseCatalogScreen extends StatefulWidget {
  const ExerciseCatalogScreen({
    super.key,
    this.initialQuery,
    this.selectionMode = false,
  });

  final String? initialQuery;
  final bool selectionMode;

  @override
  State<ExerciseCatalogScreen> createState() => _ExerciseCatalogScreenState();
}

class _ExerciseCatalogScreenState extends State<ExerciseCatalogScreen> {
  late final ExerciseRepo _exerciseRepo;
  final _controller = TextEditingController();
  List<Map<String, Object?>> _results = [];
  bool _isFilling = false;
  int _fillTotal = 0;
  int _fillDone = 0;
  int _activeView = 0;

  @override
  void initState() {
    super.initState();
    _exerciseRepo = ExerciseRepo(AppDatabase.instance);
    if (widget.selectionMode) {
      _activeView = 0;
    }
    if (widget.initialQuery != null && widget.initialQuery!.trim().isNotEmpty) {
      _controller.text = widget.initialQuery!.trim();
      _search(_controller.text);
    } else {
      _loadAll();
    }
  }

  Future<void> _loadAll() async {
    final all = await _exerciseRepo.getAll();
    setState(() {
      _results = all;
    });
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      await _loadAll();
      return;
    }
    final results = await _exerciseRepo.search(query, limit: 200);
    setState(() {
      _results = results;
    });
  }

  Future<void> _fillMissingMuscles() async {
    if (_isFilling) return;
    final settingsRepo = SettingsRepo(AppDatabase.instance);
    final enabled = await settingsRepo.getCloudEnabled();
    final apiKey = await settingsRepo.getCloudApiKey();
    if (!enabled || apiKey == null || apiKey.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloud parsing and an API key are required to fill muscles.')),
      );
      return;
    }

    final provider = await settingsRepo.getCloudProvider();
    final model = await settingsRepo.getCloudModel();
    final missing = await _exerciseRepo.getMissingMuscles(limit: 2000);
    if (missing.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No missing muscle assignments found.')),
      );
      return;
    }

    setState(() {
      _isFilling = true;
      _fillTotal = missing.length;
      _fillDone = 0;
    });

    final enricher = MuscleEnricher();
    var filled = 0;
    for (final exercise in missing) {
      if (!mounted) break;
      final name = exercise['canonical_name']?.toString() ?? '';
      final id = exercise['id'] as int?;
      if (name.isEmpty || id == null) {
        setState(() => _fillDone += 1);
        continue;
      }
      final info = await enricher.enrich(
        exerciseName: name,
        provider: provider,
        apiKey: apiKey,
        model: model,
      );
      if (info != null) {
        await _exerciseRepo.updateMuscles(
          exerciseId: id,
          primaryMuscle: info.primary,
          secondaryMuscles: info.secondary,
        );
        filled += 1;
      }
      if (!mounted) break;
      setState(() {
        _fillDone += 1;
      });
      await Future.delayed(const Duration(milliseconds: 120));
    }

    if (!mounted) return;
    await _loadAll();
    setState(() {
      _isFilling = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Filled muscles for $filled of ${missing.length} exercises.')),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectionMode = widget.selectionMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(selectionMode ? 'Select Exercise' : 'Exercise Catalog'),
        actions: selectionMode
            ? null
            : [
                IconButton(
                  tooltip: 'Fill missing muscles (cloud)',
                  onPressed: _isFilling ? null : _fillMissingMuscles,
                  icon: _isFilling ? const Icon(Icons.sync) : const Icon(Icons.auto_fix_high),
                ),
                const SizedBox(width: 72),
              ],
      ),
      body: Stack(
        children: [
          const GlassBackground(),
          Column(
            children: [
              if (!selectionMode)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: _activeView == 0
                            ? ElevatedButton(
                                onPressed: () => setState(() => _activeView = 0),
                                child: const Text('Catalog'),
                              )
                            : OutlinedButton(
                                onPressed: () => setState(() => _activeView = 0),
                                child: const Text('Catalog'),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _activeView == 1
                            ? ElevatedButton(
                                onPressed: () => setState(() => _activeView = 1),
                                child: const Text('History'),
                              )
                            : OutlinedButton(
                                onPressed: () => setState(() => _activeView = 1),
                                child: const Text('History'),
                              ),
                      ),
                    ],
                  ),
                ),
              if (_activeView == 0 || selectionMode) ...[
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      labelText: 'Search exercises',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _search,
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _results.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final item = _results[index];
                      final primary = item['primary_muscle'] as String?;
                      return GlassCard(
                        padding: EdgeInsets.zero,
                        child: ListTile(
                          title: Text(item['canonical_name'] as String),
                          subtitle: Text(
                            primary == null || primary.trim().isEmpty
                                ? (item['equipment_type'] as String)
                                : '${item['equipment_type']} • $primary',
                          ),
                          onTap: selectionMode
                              ? () => Navigator.of(context).pop(
                                    ExerciseMatch(
                                      id: item['id'] as int,
                                      name: item['canonical_name'] as String,
                                    ),
                                  )
                              : null,
                          trailing: selectionMode
                              ? const Icon(Icons.add_circle_outline)
                              : IconButton(
                                  icon: const Icon(Icons.show_chart),
                                  onPressed: () async {
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
                        ),
                      );
                    },
                  ),
                ),
                if (_isFilling)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: GlassCard(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('Filling muscles: $_fillDone / $_fillTotal'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ] else if (!selectionMode)
                Expanded(
                  child: HistoryScreen(embedded: true),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

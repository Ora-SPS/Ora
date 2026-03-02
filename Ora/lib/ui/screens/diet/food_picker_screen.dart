import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/food/food_database_service.dart';
import '../../../core/food/food_models.dart';
import '../../../data/repositories/diet_repo.dart';
import '../../widgets/glass/glass_card.dart';
import 'barcode_capture_screen.dart';

class FoodPickerScreen extends StatefulWidget {
  const FoodPickerScreen({
    super.key,
    required this.dietRepo,
    required this.targetDay,
    this.startWithScanner = false,
  });

  static Future<FoodLogDraft?> show(
    BuildContext context, {
    required DietRepo dietRepo,
    required DateTime targetDay,
    bool startWithScanner = false,
  }) {
    return Navigator.of(context).push<FoodLogDraft>(
      MaterialPageRoute(
        builder: (_) => FoodPickerScreen(
          dietRepo: dietRepo,
          targetDay: targetDay,
          startWithScanner: startWithScanner,
        ),
      ),
    );
  }

  final DietRepo dietRepo;
  final DateTime targetDay;
  final bool startWithScanner;

  @override
  State<FoodPickerScreen> createState() => _FoodPickerScreenState();
}

class _FoodPickerScreenState extends State<FoodPickerScreen> {
  final FoodDatabaseService _service = FoodDatabaseService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  Timer? _debounce;
  bool _loading = false;
  bool _searched = false;
  String? _infoMessage;
  List<FoodSearchItem> _items = const [];

  @override
  void initState() {
    super.initState();
    if (widget.startWithScanner) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scanBarcode());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (value.trim().length < 2) return;
      _runSearch(value.trim());
    });
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _loading = true;
      _searched = true;
      _infoMessage = null;
    });
    final response = await _service.searchFoods(query);
    if (!mounted) return;
    setState(() {
      _items = response.items;
      _infoMessage = response.infoMessage;
      _loading = false;
    });
  }

  Future<void> _scanBarcode() async {
    final barcode = await BarcodeCaptureScreen.show(context);
    if (!mounted || barcode == null || barcode.trim().isEmpty) return;
    _searchController.text = barcode.trim();
    setState(() {
      _loading = true;
      _searched = true;
      _infoMessage = null;
    });
    final response = await _service.lookupBarcode(barcode.trim());
    if (!mounted) return;
    setState(() {
      _items = response.items;
      _infoMessage = response.infoMessage;
      _loading = false;
    });
  }

  Future<void> _openEditor(FoodSearchItem item) async {
    final duplicates = item.barcode == null || item.barcode!.trim().isEmpty
        ? const <dynamic>[]
        : await widget.dietRepo.getEntriesForBarcodeOnDay(
            barcode: item.barcode!,
            day: widget.targetDay,
          );
    if (!mounted) return;
    final draft = await showModalBottomSheet<FoodLogDraft>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _FoodEditorSheet(
        item: item,
        duplicateCount: duplicates.length,
        service: _service,
      ),
    );
    if (!mounted || draft == null) return;
    Navigator.of(context).pop(draft);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Food database'),
        actions: [
          IconButton(
            onPressed: _scanBarcode,
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan barcode',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              decoration: InputDecoration(
                hintText: 'Search foods by name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _items = const [];
                            _searched = false;
                            _infoMessage = null;
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
              textInputAction: TextInputAction.search,
              onChanged: (value) {
                setState(() {});
                _onSearchChanged(value);
              },
              onSubmitted: _runSearch,
              autofocus: !widget.startWithScanner,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loading
                        ? null
                        : () => _runSearch(_searchController.text.trim()),
                    icon: const Icon(Icons.search),
                    label: const Text('Search'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _scanBarcode,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_infoMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _InfoBanner(message: _infoMessage!),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? _EmptyState(searched: _searched)
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return _FoodResultCard(
                              item: item,
                              onTap: () => _openEditor(item),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FoodResultCard extends StatelessWidget {
  const _FoodResultCard({required this.item, required this.onTap});

  final FoodSearchItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final perServing = item.defaultPortion;
    final preview = item.nutrientsPer100g.scale(perServing.grams / 100);
    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.displayName,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            if (item.packageSize != null &&
                item.packageSize!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                item.packageSize!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _ChipLabel(
                  item.kind == FoodKind.branded ? 'Branded' : 'Generic',
                ),
                _ChipLabel(
                  item.source == FoodSourceType.usda
                      ? 'USDA'
                      : item.source == FoodSourceType.custom
                          ? 'Custom'
                          : 'Open Food Facts',
                ),
                if (item.hasConflict) const _ChipLabel('Conflict'),
                if (item.isUserOverride) const _ChipLabel('Override'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${perServing.label}: ${_fmt(preview.calories)} kcal | P ${_fmt(preview.proteinG)} | C ${_fmt(preview.carbsG)} | F ${_fmt(preview.fatG)}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (item.warning != null) ...[
              const SizedBox(height: 6),
              Text(
                item.warning!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: Text(message)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searched});

  final bool searched;

  @override
  Widget build(BuildContext context) {
    if (!searched) {
      return const Center(
        child: Text('Search by food name or scan a barcode.'),
      );
    }
    return const Center(child: Text('No matching foods found.'));
  }
}

class _ChipLabel extends StatelessWidget {
  const _ChipLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}

class _FoodEditorSheet extends StatefulWidget {
  const _FoodEditorSheet({
    required this.item,
    required this.duplicateCount,
    required this.service,
  });

  final FoodSearchItem item;
  final int duplicateCount;
  final FoodDatabaseService service;

  @override
  State<_FoodEditorSheet> createState() => _FoodEditorSheetState();
}

class _FoodEditorSheetState extends State<_FoodEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _notesController;
  late final TextEditingController _quantityController;
  late final TextEditingController _caloriesController;
  late final TextEditingController _proteinController;
  late final TextEditingController _carbsController;
  late final TextEditingController _fatController;
  late final TextEditingController _fiberController;
  late final TextEditingController _sodiumController;
  final Map<String, TextEditingController> _microControllers = {};

  late FoodNutrients _basePer100g;
  late String _selectedPortionId;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.name);
    _notesController = TextEditingController(text: widget.item.notes ?? '');
    _quantityController = TextEditingController(text: '1');
    _caloriesController = TextEditingController();
    _proteinController = TextEditingController();
    _carbsController = TextEditingController();
    _fatController = TextEditingController();
    _fiberController = TextEditingController();
    _sodiumController = TextEditingController();
    _selectedPortionId = widget.item.defaultPortionId;
    _basePer100g = widget.item.nutrientsPer100g;
    _refreshControllers();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _quantityController.dispose();
    _caloriesController.dispose();
    _proteinController.dispose();
    _carbsController.dispose();
    _fatController.dispose();
    _fiberController.dispose();
    _sodiumController.dispose();
    for (final controller in _microControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  FoodPortionOption get _selectedPortion {
    for (final option in widget.item.portionOptions) {
      if (option.id == _selectedPortionId) return option;
    }
    return widget.item.defaultPortion;
  }

  double get _quantity => _parseDouble(_quantityController.text) ?? 1;

  double get _totalGrams =>
      _selectedPortion.grams * (_quantity <= 0 ? 1 : _quantity);

  void _captureEdits() {
    final nutrients = _currentFromControllers();
    if (_totalGrams > 0) {
      _basePer100g = nutrients.scale(100 / _totalGrams);
    } else {
      _basePer100g = nutrients;
    }
  }

  void _refreshControllers() {
    final current = _basePer100g.scale(_totalGrams / 100);
    _caloriesController.text = _fmtInput(current.calories);
    _proteinController.text = _fmtInput(current.proteinG);
    _carbsController.text = _fmtInput(current.carbsG);
    _fatController.text = _fmtInput(current.fatG);
    _fiberController.text = _fmtInput(current.fiberG);
    _sodiumController.text = _fmtInput(current.sodiumMg);

    final micros = current.micros ?? const {};
    final staleKeys = _microControllers.keys
        .where((key) => !micros.containsKey(key))
        .toList();
    for (final key in staleKeys) {
      _microControllers.remove(key)?.dispose();
    }
    for (final entry in micros.entries) {
      final controller = _microControllers.putIfAbsent(
        entry.key,
        () => TextEditingController(),
      );
      controller.text = _fmtInput(entry.value);
    }
    setState(() {});
  }

  FoodNutrients _currentFromControllers() {
    final micros = <String, double>{};
    for (final entry in _microControllers.entries) {
      final value = _parseDouble(entry.value.text);
      if (value != null) {
        micros[entry.key] = value;
      }
    }
    return FoodNutrients(
      calories: _parseDouble(_caloriesController.text),
      proteinG: _parseDouble(_proteinController.text),
      carbsG: _parseDouble(_carbsController.text),
      fatG: _parseDouble(_fatController.text),
      fiberG: _parseDouble(_fiberController.text),
      sodiumMg: _parseDouble(_sodiumController.text),
      micros: micros.isEmpty ? null : micros,
    );
  }

  bool _isEdited(FoodNutrients currentPer100g) {
    bool changed(double? a, double? b) {
      if (a == null && b == null) return false;
      return ((a ?? 0) - (b ?? 0)).abs() > 0.05;
    }

    if (_nameController.text.trim() != widget.item.name.trim()) {
      return true;
    }
    if (changed(
      currentPer100g.calories,
      widget.item.nutrientsPer100g.calories,
    )) {
      return true;
    }
    if (changed(
      currentPer100g.proteinG,
      widget.item.nutrientsPer100g.proteinG,
    )) {
      return true;
    }
    if (changed(currentPer100g.carbsG, widget.item.nutrientsPer100g.carbsG)) {
      return true;
    }
    if (changed(currentPer100g.fatG, widget.item.nutrientsPer100g.fatG)) {
      return true;
    }
    if (changed(currentPer100g.fiberG, widget.item.nutrientsPer100g.fiberG)) {
      return true;
    }
    if (changed(
      currentPer100g.sodiumMg,
      widget.item.nutrientsPer100g.sodiumMg,
    )) {
      return true;
    }
    final currentMicros = currentPer100g.micros ?? const {};
    final baseMicros = widget.item.nutrientsPer100g.micros ?? const {};
    final keys = {...currentMicros.keys, ...baseMicros.keys};
    for (final key in keys) {
      if (changed(currentMicros[key], baseMicros[key])) return true;
    }
    return false;
  }

  Future<void> _save() async {
    _captureEdits();
    final current = _basePer100g.scale(_totalGrams / 100);
    final edited = _isEdited(_basePer100g);
    final overrideItem = edited
        ? widget.service.buildOverrideItem(
            base: widget.item,
            mealName: _nameController.text.trim().isEmpty
                ? widget.item.name
                : _nameController.text.trim(),
            nutrients: current,
            totalGrams: _totalGrams,
            selectedPortion: _selectedPortion,
          )
        : null;
    if (!mounted) return;
    Navigator.of(context).pop(
      FoodLogDraft(
        mealName: _nameController.text.trim().isEmpty
            ? widget.item.name
            : _nameController.text.trim(),
        nutrients: current,
        portionLabel: _selectedPortion.label,
        portionGrams: _totalGrams,
        amount: _quantity <= 0 ? 1 : _quantity,
        unit: _selectedPortion.unit,
        notes: _notesController.text.trim().isEmpty
            ? widget.item.notes
            : _notesController.text.trim(),
        barcode: widget.item.barcode,
        foodSource: widget.item.source.name,
        foodSourceId: widget.item.sourceId,
        saveOverride: edited,
        overrideItem: overrideItem,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final micros = _microControllers.keys.toList()..sort();
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: GlassCard(
        padding: const EdgeInsets.all(16),
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.item.displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (widget.duplicateCount > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Already logged for this day: ${widget.duplicateCount}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ),
            if (widget.item.packageSize != null &&
                widget.item.packageSize!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(widget.item.packageSize!),
              ),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Food name'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _selectedPortionId,
              decoration: const InputDecoration(labelText: 'Portion'),
              items: widget.item.portionOptions
                  .map(
                    (option) => DropdownMenuItem(
                      value: option.id,
                      child: Text(option.label),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                _captureEdits();
                _selectedPortionId = value;
                _refreshControllers();
              },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _quantityController,
              decoration: const InputDecoration(labelText: 'Quantity'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) {
                _captureEdits();
                _refreshControllers();
              },
            ),
            const SizedBox(height: 12),
            _numberField(_caloriesController, 'Calories'),
            const SizedBox(height: 8),
            _numberField(_proteinController, 'Protein (g)'),
            const SizedBox(height: 8),
            _numberField(_carbsController, 'Carbs (g)'),
            const SizedBox(height: 8),
            _numberField(_fatController, 'Fat (g)'),
            const SizedBox(height: 8),
            _numberField(_fiberController, 'Fiber (g)'),
            const SizedBox(height: 8),
            _numberField(_sodiumController, 'Sodium (mg)'),
            if (micros.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Micros'),
              const SizedBox(height: 8),
              ...micros.map(
                (key) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _numberField(
                    _microControllers[key]!,
                    _prettyMicroLabel(key),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(labelText: 'Notes'),
              maxLines: 2,
            ),
            const SizedBox(height: 14),
            Text(
              'Edited values will be saved as a reusable custom food override.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Save meal'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  TextField _numberField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label),
    );
  }
}

double? _parseDouble(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return double.tryParse(trimmed);
}

String _fmt(double? value) {
  if (value == null) return '-';
  if ((value - value.round()).abs() < 0.05) {
    return value.round().toString();
  }
  return value.toStringAsFixed(1);
}

String _fmtInput(double? value) {
  if (value == null) return '';
  if ((value - value.round()).abs() < 0.01) {
    return value.round().toString();
  }
  return value.toStringAsFixed(1);
}

String _prettyMicroLabel(String key) {
  return key
      .replaceAll('_mg', ' (mg)')
      .replaceAll('_mcg', ' (mcg)')
      .replaceAll('_', ' ')
      .split(' ')
      .map((segment) {
    if (segment.isEmpty || segment.startsWith('(')) return segment;
    return '${segment[0].toUpperCase()}${segment.substring(1)}';
  }).join(' ');
}

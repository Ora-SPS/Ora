import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter/services.dart';

import '../../../data/db/db.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../../../data/repositories/diet_repo.dart';
import '../../../data/repositories/settings_repo.dart';
import '../../../domain/models/diet_entry.dart';
import '../../../core/cloud/diet_analysis_service.dart';
import '../../../core/food/food_database_service.dart';
import '../../../core/utils/image_downscaler.dart';
import '../../../core/voice/stt.dart';
import '../../screens/shell/app_shell_controller.dart';
import '../../../core/input/input_router.dart';
import '../../../core/cloud/upload_service.dart';
import '../../widgets/glass/glass_background.dart';
import '../../widgets/glass/glass_card.dart';
import '../../widgets/consent/cloud_consent.dart';
import 'food_picker_screen.dart';

class DietScreen extends StatefulWidget {
  const DietScreen({super.key});

  @override
  State<DietScreen> createState() => _DietScreenState();
}

class _DietScreenState extends State<DietScreen> {
  late final DietRepo _dietRepo;
  late final SettingsRepo _settingsRepo;

  DietTimeScale _timeScale = DietTimeScale.day;
  DietNutrientView _nutrientView = DietNutrientView.macros;
  bool _loading = true;
  List<DietEntry> _allMeals = const [];
  DietSummary _summary = const DietSummary();
  Map<String, double> _microsSummary = const {};
  final _imagePicker = ImagePicker();
  final _dietAnalysis = DietAnalysisService();
  final _foodDatabaseService = FoodDatabaseService();
  final _stt = SpeechToTextEngine.instance;
  bool _handlingInput = false;

  final _goalCalories = TextEditingController();
  final _goalProtein = TextEditingController();
  final _goalCarbs = TextEditingController();
  final _goalFat = TextEditingController();
  final _goalFiber = TextEditingController();
  final _goalSodium = TextEditingController();

  @override
  void initState() {
    super.initState();
    final db = AppDatabase.instance;
    _dietRepo = DietRepo(db);
    _settingsRepo = SettingsRepo(db);
    _load();
    AppShellController.instance.pendingInput.addListener(_handlePendingInput);
  }

  @override
  void dispose() {
    AppShellController.instance.pendingInput.removeListener(
      _handlePendingInput,
    );
    _goalCalories.dispose();
    _goalProtein.dispose();
    _goalCarbs.dispose();
    _goalFat.dispose();
    _goalFiber.dispose();
    _goalSodium.dispose();
    super.dispose();
  }

  Future<void> _handlePendingInput() async {
    if (!mounted || _handlingInput) return;
    final dispatch = AppShellController.instance.pendingInput.value;
    if (dispatch == null || dispatch.intent != InputIntent.dietLog) return;
    _handlingInput = true;
    AppShellController.instance.clearPendingInput();
    final event = dispatch.event;
    if (event.file != null) {
      if (_isImageFile(event.file!.path)) {
        final optimized = await ImageDownscaler.downscaleImageIfNeeded(
          event.file!,
        );
        await _analyzePhoto(optimized);
      } else {
        UploadService.instance.enqueue(
          UploadItem(
            type: UploadType.diet,
            name: event.file!.uri.pathSegments.last,
            path: event.file!.path,
          ),
        );
        UploadService.instance.uploadAll();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Diet file queued for analysis.')),
          );
        }
      }
    } else if ((dispatch.entity ?? event.text)?.trim().isNotEmpty == true) {
      await _analyzeTextLog((dispatch.entity ?? event.text!).trim());
    }
    _handlingInput = false;
  }

  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.heic');
  }

  Future<void> _load() async {
    final summary = await _loadSummaryForScale();
    final micros = await _loadMicrosForScale();
    final allMeals = await _dietRepo.getRecentEntries(limit: 200);
    await _loadGoals();
    setState(() {
      _summary = summary;
      _microsSummary = micros;
      _allMeals = allMeals;
      _loading = false;
    });
  }

  Future<DietSummary> _loadSummaryForScale() {
    final now = DateTime.now();
    final end = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    switch (_timeScale) {
      case DietTimeScale.day:
        final start = DateTime(now.year, now.month, now.day);
        return _dietRepo.getSummaryForRange(start, end);
      case DietTimeScale.week:
        final start = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 6));
        return _dietRepo.getSummaryForRange(start, end);
      case DietTimeScale.month:
        final start = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 29));
        return _dietRepo.getSummaryForRange(start, end);
    }
  }

  Future<Map<String, double>> _loadMicrosForScale() {
    final now = DateTime.now();
    final end = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(const Duration(days: 1));
    switch (_timeScale) {
      case DietTimeScale.day:
        final start = DateTime(now.year, now.month, now.day);
        return _dietRepo.getMicrosForRange(start, end);
      case DietTimeScale.week:
        final start = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 6));
        return _dietRepo.getMicrosForRange(start, end);
      case DietTimeScale.month:
        final start = DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 29));
        return _dietRepo.getMicrosForRange(start, end);
    }
  }

  Future<void> _loadGoals() async {
    _goalCalories.text =
        (await _settingsRepo.getValue('diet_goal_calories') ?? '2500');
    _goalProtein.text =
        (await _settingsRepo.getValue('diet_goal_protein') ?? '180');
    _goalCarbs.text =
        (await _settingsRepo.getValue('diet_goal_carbs') ?? '250');
    _goalFat.text = (await _settingsRepo.getValue('diet_goal_fat') ?? '70');
    _goalFiber.text = (await _settingsRepo.getValue('diet_goal_fiber') ?? '30');
    _goalSodium.text =
        (await _settingsRepo.getValue('diet_goal_sodium') ?? '2300');
  }

  Future<void> _saveGoals() async {
    await _settingsRepo.setValue(
      'diet_goal_calories',
      _goalCalories.text.trim(),
    );
    await _settingsRepo.setValue('diet_goal_protein', _goalProtein.text.trim());
    await _settingsRepo.setValue('diet_goal_carbs', _goalCarbs.text.trim());
    await _settingsRepo.setValue('diet_goal_fat', _goalFat.text.trim());
    await _settingsRepo.setValue('diet_goal_fiber', _goalFiber.text.trim());
    await _settingsRepo.setValue('diet_goal_sodium', _goalSodium.text.trim());
  }

  Future<void> _addMeal({String? initialName}) async {
    final nameController = TextEditingController();
    final caloriesController = TextEditingController();
    final proteinController = TextEditingController();
    final carbsController = TextEditingController();
    final fatController = TextEditingController();
    final fiberController = TextEditingController();
    final sodiumController = TextEditingController();
    final notesController = TextEditingController();

    if (initialName != null && initialName.trim().isNotEmpty) {
      nameController.text = initialName.trim();
    }
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('Add meal'),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Meal name'),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                _numberField(caloriesController, 'Calories', max: 6000),
                const SizedBox(height: 8),
                _numberField(proteinController, 'Protein (g)', max: 500),
                const SizedBox(height: 8),
                _numberField(carbsController, 'Carbs (g)', max: 800),
                const SizedBox(height: 8),
                _numberField(fatController, 'Fat (g)', max: 300),
                const SizedBox(height: 8),
                _numberField(fiberController, 'Fiber (g)', max: 200),
                const SizedBox(height: 8),
                _numberField(sodiumController, 'Sodium (mg)', max: 10000),
                const SizedBox(height: 8),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (result != true) return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    await _dietRepo.addEntry(
      mealName: name,
      loggedAt: DateTime.now(),
      calories: _parseAndClamp(caloriesController.text, max: 6000),
      proteinG: _parseAndClamp(proteinController.text, max: 500),
      carbsG: _parseAndClamp(carbsController.text, max: 800),
      fatG: _parseAndClamp(fatController.text, max: 300),
      fiberG: _parseAndClamp(fiberController.text, max: 200),
      sodiumMg: _parseAndClamp(sodiumController.text, max: 10000),
      notes: notesController.text.trim().isEmpty
          ? null
          : notesController.text.trim(),
    );
    await _load();
  }

  // ignore: unused_element
  Future<void> _addPreviousEntry() async {
    if (_allMeals.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No previous meals yet.')));
      return;
    }
    final selected = await showModalBottomSheet<DietEntry>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('Copy previous meal'),
                const SizedBox(height: 12),
                ..._allMeals
                    .take(20)
                    .map(
                      (meal) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(meal.mealName),
                        subtitle: Text(_formatEntry(meal)),
                        onTap: () => Navigator.of(context).pop(meal),
                      ),
                    ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null) return;
    await _dietRepo.addEntry(
      mealName: selected.mealName,
      loggedAt: DateTime.now(),
      calories: selected.calories,
      proteinG: selected.proteinG,
      carbsG: selected.carbsG,
      fatG: selected.fatG,
      fiberG: selected.fiberG,
      sodiumMg: selected.sodiumMg,
      micros: selected.micros,
      notes: selected.notes,
    );
    await _load();
  }

  Future<void> _pickMedia() async {
    final ok = await CloudConsent.ensureDietConsent(context, _settingsRepo);
    if (!ok || !mounted) return;
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.image,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;
    final optimized = await ImageDownscaler.downscaleImageIfNeeded(
      File(file.path!),
    );
    await _analyzePhoto(optimized);
  }

  Future<void> _useCamera() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Camera is available on mobile devices.')),
      );
      return;
    }
    final ok = await CloudConsent.ensureDietConsent(context, _settingsRepo);
    if (!ok || !mounted) return;
    try {
      final file = await _imagePicker.pickImage(source: ImageSource.camera);
      if (file == null) return;
      final optimized = await ImageDownscaler.downscaleImageIfNeeded(
        File(file.path),
      );
      await _analyzePhoto(optimized);
    } on PlatformException catch (error) {
      if (!mounted) return;
      final message = error.code.contains('camera')
          ? 'Camera access is disabled. Enable it in Settings > Ora.'
          : 'Camera unavailable: ${error.message ?? error.code}.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Camera unavailable. Check permissions in Settings > Ora.',
          ),
        ),
      );
    }
  }

  Future<void> _scanBarcode() async {
    if (!(Platform.isAndroid || Platform.isIOS)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Barcode scanning is available on mobile devices.'),
        ),
      );
      return;
    }
    final draft = await FoodPickerScreen.show(
      context,
      dietRepo: _dietRepo,
      startWithScanner: true,
    );
    if (!mounted || draft == null) return;
    await _dietRepo.addEntry(
      mealName: draft.mealName,
      loggedAt: DateTime.now(),
      calories: draft.nutrients.calories,
      proteinG: draft.nutrients.proteinG,
      carbsG: draft.nutrients.carbsG,
      fatG: draft.nutrients.fatG,
      fiberG: draft.nutrients.fiberG,
      sodiumMg: draft.nutrients.sodiumMg,
      micros: draft.nutrients.micros,
      notes: draft.notes,
      barcode: draft.barcode,
      foodSource: draft.foodSource,
      foodSourceId: draft.foodSourceId,
      portionLabel: draft.portionLabel,
      portionGrams: draft.portionGrams,
      portionAmount: draft.amount,
      portionUnit: draft.unit,
    );
    if (draft.saveOverride && draft.overrideItem != null) {
      await _foodDatabaseService.saveOverride(draft.overrideItem!);
    }
    await _load();
  }

  Future<void> _openFoodDatabase() async {
    final draft = await FoodPickerScreen.show(context, dietRepo: _dietRepo);
    if (!mounted || draft == null) return;
    await _dietRepo.addEntry(
      mealName: draft.mealName,
      loggedAt: DateTime.now(),
      calories: draft.nutrients.calories,
      proteinG: draft.nutrients.proteinG,
      carbsG: draft.nutrients.carbsG,
      fatG: draft.nutrients.fatG,
      fiberG: draft.nutrients.fiberG,
      sodiumMg: draft.nutrients.sodiumMg,
      micros: draft.nutrients.micros,
      notes: draft.notes,
      barcode: draft.barcode,
      foodSource: draft.foodSource,
      foodSourceId: draft.foodSourceId,
      portionLabel: draft.portionLabel,
      portionGrams: draft.portionGrams,
      portionAmount: draft.amount,
      portionUnit: draft.unit,
    );
    if (draft.saveOverride && draft.overrideItem != null) {
      await _foodDatabaseService.saveOverride(draft.overrideItem!);
    }
    await _load();
  }

  Future<String?> _pickMealImage({required bool fromCamera}) async {
    File? picked;
    if (fromCamera) {
      if (!(Platform.isAndroid || Platform.isIOS)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera is available on mobile devices.'),
          ),
        );
        return null;
      }
      try {
        final file = await _imagePicker.pickImage(source: ImageSource.camera);
        if (file == null) return null;
        picked = File(file.path);
      } on PlatformException catch (error) {
        if (mounted) {
          final message = error.code.contains('camera')
              ? 'Camera access is disabled. Enable it in Settings > Ora.'
              : 'Camera unavailable: ${error.message ?? error.code}.';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        return null;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Camera unavailable. Check permissions in Settings > Ora.',
              ),
            ),
          );
        }
        return null;
      }
    } else {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        type: FileType.image,
      );
      if (result == null || result.files.isEmpty) return null;
      final file = result.files.first;
      if (file.path == null) return null;
      picked = File(file.path!);
    }
    final optimized = await ImageDownscaler.downscaleImageIfNeeded(picked);
    final persisted = await ImageDownscaler.persistImage(optimized);
    return persisted.path;
  }

  Future<String?> _persistMealImage(String path) async {
    final persisted = await ImageDownscaler.persistImage(File(path));
    return persisted.path;
  }

  Future<void> _deleteMeal(DietEntry entry) async {
    final path = entry.imagePath;
    if (path != null) {
      final file = File(path);
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // Ignore file deletion failures to avoid blocking the DB update.
      }
    }
    await _dietRepo.deleteEntry(entry.id);
  }

  Future<void> _analyzePhoto(File file) async {
    final ok = await CloudConsent.ensureDietConsent(context, _settingsRepo);
    if (!ok || !context.mounted) return;
    final enabled = await _settingsRepo.getCloudEnabled();
    final apiKey = await _settingsRepo.getCloudApiKey();
    final provider = await _settingsRepo.getCloudProvider();
    final model = await _settingsRepo.getCloudModel();
    if (!mounted) return;
    if (!enabled || apiKey == null || apiKey.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloud analysis requires an API key.')),
      );
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Analyzing photo...')));
    final estimate = await _dietAnalysis.analyzeImage(
      file: file,
      provider: provider,
      apiKey: apiKey,
      model: model,
    );
    if (!mounted) return;
    if (estimate == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Unable to analyze photo.')));
      return;
    }
    await _reviewEstimate(estimate, imagePath: file.path);
  }

  Future<void> _analyzeTextLog(String text) async {
    final ok = await CloudConsent.ensureDietConsent(context, _settingsRepo);
    if (!ok || !mounted) return;
    final enabled = await _settingsRepo.getCloudEnabled();
    final apiKey = await _settingsRepo.getCloudApiKey();
    final provider = await _settingsRepo.getCloudProvider();
    final model = await _settingsRepo.getCloudModel();
    if (!mounted) return;
    if (!enabled || apiKey == null || apiKey.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cloud analysis requires an API key.')),
      );
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Analyzing log...')));
    final estimate = await _dietAnalysis.analyzeText(
      text: text,
      provider: provider,
      apiKey: apiKey,
      model: model,
    );
    if (!mounted) return;
    if (estimate == null) {
      await _addMeal(initialName: text);
      return;
    }
    await _reviewEstimate(estimate);
  }

  Future<void> _reviewEstimate(
    DietEstimate estimate, {
    String? imagePath,
  }) async {
    final refineController = TextEditingController();
    final servingsController = TextEditingController(text: '1');
    final servingSizeController = TextEditingController(text: '100');
    final gramsController = TextEditingController();
    final caloriesController = TextEditingController(
      text: estimate.calories?.toStringAsFixed(1) ?? '',
    );
    final proteinController = TextEditingController(
      text: estimate.proteinG?.toStringAsFixed(1) ?? '',
    );
    final carbsController = TextEditingController(
      text: estimate.carbsG?.toStringAsFixed(1) ?? '',
    );
    final fatController = TextEditingController(
      text: estimate.fatG?.toStringAsFixed(1) ?? '',
    );
    final fiberController = TextEditingController(
      text: estimate.fiberG?.toStringAsFixed(1) ?? '',
    );
    final sodiumController = TextEditingController(
      text: estimate.sodiumMg?.toStringAsFixed(0) ?? '',
    );
    final microControllers = <String, TextEditingController>{
      for (final entry in (estimate.micros ?? {}).entries)
        entry.key: TextEditingController(text: entry.value.toStringAsFixed(1)),
    };
    DietEstimate baseEstimate = estimate;
    DietEstimate current = estimate;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                Widget infoRow(String label, double? value) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('$label: ${value?.toStringAsFixed(1) ?? '-'}'),
                  );
                }

                void applyDetails() {
                  final updatedMicros = <String, double>{};
                  for (final entry in microControllers.entries) {
                    final parsed = _parseDouble(entry.value.text);
                    if (parsed != null) {
                      updatedMicros[entry.key] = parsed;
                    }
                  }
                  baseEstimate = DietEstimate(
                    mealName: baseEstimate.mealName,
                    calories: _parseDouble(caloriesController.text),
                    proteinG: _parseDouble(proteinController.text),
                    carbsG: _parseDouble(carbsController.text),
                    fatG: _parseDouble(fatController.text),
                    fiberG: _parseDouble(fiberController.text),
                    sodiumMg: _parseDouble(sodiumController.text),
                    micros: updatedMicros.isEmpty ? null : updatedMicros,
                    notes: baseEstimate.notes,
                  );
                }

                void applyMultiplier() {
                  final servings = _parseDouble(servingsController.text) ?? 1;
                  final totalGrams = _parseDouble(gramsController.text);
                  final servingSize =
                      _parseDouble(servingSizeController.text) ?? 100;
                  final multiplier = (totalGrams != null && servingSize > 0)
                      ? (totalGrams / servingSize)
                      : servings;
                  final normalized = (multiplier <= 0
                      ? 1.0
                      : multiplier.toDouble());
                  setModalState(() {
                    applyDetails();
                    current = _scaleEstimate(baseEstimate, normalized);
                  });
                }

                final micros = current.micros ?? const {};
                return ListView(
                  shrinkWrap: true,
                  children: [
                    if (imagePath != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(imagePath),
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    if (imagePath != null) const SizedBox(height: 12),
                    Text(
                      current.mealName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    infoRow('Calories', current.calories),
                    infoRow('Protein (g)', current.proteinG),
                    infoRow('Carbs (g)', current.carbsG),
                    infoRow('Fat (g)', current.fatG),
                    infoRow('Fiber (g)', current.fiberG),
                    infoRow('Sodium (mg)', current.sodiumMg),
                    if (micros.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('Micros'),
                      const SizedBox(height: 4),
                      ...micros.entries.map(
                        (e) => Text('${e.key}: ${e.value.toStringAsFixed(1)}'),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text('Quantity'),
                    const SizedBox(height: 8),
                    _numberField(
                      servingsController,
                      'Servings',
                      max: 20,
                      onChanged: (_) => applyMultiplier(),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _numberField(
                            servingSizeController,
                            'Serving size (g)',
                            max: 5000,
                            onChanged: (_) => applyMultiplier(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _numberField(
                            gramsController,
                            'Total grams',
                            max: 20000,
                            onChanged: (_) => applyMultiplier(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('Details'),
                    const SizedBox(height: 8),
                    _numberField(
                      caloriesController,
                      'Calories',
                      onChanged: (_) => applyMultiplier(),
                    ),
                    const SizedBox(height: 8),
                    _numberField(
                      proteinController,
                      'Protein (g)',
                      onChanged: (_) => applyMultiplier(),
                    ),
                    const SizedBox(height: 8),
                    _numberField(
                      carbsController,
                      'Carbs (g)',
                      onChanged: (_) => applyMultiplier(),
                    ),
                    const SizedBox(height: 8),
                    _numberField(
                      fatController,
                      'Fat (g)',
                      onChanged: (_) => applyMultiplier(),
                    ),
                    const SizedBox(height: 8),
                    _numberField(
                      fiberController,
                      'Fiber (g)',
                      onChanged: (_) => applyMultiplier(),
                    ),
                    const SizedBox(height: 8),
                    _numberField(
                      sodiumController,
                      'Sodium (mg)',
                      onChanged: (_) => applyMultiplier(),
                    ),
                    if (microControllers.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text('Micros/Vitamins'),
                      const SizedBox(height: 4),
                      ...microControllers.entries.map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _numberField(
                            entry.value,
                            entry.key,
                            onChanged: (_) => applyMultiplier(),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: refineController,
                      decoration: const InputDecoration(
                        labelText: 'Refine estimate (optional)',
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            final transcript = await _stt.listenOnce();
                            if (transcript == null ||
                                transcript.trim().isEmpty) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('No voice captured.'),
                                ),
                              );
                              return;
                            }
                            refineController.text = transcript;
                            if (!context.mounted) return;
                            await _applyRefinement(
                              transcript,
                              current,
                              (updated) => setModalState(() {
                                baseEstimate = updated;
                                caloriesController.text =
                                    updated.calories?.toStringAsFixed(1) ?? '';
                                proteinController.text =
                                    updated.proteinG?.toStringAsFixed(1) ?? '';
                                carbsController.text =
                                    updated.carbsG?.toStringAsFixed(1) ?? '';
                                fatController.text =
                                    updated.fatG?.toStringAsFixed(1) ?? '';
                                fiberController.text =
                                    updated.fiberG?.toStringAsFixed(1) ?? '';
                                sodiumController.text =
                                    updated.sodiumMg?.toStringAsFixed(0) ?? '';
                                final updatedMicros =
                                    updated.micros ?? const {};
                                for (final entry in microControllers.entries) {
                                  entry.value.text =
                                      updatedMicros[entry.key]?.toStringAsFixed(
                                        1,
                                      ) ??
                                      '';
                                }
                                applyMultiplier();
                              }),
                            );
                          },
                          icon: const Icon(Icons.mic),
                          label: const Text('Refine by voice'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            final text = refineController.text.trim();
                            if (text.isEmpty) return;
                            await _applyRefinement(
                              text,
                              current,
                              (updated) => setModalState(() {
                                baseEstimate = updated;
                                caloriesController.text =
                                    updated.calories?.toStringAsFixed(1) ?? '';
                                proteinController.text =
                                    updated.proteinG?.toStringAsFixed(1) ?? '';
                                carbsController.text =
                                    updated.carbsG?.toStringAsFixed(1) ?? '';
                                fatController.text =
                                    updated.fatG?.toStringAsFixed(1) ?? '';
                                fiberController.text =
                                    updated.fiberG?.toStringAsFixed(1) ?? '';
                                sodiumController.text =
                                    updated.sodiumMg?.toStringAsFixed(0) ?? '';
                                final updatedMicros =
                                    updated.micros ?? const {};
                                for (final entry in microControllers.entries) {
                                  entry.value.text =
                                      updatedMicros[entry.key]?.toStringAsFixed(
                                        1,
                                      ) ??
                                      '';
                                }
                                applyMultiplier();
                              }),
                            );
                          },
                          child: const Text('Apply refine text'),
                        ),
                        ElevatedButton.icon(
                          onPressed: () async {
                            String? persistedPath;
                            if (imagePath != null) {
                              persistedPath = await _persistMealImage(
                                imagePath,
                              );
                            }
                            await _dietRepo.addEntry(
                              mealName: current.mealName,
                              loggedAt: DateTime.now(),
                              calories: current.calories,
                              proteinG: current.proteinG,
                              carbsG: current.carbsG,
                              fatG: current.fatG,
                              fiberG: current.fiberG,
                              sodiumMg: current.sodiumMg,
                              micros: current.micros,
                              notes: current.notes,
                              imagePath: persistedPath,
                            );
                            if (context.mounted) Navigator.of(context).pop();
                            await _load();
                          },
                          icon: const Icon(Icons.save),
                          label: const Text('Save meal'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _editMeal(DietEntry entry, {bool autoVoice = false}) async {
    final nameController = TextEditingController(text: entry.mealName);
    final caloriesController = TextEditingController(
      text: entry.calories?.toStringAsFixed(0) ?? '',
    );
    final proteinController = TextEditingController(
      text: entry.proteinG?.toStringAsFixed(1) ?? '',
    );
    final carbsController = TextEditingController(
      text: entry.carbsG?.toStringAsFixed(1) ?? '',
    );
    final fatController = TextEditingController(
      text: entry.fatG?.toStringAsFixed(1) ?? '',
    );
    final fiberController = TextEditingController(
      text: entry.fiberG?.toStringAsFixed(1) ?? '',
    );
    final sodiumController = TextEditingController(
      text: entry.sodiumMg?.toStringAsFixed(0) ?? '',
    );
    final notesController = TextEditingController(text: entry.notes ?? '');
    final refineController = TextEditingController();
    String? imagePath = entry.imagePath;
    var current = DietEstimate(
      mealName: entry.mealName,
      calories: entry.calories,
      proteinG: entry.proteinG,
      carbsG: entry.carbsG,
      fatG: entry.fatG,
      fiberG: entry.fiberG,
      sodiumMg: entry.sodiumMg,
      micros: entry.micros,
      notes: entry.notes,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: StatefulBuilder(
              builder: (context, setModalState) {
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  if (!autoVoice) return;
                  final transcript = await _stt.listenOnce();
                  if (transcript == null || transcript.trim().isEmpty) return;
                  refineController.text = transcript.trim();
                  if (!context.mounted) return;
                  await _applyRefinement(
                    transcript,
                    current,
                    (updated) => setModalState(() => current = updated),
                  );
                });
                return ListView(
                  shrinkWrap: true,
                  children: [
                    const Text('Edit meal'),
                    const SizedBox(height: 12),
                    if (imagePath != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(imagePath!),
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ] else ...[
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await _pickMealImage(
                                fromCamera: false,
                              );
                              if (picked == null || !context.mounted) return;
                              setModalState(() => imagePath = picked);
                            },
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Add photo'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () async {
                              final picked = await _pickMealImage(
                                fromCamera: true,
                              );
                              if (picked == null || !context.mounted) return;
                              setModalState(() => imagePath = picked);
                            },
                            icon: const Icon(Icons.photo_camera),
                            label: const Text('Camera'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Meal name'),
                    ),
                    const SizedBox(height: 8),
                    _numberField(caloriesController, 'Calories'),
                    const SizedBox(height: 8),
                    _numberField(proteinController, 'Protein (g)'),
                    const SizedBox(height: 8),
                    _numberField(carbsController, 'Carbs (g)'),
                    const SizedBox(height: 8),
                    _numberField(fatController, 'Fat (g)'),
                    const SizedBox(height: 8),
                    _numberField(fiberController, 'Fiber (g)'),
                    const SizedBox(height: 8),
                    _numberField(sodiumController, 'Sodium (mg)'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: notesController,
                      decoration: const InputDecoration(labelText: 'Notes'),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: refineController,
                      decoration: const InputDecoration(
                        labelText: 'Refine estimate (optional)',
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            final transcript = await _stt.listenOnce();
                            if (transcript == null ||
                                transcript.trim().isEmpty) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('No voice captured.'),
                                ),
                              );
                              return;
                            }
                            refineController.text = transcript;
                            if (!context.mounted) return;
                            await _applyRefinement(
                              transcript,
                              current,
                              (updated) =>
                                  setModalState(() => current = updated),
                            );
                          },
                          icon: const Icon(Icons.mic),
                          label: const Text('Refine by voice'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            final text = refineController.text.trim();
                            if (text.isEmpty) return;
                            await _applyRefinement(
                              text,
                              current,
                              (updated) =>
                                  setModalState(() => current = updated),
                            );
                          },
                          child: const Text('Apply refine text'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('Delete meal?'),
                                  content: const Text('This cannot be undone.'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          Navigator.of(context).pop(true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm != true) return;
                              await _deleteMeal(entry);
                              if (context.mounted) Navigator.of(context).pop();
                              await _load();
                            },
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Delete'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final canAttachImage =
                                  entry.imagePath == null && imagePath != null;
                              await _dietRepo.updateEntry(
                                id: entry.id,
                                mealName: nameController.text.trim().isEmpty
                                    ? entry.mealName
                                    : nameController.text.trim(),
                                calories: _parseAndClamp(
                                  caloriesController.text,
                                  max: 6000,
                                ),
                                proteinG: _parseAndClamp(
                                  proteinController.text,
                                  max: 500,
                                ),
                                carbsG: _parseAndClamp(
                                  carbsController.text,
                                  max: 800,
                                ),
                                fatG: _parseAndClamp(
                                  fatController.text,
                                  max: 300,
                                ),
                                fiberG: _parseAndClamp(
                                  fiberController.text,
                                  max: 200,
                                ),
                                sodiumMg: _parseAndClamp(
                                  sodiumController.text,
                                  max: 10000,
                                ),
                                micros: current.micros,
                                notes: notesController.text.trim().isEmpty
                                    ? null
                                    : notesController.text.trim(),
                                imagePath: canAttachImage ? imagePath : null,
                              );
                              if (context.mounted) Navigator.of(context).pop();
                              await _load();
                            },
                            icon: const Icon(Icons.save),
                            label: const Text('Save changes'),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _applyRefinement(
    String text,
    DietEstimate current,
    void Function(DietEstimate updated) update,
  ) async {
    final apiKey = await _settingsRepo.getCloudApiKey();
    final provider = await _settingsRepo.getCloudProvider();
    final model = await _settingsRepo.getCloudModel();
    if (apiKey == null || apiKey.trim().isEmpty) return;
    final updated = await _dietAnalysis.refineEstimate(
      current: current,
      userText: text,
      provider: provider,
      apiKey: apiKey,
      model: model,
    );
    if (updated != null) {
      update(updated);
    }
  }

  TextField _numberField(
    TextEditingController controller,
    String label, {
    double? max,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        helperText: max == null ? null : 'Max ${max.toStringAsFixed(0)}',
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      onChanged: onChanged,
    );
  }

  double? _parseDouble(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  DietEstimate _scaleEstimate(DietEstimate base, double multiplier) {
    Map<String, double>? scaleMicros(Map<String, double>? micros) {
      if (micros == null) return null;
      return micros.map((key, value) => MapEntry(key, value * multiplier));
    }

    return DietEstimate(
      mealName: base.mealName,
      calories: base.calories == null ? null : base.calories! * multiplier,
      proteinG: base.proteinG == null ? null : base.proteinG! * multiplier,
      carbsG: base.carbsG == null ? null : base.carbsG! * multiplier,
      fatG: base.fatG == null ? null : base.fatG! * multiplier,
      fiberG: base.fiberG == null ? null : base.fiberG! * multiplier,
      sodiumMg: base.sodiumMg == null ? null : base.sodiumMg! * multiplier,
      micros: scaleMicros(base.micros),
      notes: base.notes,
    );
  }

  double? _parseAndClamp(String value, {required double max}) {
    final parsed = _parseDouble(value);
    if (parsed == null) return null;
    return parsed > max ? max : parsed;
  }

  double _goalValue(TextEditingController controller) {
    return double.tryParse(controller.text.trim()) ?? 0;
  }

  String _format(double? value) {
    if (value == null) return '-';
    return value.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final goals = _buildGoals();
    final goalMultiplier = _timeScale == DietTimeScale.day
        ? 1
        : _timeScale == DietTimeScale.week
        ? 7
        : 30;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diet'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showMealPlanEditor,
          ),
        ],
      ),
      body: Stack(
        children: [
          const GlassBackground(),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Stats'),
                      const SizedBox(height: 12),
                      SegmentedButton<DietTimeScale>(
                        segments: const [
                          ButtonSegment(
                            value: DietTimeScale.day,
                            label: Text('Day'),
                          ),
                          ButtonSegment(
                            value: DietTimeScale.week,
                            label: Text('Week'),
                          ),
                          ButtonSegment(
                            value: DietTimeScale.month,
                            label: Text('Month'),
                          ),
                        ],
                        selected: {_timeScale},
                        onSelectionChanged: (value) async {
                          setState(() {
                            _timeScale = value.first;
                            _loading = true;
                          });
                          final summary = await _loadSummaryForScale();
                          final micros = await _loadMicrosForScale();
                          if (!mounted) return;
                          setState(() {
                            _summary = summary;
                            _microsSummary = micros;
                            _loading = false;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<DietNutrientView>(
                        segments: const [
                          ButtonSegment(
                            value: DietNutrientView.macros,
                            label: Text('Macros'),
                          ),
                          ButtonSegment(
                            value: DietNutrientView.micros,
                            label: Text('Micros'),
                          ),
                          ButtonSegment(
                            value: DietNutrientView.vitamins,
                            label: Text('Vitamins'),
                          ),
                        ],
                        selected: {_nutrientView},
                        onSelectionChanged: (value) {
                          setState(() {
                            _nutrientView = value.first;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      if (_nutrientView == DietNutrientView.macros) ...[
                        _summaryRow(
                          'Calories',
                          _summary.calories,
                          goals.calories * goalMultiplier,
                        ),
                        _summaryRow(
                          'Protein (g)',
                          _summary.proteinG,
                          goals.proteinG * goalMultiplier,
                        ),
                        _summaryRow(
                          'Carbs (g)',
                          _summary.carbsG,
                          goals.carbsG * goalMultiplier,
                        ),
                        _summaryRow(
                          'Fat (g)',
                          _summary.fatG,
                          goals.fatG * goalMultiplier,
                        ),
                        _summaryRow(
                          'Fiber (g)',
                          _summary.fiberG,
                          goals.fiberG * goalMultiplier,
                        ),
                        _summaryRow(
                          'Sodium (mg)',
                          _summary.sodiumMg,
                          goals.sodiumMg * goalMultiplier,
                        ),
                      ] else ...[
                        ..._buildMicroRows(
                          vitaminsOnly:
                              _nutrientView == DietNutrientView.vitamins,
                          goalMultiplier: goalMultiplier,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Meals'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _openFoodDatabase,
                              icon: const Icon(Icons.search),
                              label: const Text('Search food'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: _useCamera,
                              icon: const Icon(Icons.photo_camera),
                              label: const Text('Scan photo'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _scanBarcode,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('Quick barcode'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _pickMedia,
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Upload photo'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_allMeals.isEmpty)
                        const Text('No meals logged yet.')
                      else
                        ..._allMeals.map(
                          (meal) => GlassCard(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (meal.imagePath != null &&
                                    File(meal.imagePath!).existsSync())
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(
                                      File(meal.imagePath!),
                                      height: 200,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                if (meal.imagePath != null &&
                                    File(meal.imagePath!).existsSync())
                                  const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        meal.mealName,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.mic),
                                      onPressed: () =>
                                          _editMeal(meal, autoVoice: true),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      onPressed: () => _editMeal(meal),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Delete meal?'),
                                            content: const Text(
                                              'This cannot be undone.',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(
                                                  context,
                                                ).pop(false),
                                                child: const Text('Cancel'),
                                              ),
                                              ElevatedButton(
                                                onPressed: () => Navigator.of(
                                                  context,
                                                ).pop(true),
                                                child: const Text('Delete'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm != true) return;
                                        await _deleteMeal(meal);
                                        await _load();
                                      },
                                    ),
                                  ],
                                ),
                                Text(
                                  '${meal.loggedAt.month}/${meal.loggedAt.day} • ${meal.loggedAt.hour.toString().padLeft(2, '0')}:${meal.loggedAt.minute.toString().padLeft(2, '0')}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (meal.notes != null &&
                                    meal.notes!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    meal.notes!.trim(),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Text(
                                  _formatEntry(meal),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _formatEntry(DietEntry entry) {
    final parts = <String>[];
    if (entry.calories != null) {
      parts.add('${entry.calories!.toStringAsFixed(0)} kcal');
    }
    if (entry.proteinG != null) parts.add('P ${_format(entry.proteinG)}');
    if (entry.carbsG != null) parts.add('C ${_format(entry.carbsG)}');
    if (entry.fatG != null) parts.add('F ${_format(entry.fatG)}');
    final micros = entry.micros;
    if (micros != null && micros.isNotEmpty) {
      final shown = micros.entries
          .take(3)
          .map((e) => '${e.key} ${e.value.toStringAsFixed(0)}')
          .join(', ');
      parts.add('Micros: $shown');
    }
    return parts.join(' • ');
  }

  // ignore: unused_element
  Future<void> _showGoalEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('Daily goals (Tier B)'),
                const SizedBox(height: 12),
                _numberField(_goalCalories, 'Calories'),
                const SizedBox(height: 8),
                _numberField(_goalProtein, 'Protein (g)'),
                const SizedBox(height: 8),
                _numberField(_goalCarbs, 'Carbs (g)'),
                const SizedBox(height: 8),
                _numberField(_goalFat, 'Fat (g)'),
                const SizedBox(height: 8),
                _numberField(_goalFiber, 'Fiber (g)'),
                const SizedBox(height: 8),
                _numberField(_goalSodium, 'Sodium (mg)'),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await _saveGoals();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showMealPlanEditor() async {
    final calories = TextEditingController(text: _goalCalories.text);
    final protein = TextEditingController(text: _goalProtein.text);
    final carbs = TextEditingController(text: _goalCarbs.text);
    final fat = TextEditingController(text: _goalFat.text);
    final fiber = TextEditingController(text: _goalFiber.text);
    final sodium = TextEditingController(text: _goalSodium.text);
    final microControllers = {
      for (final key in _defaultMicros) key: TextEditingController(),
    };
    final vitaminControllers = {
      for (final key in _defaultVitamins) key: TextEditingController(),
    };

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 24,
          ),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('Meal plan goals'),
                const SizedBox(height: 12),
                _numberField(calories, 'Calories', max: 6000),
                const SizedBox(height: 8),
                _numberField(protein, 'Protein (g)', max: 500),
                const SizedBox(height: 8),
                _numberField(carbs, 'Carbs (g)', max: 800),
                const SizedBox(height: 8),
                _numberField(fat, 'Fat (g)', max: 300),
                const SizedBox(height: 8),
                _numberField(fiber, 'Fiber (g)', max: 200),
                const SizedBox(height: 8),
                _numberField(sodium, 'Sodium (mg)', max: 10000),
                const SizedBox(height: 12),
                const Text('Micros'),
                const SizedBox(height: 8),
                ..._defaultMicros.map((key) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _numberField(
                      microControllers[key]!,
                      key,
                      max: _defaultMicroGoals[key] ?? 99999,
                    ),
                  );
                }),
                const SizedBox(height: 12),
                const Text('Vitamins'),
                const SizedBox(height: 8),
                ..._defaultVitamins.map((key) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _numberField(
                      vitaminControllers[key]!,
                      key,
                      max: _defaultVitaminGoals[key] ?? 99999,
                    ),
                  );
                }),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final payload = {
                        'calories': _parseAndClamp(calories.text, max: 6000),
                        'protein_g': _parseAndClamp(protein.text, max: 500),
                        'carbs_g': _parseAndClamp(carbs.text, max: 800),
                        'fat_g': _parseAndClamp(fat.text, max: 300),
                        'fiber_g': _parseAndClamp(fiber.text, max: 200),
                        'sodium_mg': _parseAndClamp(sodium.text, max: 10000),
                        'micros': {
                          for (final key in _defaultMicros)
                            if (_parseAndClamp(
                                  microControllers[key]!.text,
                                  max: _defaultMicroGoals[key] ?? 99999,
                                ) !=
                                null)
                              key: _parseAndClamp(
                                microControllers[key]!.text,
                                max: _defaultMicroGoals[key] ?? 99999,
                              ),
                        },
                        'vitamins': {
                          for (final key in _defaultVitamins)
                            if (_parseAndClamp(
                                  vitaminControllers[key]!.text,
                                  max: _defaultVitaminGoals[key] ?? 99999,
                                ) !=
                                null)
                              key: _parseAndClamp(
                                vitaminControllers[key]!.text,
                                max: _defaultVitaminGoals[key] ?? 99999,
                              ),
                        },
                      };
                      await _settingsRepo.setValue(
                        'diet_meal_plan_json',
                        jsonEncode(payload),
                      );
                      if (!mounted) return;
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Meal plan saved.')),
                      );
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  Future<void> _uploadMealPlan() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Meal plan upload coming soon (${result.files.first.name}).',
        ),
      ),
    );
  }

  DietGoals _buildGoals() {
    return DietGoals(
      calories: _goalValue(_goalCalories),
      proteinG: _goalValue(_goalProtein),
      carbsG: _goalValue(_goalCarbs),
      fatG: _goalValue(_goalFat),
      fiberG: _goalValue(_goalFiber),
      sodiumMg: _goalValue(_goalSodium),
    );
  }

  Widget _summaryRow(String label, double? value, double goal) {
    final current = value ?? 0;
    final progress = goal == 0 ? 0.0 : (current / goal).clamp(0.0, 2.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ${_format(value)} / ${goal.toStringAsFixed(0)}'),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: progress > 1 ? 1 : progress),
        ],
      ),
    );
  }

  List<Widget> _buildMicroRows({
    required bool vitaminsOnly,
    required int goalMultiplier,
  }) {
    final entries = _filterMicros(vitaminsOnly: vitaminsOnly);
    final defaults = vitaminsOnly ? _defaultVitamins : _defaultMicros;
    final goals = vitaminsOnly ? _defaultVitaminGoals : _defaultMicroGoals;
    final used = <String, double>{};
    for (final entry in entries) {
      used[entry.key] = entry.value;
    }
    final rows = <MapEntry<String, double>>[];
    for (final key in defaults) {
      rows.add(MapEntry(key, used[key] ?? 0));
    }
    for (final entry in entries) {
      if (!defaults.contains(entry.key)) {
        rows.add(entry);
      }
    }
    return rows.map((entry) {
      final goal = goals[entry.key];
      if (goal == null) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('${entry.key}: ${entry.value.toStringAsFixed(1)}'),
        );
      }
      return _summaryRow(entry.key, entry.value, goal * goalMultiplier);
    }).toList();
  }

  List<MapEntry<String, double>> _filterMicros({required bool vitaminsOnly}) {
    final entries = _microsSummary.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (!vitaminsOnly) return entries;
    return entries
        .where(
          (e) =>
              e.key.toLowerCase().contains('vitamin') ||
              e.key.toLowerCase().startsWith('vit '),
        )
        .toList();
  }
}

class DietGoals {
  DietGoals({
    required this.calories,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.fiberG,
    required this.sodiumMg,
  });

  final double calories;
  final double proteinG;
  final double carbsG;
  final double fatG;
  final double fiberG;
  final double sodiumMg;
}

enum DietTimeScale { day, week, month }

enum DietNutrientView { macros, micros, vitamins }

const List<String> _defaultMicros = [
  'Potassium (mg)',
  'Sodium (mg)',
  'Calcium (mg)',
  'Iron (mg)',
  'Magnesium (mg)',
  'Zinc (mg)',
  'Phosphorus (mg)',
  'Selenium (mcg)',
  'Iodine (mcg)',
];

const List<String> _defaultVitamins = [
  'Vitamin A (mcg)',
  'Vitamin C (mg)',
  'Vitamin D (mcg)',
  'Vitamin E (mg)',
  'Vitamin K (mcg)',
  'Vitamin B1 (mg)',
  'Vitamin B2 (mg)',
  'Vitamin B3 (mg)',
  'Vitamin B5 (mg)',
  'Vitamin B6 (mg)',
  'Vitamin B7 (mcg)',
  'Vitamin B9 (mcg)',
  'Vitamin B12 (mcg)',
];

const Map<String, double> _defaultMicroGoals = {
  'Potassium (mg)': 3500,
  'Sodium (mg)': 2300,
  'Calcium (mg)': 1000,
  'Iron (mg)': 18,
  'Magnesium (mg)': 400,
  'Zinc (mg)': 11,
  'Phosphorus (mg)': 700,
  'Selenium (mcg)': 55,
  'Iodine (mcg)': 150,
};

const Map<String, double> _defaultVitaminGoals = {
  'Vitamin A (mcg)': 900,
  'Vitamin C (mg)': 90,
  'Vitamin D (mcg)': 20,
  'Vitamin E (mg)': 15,
  'Vitamin K (mcg)': 120,
  'Vitamin B1 (mg)': 1.2,
  'Vitamin B2 (mg)': 1.3,
  'Vitamin B3 (mg)': 16,
  'Vitamin B5 (mg)': 5,
  'Vitamin B6 (mg)': 1.3,
  'Vitamin B7 (mcg)': 30,
  'Vitamin B9 (mcg)': 400,
  'Vitamin B12 (mcg)': 2.4,
};

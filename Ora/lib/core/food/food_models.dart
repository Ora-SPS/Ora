import '../cloud/diet_analysis_service.dart';

enum FoodSourceType {
  custom,
  openFoodFacts,
  usda,
}

enum FoodKind {
  branded,
  generic,
}

enum FoodMatchType {
  custom,
  exactBarcode,
  exactName,
  brandedName,
  genericName,
}

class FoodNutrients {
  const FoodNutrients({
    this.calories,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sodiumMg,
    this.micros,
  });

  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final double? fiberG;
  final double? sodiumMg;
  final Map<String, double>? micros;

  FoodNutrients scale(double factor) {
    if (factor == 1) return this;
    return FoodNutrients(
      calories: _scale(calories, factor),
      proteinG: _scale(proteinG, factor),
      carbsG: _scale(carbsG, factor),
      fatG: _scale(fatG, factor),
      fiberG: _scale(fiberG, factor),
      sodiumMg: _scale(sodiumMg, factor),
      micros: micros == null
          ? null
          : {
              for (final entry in micros!.entries)
                entry.key: entry.value * factor,
            },
    );
  }

  int completenessScore() {
    var score = 0;
    if (calories != null) score += 3;
    if (proteinG != null) score += 2;
    if (carbsG != null) score += 2;
    if (fatG != null) score += 2;
    if (fiberG != null) score += 1;
    if (sodiumMg != null) score += 1;
    score += (micros?.length ?? 0).clamp(0, 12);
    return score;
  }

  DietEstimate toDietEstimate({
    required String mealName,
    String? notes,
  }) {
    return DietEstimate(
      mealName: mealName,
      calories: calories,
      proteinG: proteinG,
      carbsG: carbsG,
      fatG: fatG,
      fiberG: fiberG,
      sodiumMg: sodiumMg,
      micros: micros,
      notes: notes,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'calories': calories,
      'protein_g': proteinG,
      'carbs_g': carbsG,
      'fat_g': fatG,
      'fiber_g': fiberG,
      'sodium_mg': sodiumMg,
      'micros': micros,
    };
  }

  factory FoodNutrients.fromMap(Map<String, dynamic> map) {
    return FoodNutrients(
      calories: asDouble(map['calories']),
      proteinG: asDouble(map['protein_g']),
      carbsG: asDouble(map['carbs_g']),
      fatG: asDouble(map['fat_g']),
      fiberG: asDouble(map['fiber_g']),
      sodiumMg: asDouble(map['sodium_mg']),
      micros: asMicros(map['micros']),
    );
  }

  static double? _scale(double? value, double factor) {
    if (value == null) return null;
    return value * factor;
  }

  static double? asDouble(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static Map<String, double>? asMicros(Object? value) {
    if (value is Map<String, dynamic>) {
      final result = <String, double>{};
      for (final entry in value.entries) {
        final parsed = asDouble(entry.value);
        if (parsed != null) {
          result[entry.key] = parsed;
        }
      }
      return result.isEmpty ? null : result;
    }
    if (value is Map) {
      final result = <String, double>{};
      for (final entry in value.entries) {
        final parsed = asDouble(entry.value);
        if (parsed != null) {
          result[entry.key.toString()] = parsed;
        }
      }
      return result.isEmpty ? null : result;
    }
    return null;
  }
}

class FoodPortionOption {
  const FoodPortionOption({
    required this.id,
    required this.label,
    required this.amount,
    required this.unit,
    required this.grams,
    this.isDefault = false,
  });

  final String id;
  final String label;
  final double amount;
  final String unit;
  final double grams;
  final bool isDefault;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'amount': amount,
      'unit': unit,
      'grams': grams,
      'is_default': isDefault,
    };
  }

  factory FoodPortionOption.fromMap(Map<String, dynamic> map) {
    return FoodPortionOption(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? 'Serving',
      amount: FoodNutrients.asDouble(map['amount']) ?? 1,
      unit: map['unit']?.toString() ?? 'serving',
      grams: FoodNutrients.asDouble(map['grams']) ?? 0,
      isDefault: map['is_default'] == true || map['is_default'] == 1,
    );
  }
}

class FoodSourceEvidence {
  const FoodSourceEvidence({
    required this.source,
    required this.sourceId,
    required this.matchType,
    required this.nutrientsPer100g,
    required this.qualityScore,
    this.defaultServingLabel,
    this.defaultServingGrams,
    this.notes,
  });

  final FoodSourceType source;
  final String sourceId;
  final FoodMatchType matchType;
  final FoodNutrients nutrientsPer100g;
  final int qualityScore;
  final String? defaultServingLabel;
  final double? defaultServingGrams;
  final String? notes;

  Map<String, dynamic> toMap() {
    return {
      'source': source.name,
      'source_id': sourceId,
      'match_type': matchType.name,
      'nutrients_per_100g': nutrientsPer100g.toMap(),
      'quality_score': qualityScore,
      'default_serving_label': defaultServingLabel,
      'default_serving_grams': defaultServingGrams,
      'notes': notes,
    };
  }

  factory FoodSourceEvidence.fromMap(Map<String, dynamic> map) {
    return FoodSourceEvidence(
      source: _parseFoodSource(map['source']?.toString()),
      sourceId: map['source_id']?.toString() ?? '',
      matchType: _parseMatchType(map['match_type']?.toString()),
      nutrientsPer100g: FoodNutrients.fromMap(
        (map['nutrients_per_100g'] as Map?)?.cast<String, dynamic>() ??
            const {},
      ),
      qualityScore: (map['quality_score'] as num?)?.toInt() ?? 0,
      defaultServingLabel: map['default_serving_label']?.toString(),
      defaultServingGrams: FoodNutrients.asDouble(map['default_serving_grams']),
      notes: map['notes']?.toString(),
    );
  }
}

class FoodSearchItem {
  const FoodSearchItem({
    required this.source,
    required this.sourceId,
    required this.name,
    required this.kind,
    required this.nutrientsPer100g,
    required this.portionOptions,
    required this.defaultPortionId,
    required this.matchType,
    required this.qualityScore,
    this.brandName,
    this.packageSize,
    this.barcode,
    this.imageUrl,
    this.notes,
    this.alternates = const [],
    this.hasConflict = false,
    this.warning,
    this.isUserOverride = false,
  });

  final FoodSourceType source;
  final String sourceId;
  final String name;
  final String? brandName;
  final String? packageSize;
  final String? barcode;
  final FoodKind kind;
  final FoodNutrients nutrientsPer100g;
  final List<FoodPortionOption> portionOptions;
  final String defaultPortionId;
  final FoodMatchType matchType;
  final int qualityScore;
  final String? imageUrl;
  final String? notes;
  final List<FoodSourceEvidence> alternates;
  final bool hasConflict;
  final String? warning;
  final bool isUserOverride;

  String get displayName {
    if (brandName != null && brandName!.trim().isNotEmpty) {
      return '$name - ${brandName!.trim()}';
    }
    return name;
  }

  FoodPortionOption get defaultPortion {
    for (final option in portionOptions) {
      if (option.id == defaultPortionId) return option;
    }
    return portionOptions.isNotEmpty
        ? portionOptions.first
        : const FoodPortionOption(
            id: '100g',
            label: '100 g',
            amount: 100,
            unit: 'g',
            grams: 100,
            isDefault: true,
          );
  }

  Map<String, dynamic> toMap() {
    return {
      'source': source.name,
      'source_id': sourceId,
      'name': name,
      'brand_name': brandName,
      'package_size': packageSize,
      'barcode': barcode,
      'kind': kind.name,
      'nutrients_per_100g': nutrientsPer100g.toMap(),
      'portion_options':
          portionOptions.map((option) => option.toMap()).toList(),
      'default_portion_id': defaultPortionId,
      'match_type': matchType.name,
      'quality_score': qualityScore,
      'image_url': imageUrl,
      'notes': notes,
      'alternates': alternates.map((item) => item.toMap()).toList(),
      'has_conflict': hasConflict,
      'warning': warning,
      'is_user_override': isUserOverride,
    };
  }

  factory FoodSearchItem.fromMap(Map<String, dynamic> map) {
    final rawOptions = map['portion_options'] as List<dynamic>? ?? const [];
    final rawAlternates = map['alternates'] as List<dynamic>? ?? const [];
    return FoodSearchItem(
      source: _parseFoodSource(map['source']?.toString()),
      sourceId: map['source_id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Food',
      brandName: map['brand_name']?.toString(),
      packageSize: map['package_size']?.toString(),
      barcode: map['barcode']?.toString(),
      kind: _parseFoodKind(map['kind']?.toString()),
      nutrientsPer100g: FoodNutrients.fromMap(
        (map['nutrients_per_100g'] as Map?)?.cast<String, dynamic>() ??
            const {},
      ),
      portionOptions: rawOptions
          .whereType<Map>()
          .map(
              (item) => FoodPortionOption.fromMap(item.cast<String, dynamic>()))
          .toList(),
      defaultPortionId: map['default_portion_id']?.toString() ?? '100g',
      matchType: _parseMatchType(map['match_type']?.toString()),
      qualityScore: (map['quality_score'] as num?)?.toInt() ?? 0,
      imageUrl: map['image_url']?.toString(),
      notes: map['notes']?.toString(),
      alternates: rawAlternates
          .whereType<Map>()
          .map((item) =>
              FoodSourceEvidence.fromMap(item.cast<String, dynamic>()))
          .toList(),
      hasConflict: map['has_conflict'] == true || map['has_conflict'] == 1,
      warning: map['warning']?.toString(),
      isUserOverride:
          map['is_user_override'] == true || map['is_user_override'] == 1,
    );
  }

  FoodSearchItem copyWith({
    FoodSourceType? source,
    String? sourceId,
    String? name,
    String? brandName,
    String? packageSize,
    String? barcode,
    FoodKind? kind,
    FoodNutrients? nutrientsPer100g,
    List<FoodPortionOption>? portionOptions,
    String? defaultPortionId,
    FoodMatchType? matchType,
    int? qualityScore,
    String? imageUrl,
    String? notes,
    List<FoodSourceEvidence>? alternates,
    bool? hasConflict,
    String? warning,
    bool? isUserOverride,
  }) {
    return FoodSearchItem(
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      name: name ?? this.name,
      brandName: brandName ?? this.brandName,
      packageSize: packageSize ?? this.packageSize,
      barcode: barcode ?? this.barcode,
      kind: kind ?? this.kind,
      nutrientsPer100g: nutrientsPer100g ?? this.nutrientsPer100g,
      portionOptions: portionOptions ?? this.portionOptions,
      defaultPortionId: defaultPortionId ?? this.defaultPortionId,
      matchType: matchType ?? this.matchType,
      qualityScore: qualityScore ?? this.qualityScore,
      imageUrl: imageUrl ?? this.imageUrl,
      notes: notes ?? this.notes,
      alternates: alternates ?? this.alternates,
      hasConflict: hasConflict ?? this.hasConflict,
      warning: warning ?? this.warning,
      isUserOverride: isUserOverride ?? this.isUserOverride,
    );
  }
}

class FoodLookupResponse {
  const FoodLookupResponse({
    required this.items,
    this.infoMessage,
  });

  final List<FoodSearchItem> items;
  final String? infoMessage;
}

class FoodLogDraft {
  const FoodLogDraft({
    required this.mealName,
    required this.nutrients,
    required this.portionLabel,
    required this.portionGrams,
    required this.amount,
    required this.unit,
    this.notes,
    this.barcode,
    this.foodSource,
    this.foodSourceId,
    this.saveOverride = false,
    this.overrideItem,
  });

  final String mealName;
  final FoodNutrients nutrients;
  final String portionLabel;
  final double portionGrams;
  final double amount;
  final String unit;
  final String? notes;
  final String? barcode;
  final String? foodSource;
  final String? foodSourceId;
  final bool saveOverride;
  final FoodSearchItem? overrideItem;
}

FoodSourceType _parseFoodSource(String? value) {
  for (final candidate in FoodSourceType.values) {
    if (candidate.name == value) return candidate;
  }
  return FoodSourceType.openFoodFacts;
}

FoodKind _parseFoodKind(String? value) {
  for (final candidate in FoodKind.values) {
    if (candidate.name == value) return candidate;
  }
  return FoodKind.generic;
}

FoodMatchType _parseMatchType(String? value) {
  for (final candidate in FoodMatchType.values) {
    if (candidate.name == value) return candidate;
  }
  return FoodMatchType.genericName;
}

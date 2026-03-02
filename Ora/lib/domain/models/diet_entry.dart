enum DietMealType { breakfast, lunch, dinner, snack }

extension DietMealTypeX on DietMealType {
  String get storageValue {
    switch (this) {
      case DietMealType.breakfast:
        return 'breakfast';
      case DietMealType.lunch:
        return 'lunch';
      case DietMealType.dinner:
        return 'dinner';
      case DietMealType.snack:
        return 'snack';
    }
  }

  String get label {
    switch (this) {
      case DietMealType.breakfast:
        return 'Breakfast';
      case DietMealType.lunch:
        return 'Lunch';
      case DietMealType.dinner:
        return 'Dinner';
      case DietMealType.snack:
        return 'Snacks';
    }
  }

  static DietMealType fromStorage(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'breakfast':
        return DietMealType.breakfast;
      case 'lunch':
        return DietMealType.lunch;
      case 'dinner':
        return DietMealType.dinner;
      case 'snack':
      default:
        return DietMealType.snack;
    }
  }

  static DietMealType inferFromLoggedAt(DateTime loggedAt) {
    final hour = loggedAt.hour;
    if (hour >= 5 && hour < 11) {
      return DietMealType.breakfast;
    }
    if (hour >= 11 && hour < 16) {
      return DietMealType.lunch;
    }
    if (hour >= 16 && hour < 22) {
      return DietMealType.dinner;
    }
    return DietMealType.snack;
  }
}

class DietEntry {
  DietEntry({
    required this.id,
    required this.mealName,
    required this.loggedAt,
    required this.mealType,
    this.calories,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sodiumMg,
    this.micros,
    this.notes,
    this.imagePath,
    this.barcode,
    this.foodSource,
    this.foodSourceId,
    this.portionLabel,
    this.portionGrams,
    this.portionAmount,
    this.portionUnit,
  });

  final int id;
  final String mealName;
  final DateTime loggedAt;
  final DietMealType mealType;
  final double? calories;
  final double? proteinG;
  final double? carbsG;
  final double? fatG;
  final double? fiberG;
  final double? sodiumMg;
  final Map<String, double>? micros;
  final String? notes;
  final String? imagePath;
  final String? barcode;
  final String? foodSource;
  final String? foodSourceId;
  final String? portionLabel;
  final double? portionGrams;
  final double? portionAmount;
  final String? portionUnit;
}

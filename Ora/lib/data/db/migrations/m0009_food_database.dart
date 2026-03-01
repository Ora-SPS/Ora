import '../schema.dart';

List<String> migration0009() {
  return [
    'ALTER TABLE diet_entry ADD COLUMN barcode TEXT;',
    'ALTER TABLE diet_entry ADD COLUMN food_source TEXT;',
    'ALTER TABLE diet_entry ADD COLUMN food_source_id TEXT;',
    'ALTER TABLE diet_entry ADD COLUMN portion_label TEXT;',
    'ALTER TABLE diet_entry ADD COLUMN portion_grams REAL;',
    'ALTER TABLE diet_entry ADD COLUMN portion_amount REAL;',
    'ALTER TABLE diet_entry ADD COLUMN portion_unit TEXT;',
    createTableFoodLookupCache,
    createTableFoodCustomOverride,
    ...createFoodIndexes,
  ];
}

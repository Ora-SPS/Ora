const dbName = 'ora.db';
const dbVersion = 9;

const createTableExercise = '''
CREATE TABLE exercise(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  canonical_name TEXT UNIQUE NOT NULL,
  equipment_type TEXT NOT NULL,
  primary_muscle TEXT,
  secondary_muscles_json TEXT,
  is_builtin INTEGER NOT NULL,
  weight_mode_default TEXT NOT NULL,
  created_at TEXT NOT NULL
);
''';

const createTableExerciseAlias = '''
CREATE TABLE exercise_alias(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  exercise_id INTEGER NOT NULL,
  alias_normalized TEXT NOT NULL,
  source TEXT NOT NULL,
  UNIQUE(exercise_id, alias_normalized),
  FOREIGN KEY(exercise_id) REFERENCES exercise(id)
);
''';

const createTableProgram = '''
CREATE TABLE program(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  notes TEXT,
  created_at TEXT NOT NULL
);
''';

const createTableProgramDay = '''
CREATE TABLE program_day(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  program_id INTEGER NOT NULL,
  day_index INTEGER NOT NULL,
  day_name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(program_id) REFERENCES program(id)
);
''';

const createTableProgramDayExercise = '''
CREATE TABLE program_day_exercise(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  program_day_id INTEGER NOT NULL,
  exercise_id INTEGER NOT NULL,
  order_index INTEGER NOT NULL,
  notes TEXT,
  FOREIGN KEY(program_day_id) REFERENCES program_day(id),
  FOREIGN KEY(exercise_id) REFERENCES exercise(id)
);
''';

const createTableSetPlanBlock = '''
CREATE TABLE set_plan_block(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  program_day_exercise_id INTEGER NOT NULL,
  order_index INTEGER NOT NULL,
  role TEXT NOT NULL,
  set_count INTEGER NOT NULL,
  reps_min INTEGER,
  reps_max INTEGER,
  rest_sec_min INTEGER,
  rest_sec_max INTEGER,
  target_rpe_min REAL,
  target_rpe_max REAL,
  target_rir_min REAL,
  target_rir_max REAL,
  load_rule_type TEXT NOT NULL,
  load_rule_min REAL,
  load_rule_max REAL,
  amrap_last_set INTEGER NOT NULL,
  partials_target_min INTEGER,
  partials_target_max INTEGER,
  notes TEXT,
  FOREIGN KEY(program_day_exercise_id) REFERENCES program_day_exercise(id)
);
''';

const createTableWorkoutSession = '''
CREATE TABLE workout_session(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  program_id INTEGER,
  program_day_id INTEGER,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  notes TEXT,
  FOREIGN KEY(program_id) REFERENCES program(id),
  FOREIGN KEY(program_day_id) REFERENCES program_day(id)
);
''';

const createTableSessionExercise = '''
CREATE TABLE session_exercise(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workout_session_id INTEGER NOT NULL,
  exercise_id INTEGER NOT NULL,
  order_index INTEGER NOT NULL,
  FOREIGN KEY(workout_session_id) REFERENCES workout_session(id),
  FOREIGN KEY(exercise_id) REFERENCES exercise(id)
);
''';

const createTableSetEntry = '''
CREATE TABLE set_entry(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_exercise_id INTEGER NOT NULL,
  set_index INTEGER NOT NULL,
  set_role TEXT NOT NULL,
  weight_value REAL,
  weight_unit TEXT NOT NULL,
  weight_mode TEXT NOT NULL,
  reps INTEGER,
  partial_reps INTEGER NOT NULL DEFAULT 0,
  rpe REAL,
  rir REAL,
  flag_warmup INTEGER NOT NULL DEFAULT 0,
  flag_partials INTEGER NOT NULL DEFAULT 0,
  is_amrap INTEGER NOT NULL DEFAULT 0,
  rest_sec_actual INTEGER,
  created_at TEXT NOT NULL,
  FOREIGN KEY(session_exercise_id) REFERENCES session_exercise(id)
);
''';

const createTableUserProfile = '''
CREATE TABLE user_profile(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  display_name TEXT,
  age INTEGER,
  height_cm REAL,
  weight_kg REAL,
  notes TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''';

const createTableAppSettings = '''
CREATE TABLE app_setting(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

const createTableDietEntry = '''
CREATE TABLE diet_entry(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meal_name TEXT NOT NULL,
  logged_at TEXT NOT NULL,
  calories REAL,
  protein_g REAL,
  carbs_g REAL,
  fat_g REAL,
  fiber_g REAL,
  sodium_mg REAL,
  micros_json TEXT,
  notes TEXT,
  image_path TEXT,
  barcode TEXT,
  food_source TEXT,
  food_source_id TEXT,
  portion_label TEXT,
  portion_grams REAL,
  portion_amount REAL,
  portion_unit TEXT
);
''';

const createTableAppearanceEntry = '''
CREATE TABLE appearance_entry(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT NOT NULL,
  measurements TEXT,
  notes TEXT,
  image_path TEXT
);
''';

const createTableFoodLookupCache = '''
CREATE TABLE food_lookup_cache(
  cache_key TEXT PRIMARY KEY,
  cache_type TEXT NOT NULL,
  query_text TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''';

const createTableFoodCustomOverride = '''
CREATE TABLE food_custom_override(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lookup_key TEXT NOT NULL UNIQUE,
  normalized_name TEXT NOT NULL,
  brand_name_normalized TEXT,
  display_name TEXT NOT NULL,
  barcode TEXT,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
''';

const createIndexes = [
  'CREATE INDEX idx_exercise_alias_norm ON exercise_alias(alias_normalized);',
  'CREATE INDEX idx_set_entry_session_created ON set_entry(session_exercise_id, created_at);',
  'CREATE INDEX idx_session_exercise_exercise ON session_exercise(exercise_id);',
  'CREATE INDEX idx_workout_session_started ON workout_session(started_at);',
];

const createFoodIndexes = [
  'CREATE INDEX idx_diet_entry_barcode_logged_at ON diet_entry(barcode, logged_at);',
  'CREATE INDEX idx_food_lookup_cache_expires ON food_lookup_cache(expires_at);',
  'CREATE INDEX idx_food_custom_override_name ON food_custom_override(normalized_name);',
  'CREATE INDEX idx_food_custom_override_barcode ON food_custom_override(barcode);',
];

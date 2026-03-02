import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../data/db/db.dart';
import '../../data/repositories/food_cache_repo.dart';
import '../../data/repositories/food_override_repo.dart';
import 'food_models.dart';

class FoodDatabaseService {
  FoodDatabaseService({AppDatabase? db, http.Client? client})
      : _cacheRepo = FoodCacheRepo(db ?? AppDatabase.instance),
        _overrideRepo = FoodOverrideRepo(db ?? AppDatabase.instance),
        _client = client ?? http.Client();

  static const Duration _searchTtl = Duration(days: 7);
  static const Duration _barcodeTtl = Duration(days: 30);
  static const String _searchCacheVersion = 'v2';
  static const String _usdaApiKey = String.fromEnvironment(
    'USDA_API_KEY',
    defaultValue: 'DEMO_KEY',
  );
  static const String _openFoodFactsHost = 'world.openfoodfacts.org';

  final FoodCacheRepo _cacheRepo;
  final FoodOverrideRepo _overrideRepo;
  final http.Client _client;

  Future<FoodLookupResponse> searchFoods(String query) async {
    final normalized = _normalize(query);
    if (normalized.isEmpty) {
      return const FoodLookupResponse(items: <FoodSearchItem>[]);
    }
    unawaited(_cacheRepo.purgeExpired());
    final overrides = await _overrideRepo.search(query);
    final cacheKey = 'search:$_searchCacheVersion:$normalized';
    final cached = await _cacheRepo.getFresh(cacheKey);
    if (cached != null) {
      final cachedResponse = _responseFromMap(cached);
      return _withOverrides(cachedResponse, overrides);
    }

    final fetches = await Future.wait([
      _searchOpenFoodFacts(query),
      _searchUsda(query),
    ]);
    final mergedItems = _mergeCandidates([
      ...fetches[0].items,
      ...fetches[1].items,
    ], query: normalized);
    final items = _filterSearchResults(
      mergedItems,
      query: normalized,
      openFoodFacts: fetches[0],
      usda: fetches[1],
    );
    final infoMessage = _searchInfoMessage(
      fetches,
      query: normalized,
      items: items,
    );
    final degraded = fetches.any((fetch) => fetch.rateLimited || fetch.failed);
    if (items.isNotEmpty) {
      final response = FoodLookupResponse(
        items: items,
        infoMessage: infoMessage,
      );
      if (!degraded) {
        await _cacheRepo.put(
          cacheKey: cacheKey,
          cacheType: 'search',
          queryText: normalized,
          payload: _responseToMap(response),
          ttl: _searchTtl,
        );
      }
      return _withOverrides(response, overrides);
    }

    final stale = await _cacheRepo.getAny(cacheKey);
    if (stale != null) {
      final response = _responseFromMap(stale);
      return _withOverrides(response, overrides);
    }
    if (overrides.isNotEmpty) {
      return FoodLookupResponse(
        items: overrides,
        infoMessage: 'Showing your saved custom foods.',
      );
    }
    return FoodLookupResponse(
      items: const [],
      infoMessage: infoMessage ?? 'No foods found for "$query".',
    );
  }

  Future<FoodLookupResponse> lookupBarcode(String barcode) async {
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) {
      return const FoodLookupResponse(items: <FoodSearchItem>[]);
    }
    final override = await _overrideRepo.findByBarcode(trimmed);
    if (override != null) {
      return FoodLookupResponse(
        items: [override],
        infoMessage: 'Using your saved custom override for this barcode.',
      );
    }

    final cacheKey = 'barcode:$trimmed';
    final cached = await _cacheRepo.getFresh(cacheKey);
    if (cached != null) {
      return _responseFromMap(cached);
    }

    final fetches = await Future.wait([
      _lookupOpenFoodFactsBarcode(trimmed),
      _lookupUsdaBarcode(trimmed),
    ]);
    var items = _mergeCandidates([...fetches[0].items, ...fetches[1].items]);
    var infoMessage = _mergeInfoMessage(fetches);

    if (items.isNotEmpty && _isWeakResult(items.first)) {
      final fallbackName = items.first.name;
      final generic = await _searchUsda(
        fallbackName,
        brandedOnly: false,
        genericOnly: true,
        limit: 4,
        forceNetwork: true,
      );
      if (generic.items.isNotEmpty) {
        final genericItems = generic.items
            .map(
              (item) => item.copyWith(
                warning:
                    'Exact barcode data was weak. Showing generic reference data.',
              ),
            )
            .toList();
        items = [...items, ..._dedupeByLookup(genericItems, existing: items)];
        infoMessage ??=
            'Exact barcode data was weak. Generic foods are shown too.';
      }
    }

    if (items.isNotEmpty) {
      final response = FoodLookupResponse(
        items: items,
        infoMessage: infoMessage,
      );
      await _cacheRepo.put(
        cacheKey: cacheKey,
        cacheType: 'barcode',
        queryText: trimmed,
        payload: _responseToMap(response),
        ttl: _barcodeTtl,
      );
      return response;
    }

    final stale = await _cacheRepo.getAny(cacheKey);
    if (stale != null) {
      return _responseFromMap(stale);
    }
    return const FoodLookupResponse(
      items: [],
      infoMessage:
          'Barcode not found in the supported food databases. Try text search.',
    );
  }

  Future<void> saveOverride(FoodSearchItem item) {
    return _overrideRepo.upsert(
      item.copyWith(
        source: FoodSourceType.custom,
        matchType: FoodMatchType.custom,
        isUserOverride: true,
        qualityScore: 10000,
        warning: null,
        hasConflict: false,
        alternates: const [],
        notes: 'Custom food override',
      ),
    );
  }

  FoodSearchItem buildOverrideItem({
    required FoodSearchItem base,
    required String mealName,
    required FoodNutrients nutrients,
    required double totalGrams,
    required FoodPortionOption selectedPortion,
  }) {
    final normalizedPer100g = totalGrams > 0
        ? nutrients.scale(100 / totalGrams)
        : base.nutrientsPer100g;
    final portions = _dedupePortions([selectedPortion, ...base.portionOptions]);
    return FoodSearchItem(
      source: FoodSourceType.custom,
      sourceId: base.barcode?.isNotEmpty == true
          ? 'barcode:${base.barcode}'
          : 'custom:${_normalize(mealName)}',
      name: mealName,
      brandName: base.brandName,
      packageSize: base.packageSize,
      barcode: base.barcode,
      kind: base.kind,
      nutrientsPer100g: normalizedPer100g,
      portionOptions: portions,
      defaultPortionId: selectedPortion.id,
      matchType: FoodMatchType.custom,
      qualityScore: 10000,
      imageUrl: base.imageUrl,
      notes: 'Custom food override',
      isUserOverride: true,
    );
  }

  Future<_FetchOutcome> _searchOpenFoodFacts(
    String query, {
    int limit = 10,
  }) async {
    final rawLimit = limit < 50 ? 50 : limit;
    final uri = Uri.https(_openFoodFactsHost, '/cgi/search.pl', {
      'search_terms': query,
      'search_simple': '1',
      'action': 'process',
      'json': '1',
      'page_size': '$rawLimit',
      'fields':
          'code,product_name,product_name_en,lang,brands,serving_size,quantity,product_quantity,product_quantity_unit,nutriments,image_url,image_front_url',
    });
    return _runFetch(() async {
      final response = await _client.get(uri, headers: const {
        'User-Agent': 'Ora/0.1 (support@ora.app)'
      }).timeout(const Duration(seconds: 12));
      if (response.statusCode == 429) {
        return const _FetchOutcome(items: [], rateLimited: true);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const _FetchOutcome(items: [], failed: true);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final products = body['products'] as List<dynamic>? ?? const [];
      final items = <FoodSearchItem>[];
      for (final rawItem in products.whereType<Map>()) {
        final normalized = _tryNormalizeOpenFoodFactsProduct(
          rawItem.cast<String, dynamic>(),
          query: query,
          matchType: FoodMatchType.brandedName,
        );
        if (normalized != null) {
          items.add(normalized);
        }
      }
      return _FetchOutcome(items: items);
    });
  }

  Future<_FetchOutcome> _lookupOpenFoodFactsBarcode(String barcode) async {
    final uri = Uri.https(_openFoodFactsHost, '/api/v2/product/$barcode', {
      'fields':
          'code,product_name,product_name_en,lang,brands,serving_size,quantity,product_quantity,product_quantity_unit,nutriments,image_url,image_front_url',
    });
    return _runFetch(() async {
      final response = await _client.get(uri, headers: const {
        'User-Agent': 'Ora/0.1 (support@ora.app)'
      }).timeout(const Duration(seconds: 12));
      if (response.statusCode == 429) {
        return const _FetchOutcome(items: [], rateLimited: true);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const _FetchOutcome(items: [], failed: true);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['status'] != 1) {
        return const _FetchOutcome(items: []);
      }
      final product = body['product'] as Map<String, dynamic>? ?? const {};
      final item = _normalizeOpenFoodFactsProduct(
        product,
        query: barcode,
        matchType: FoodMatchType.exactBarcode,
      );
      return _FetchOutcome(items: item == null ? const [] : [item]);
    });
  }

  Future<_FetchOutcome> _searchUsda(
    String query, {
    bool brandedOnly = false,
    bool genericOnly = false,
    int limit = 12,
    bool forceNetwork = false,
  }) async {
    final dataTypes = brandedOnly
        ? const ['Branded']
        : genericOnly
            ? const ['Foundation', 'SR Legacy', 'Survey (FNDDS)']
            : const ['Branded', 'Foundation', 'SR Legacy', 'Survey (FNDDS)'];
    final uri = Uri.https('api.nal.usda.gov', '/fdc/v1/foods/search', {
      'api_key': _usdaApiKey,
    });
    return _runFetch(() async {
      final payload = {
        'query': query,
        'pageSize': limit,
        'requireAllWords': false,
        'dataType': dataTypes,
      };
      final response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 429) {
        return const _FetchOutcome(items: [], rateLimited: true);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const _FetchOutcome(items: [], failed: true);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final foods = body['foods'] as List<dynamic>? ?? const [];
      final items = <FoodSearchItem>[];
      for (final rawItem in foods.whereType<Map>()) {
        final normalized = _tryNormalizeUsdaFood(
          rawItem.cast<String, dynamic>(),
          query: query,
          matchType: brandedOnly || genericOnly
              ? (genericOnly
                  ? FoodMatchType.genericName
                  : FoodMatchType.brandedName)
              : null,
        );
        if (normalized != null) {
          items.add(normalized);
        }
      }
      if (!forceNetwork && items.isEmpty) {
        return const _FetchOutcome(items: []);
      }
      return _FetchOutcome(items: items);
    });
  }

  Future<_FetchOutcome> _lookupUsdaBarcode(String barcode) async {
    final uri = Uri.https('api.nal.usda.gov', '/fdc/v1/foods/search', {
      'api_key': _usdaApiKey,
    });
    return _runFetch(() async {
      final payload = {
        'query': barcode,
        'pageSize': 4,
        'dataType': const ['Branded'],
      };
      final response = await _client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode == 429) {
        return const _FetchOutcome(items: [], rateLimited: true);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const _FetchOutcome(items: [], failed: true);
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final foods = body['foods'] as List<dynamic>? ?? const [];
      final items = foods
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .where((item) => item['gtinUpc']?.toString().trim() == barcode)
          .map((item) => _tryNormalizeUsdaFood(
                item,
                query: barcode,
                matchType: FoodMatchType.exactBarcode,
              ))
          .whereType<FoodSearchItem>()
          .toList();
      return _FetchOutcome(items: items);
    });
  }

  Future<_FetchOutcome> _runFetch(
    Future<_FetchOutcome> Function() operation,
  ) async {
    try {
      return await operation();
    } on TimeoutException {
      return const _FetchOutcome(items: [], failed: true);
    } catch (_) {
      return const _FetchOutcome(items: [], failed: true);
    }
  }

  FoodSearchItem? _normalizeOpenFoodFactsProduct(
    Map<String, dynamic> product, {
    required String query,
    required FoodMatchType matchType,
  }) {
    final rawName = product['product_name']?.toString().trim();
    final englishName = product['product_name_en']?.toString().trim();
    final sourceLang = product['lang']?.toString().trim().toLowerCase();
    final name =
        englishName != null && englishName.isNotEmpty ? englishName : rawName;
    final barcode = product['code']?.toString().trim();
    if (matchType != FoodMatchType.exactBarcode &&
        (name == null || name.isEmpty) &&
        sourceLang != 'en') {
      return null;
    }
    if ((name == null || name.isEmpty) &&
        (barcode == null || barcode.isEmpty)) {
      return null;
    }
    final brandsRaw = product['brands']?.toString().trim();
    final brandName = brandsRaw == null || brandsRaw.isEmpty
        ? null
        : brandsRaw.split(',').first.trim();
    final nutriments =
        product['nutriments'] as Map<String, dynamic>? ?? const {};
    final servingLabel = product['serving_size']?.toString().trim();
    final servingGrams = _parseGrams(
      servingLabel,
      fallbackValue: FoodNutrients.asDouble(product['serving_quantity']),
      fallbackUnit: product['serving_quantity_unit']?.toString(),
    );
    final quantity = product['quantity']?.toString().trim();
    final packageGrams = _parseGrams(
      quantity,
      fallbackValue: FoodNutrients.asDouble(product['product_quantity']),
      fallbackUnit: product['product_quantity_unit']?.toString(),
    );
    final per100g = _readOpenFoodFactsPer100g(nutriments, servingGrams);
    final portions = _buildOpenFoodFactsPortions(
      servingLabel: servingLabel,
      servingGrams: servingGrams,
      packageLabel: quantity,
      packageGrams: packageGrams,
    );
    final sourceId =
        barcode?.isNotEmpty == true ? barcode! : _normalize(name ?? query);
    final displayName = name?.isNotEmpty == true ? name! : 'Barcode $sourceId';
    final portionLabel = portions.firstWhere(
      (option) => option.isDefault,
      orElse: () => portions.first,
    );
    final qualityScore = per100g.completenessScore() +
        (portionLabel.grams > 0 ? 4 : 0) +
        (quantity?.isNotEmpty == true ? 2 : 0);
    return FoodSearchItem(
      source: FoodSourceType.openFoodFacts,
      sourceId: sourceId,
      name: displayName,
      brandName: brandName,
      packageSize: quantity,
      barcode: barcode,
      kind: brandName == null ? FoodKind.generic : FoodKind.branded,
      nutrientsPer100g: per100g,
      portionOptions: portions,
      defaultPortionId: portionLabel.id,
      matchType: matchType == FoodMatchType.exactBarcode
          ? FoodMatchType.exactBarcode
          : _inferSearchMatchType(
              name: displayName,
              brandName: brandName,
              query: query,
              fallback: brandName == null
                  ? FoodMatchType.genericName
                  : FoodMatchType.brandedName,
            ),
      qualityScore: qualityScore,
      imageUrl: product['image_front_url']?.toString() ??
          product['image_url']?.toString(),
      notes: 'Open Food Facts',
    );
  }

  FoodSearchItem? _tryNormalizeOpenFoodFactsProduct(
    Map<String, dynamic> product, {
    required String query,
    required FoodMatchType matchType,
  }) {
    try {
      return _normalizeOpenFoodFactsProduct(
        product,
        query: query,
        matchType: matchType,
      );
    } catch (_) {
      return null;
    }
  }

  FoodSearchItem? _normalizeUsdaFood(
    Map<String, dynamic> food, {
    required String query,
    FoodMatchType? matchType,
  }) {
    final name = food['description']?.toString().trim();
    if (name == null || name.isEmpty) return null;
    final dataType = food['dataType']?.toString() ?? '';
    final isBranded = dataType.toLowerCase() == 'branded';
    final brandName = _firstNonEmpty([
      food['brandName']?.toString(),
      food['brandOwner']?.toString(),
    ]);
    final sourceId = food['fdcId']?.toString() ?? _normalize(name);
    final barcode = food['gtinUpc']?.toString().trim();
    final servingSize = FoodNutrients.asDouble(food['servingSize']);
    final servingUnit = food['servingSizeUnit']?.toString();
    final servingGrams = _gramsFromUnit(servingSize, servingUnit);
    final packageSize = food['packageWeight']?.toString();
    final per100g = _readUsdaPer100g(
      food,
      isBranded: isBranded,
      servingGrams: servingGrams,
    );
    final portions = _buildUsdaPortions(food, servingGrams: servingGrams);
    final inferredMatchType = matchType ??
        (barcode != null && barcode == query
            ? FoodMatchType.exactBarcode
            : _inferSearchMatchType(
                name: name,
                brandName: brandName,
                query: query,
                fallback: isBranded
                    ? FoodMatchType.brandedName
                    : FoodMatchType.genericName,
              ));
    final qualityScore = per100g.completenessScore() +
        (servingGrams != null && servingGrams > 0 ? 4 : 0) +
        ((packageSize?.isNotEmpty ?? false) ? 2 : 0) +
        (isBranded ? 1 : 0);
    return FoodSearchItem(
      source: FoodSourceType.usda,
      sourceId: sourceId,
      name: _titleCase(name),
      brandName: brandName,
      packageSize: packageSize,
      barcode: barcode,
      kind: isBranded ? FoodKind.branded : FoodKind.generic,
      nutrientsPer100g: per100g,
      portionOptions: portions,
      defaultPortionId: portions
          .firstWhere(
            (option) => option.isDefault,
            orElse: () => portions.first,
          )
          .id,
      matchType: inferredMatchType,
      qualityScore: qualityScore,
      notes: 'USDA FoodData Central',
    );
  }

  FoodSearchItem? _tryNormalizeUsdaFood(
    Map<String, dynamic> food, {
    required String query,
    FoodMatchType? matchType,
  }) {
    try {
      return _normalizeUsdaFood(food, query: query, matchType: matchType);
    } catch (_) {
      return null;
    }
  }

  FoodNutrients _readOpenFoodFactsPer100g(
    Map<String, dynamic> nutriments,
    double? servingGrams,
  ) {
    double? readMacro(String base) {
      final direct = _readOffValue(nutriments, '${base}_100g');
      if (direct != null) return direct;
      final serving = _readOffValue(nutriments, '${base}_serving');
      if (serving == null || servingGrams == null || servingGrams <= 0) {
        return null;
      }
      return serving * (100 / servingGrams);
    }

    final calories = _readOffCaloriesPer100g(nutriments, servingGrams);
    final micros = <String, double>{};
    for (final spec in _offMicroSpecs) {
      final value = _readOffNutrientPer100g(
        nutriments,
        base: spec.offKey,
        targetUnit: spec.targetUnit,
        servingGrams: servingGrams,
      );
      if (value != null) {
        micros[spec.storageKey] = value;
      }
    }
    return FoodNutrients(
      calories: calories,
      proteinG: readMacro('proteins'),
      carbsG: readMacro('carbohydrates'),
      fatG: readMacro('fat'),
      fiberG: readMacro('fiber'),
      sodiumMg: _readOffNutrientPer100g(
        nutriments,
        base: 'sodium',
        targetUnit: _TargetUnit.mg,
        servingGrams: servingGrams,
      ),
      micros: micros.isEmpty ? null : micros,
    );
  }

  FoodNutrients _readUsdaPer100g(
    Map<String, dynamic> food, {
    required bool isBranded,
    required double? servingGrams,
  }) {
    final nutrients = (food['foodNutrients'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();

    double? readMacro(String number) {
      final value = _findUsdaNutrient(nutrients, number);
      if (value == null) return null;
      if (!isBranded) return value;
      if (servingGrams == null || servingGrams <= 0) return null;
      return value * (100 / servingGrams);
    }

    final micros = <String, double>{};
    for (final spec in _usdaMicroSpecs) {
      final value = _findUsdaNutrient(nutrients, spec.number);
      if (value == null) continue;
      final unit = _findUsdaUnit(nutrients, spec.number);
      final converted = _convertValue(value, unit, spec.targetUnit);
      if (converted == null) continue;
      micros[spec.storageKey] =
          isBranded && servingGrams != null && servingGrams > 0
              ? converted * (100 / servingGrams)
              : converted;
    }

    final sodium = _findUsdaNutrient(nutrients, '307');
    final sodiumUnit = _findUsdaUnit(nutrients, '307');
    final sodiumConverted = sodium == null
        ? null
        : _convertValue(sodium, sodiumUnit, _TargetUnit.mg);
    return FoodNutrients(
      calories: readMacro('208'),
      proteinG: readMacro('203'),
      carbsG: readMacro('205'),
      fatG: readMacro('204'),
      fiberG: readMacro('291'),
      sodiumMg: sodiumConverted == null
          ? null
          : (isBranded && servingGrams != null && servingGrams > 0
              ? sodiumConverted * (100 / servingGrams)
              : sodiumConverted),
      micros: micros.isEmpty ? null : micros,
    );
  }

  List<FoodPortionOption> _buildOpenFoodFactsPortions({
    required String? servingLabel,
    required double? servingGrams,
    required String? packageLabel,
    required double? packageGrams,
  }) {
    final portions = <FoodPortionOption>[
      const FoodPortionOption(
        id: '100g',
        label: '100 g',
        amount: 100,
        unit: 'g',
        grams: 100,
      ),
      const FoodPortionOption(
        id: '1oz',
        label: '1 oz',
        amount: 1,
        unit: 'oz',
        grams: 28.3495,
      ),
    ];
    if (servingGrams != null && servingGrams > 0) {
      portions.insert(
        0,
        FoodPortionOption(
          id: 'serving',
          label: servingLabel?.isNotEmpty == true
              ? '1 serving ($servingLabel)'
              : '1 serving',
          amount: 1,
          unit: 'serving',
          grams: servingGrams,
          isDefault: true,
        ),
      );
    }
    if (packageGrams != null && packageGrams > 0) {
      portions.add(
        FoodPortionOption(
          id: 'package',
          label: packageLabel?.isNotEmpty == true
              ? '1 package ($packageLabel)'
              : '1 package',
          amount: 1,
          unit: 'package',
          grams: packageGrams,
        ),
      );
    }
    return _dedupePortions(portions);
  }

  List<FoodPortionOption> _buildUsdaPortions(
    Map<String, dynamic> food, {
    required double? servingGrams,
  }) {
    final portions = <FoodPortionOption>[
      const FoodPortionOption(
        id: '100g',
        label: '100 g',
        amount: 100,
        unit: 'g',
        grams: 100,
      ),
      const FoodPortionOption(
        id: '1oz',
        label: '1 oz',
        amount: 1,
        unit: 'oz',
        grams: 28.3495,
      ),
    ];
    final household = food['householdServingFullText']?.toString().trim();
    if (servingGrams != null && servingGrams > 0) {
      portions.insert(
        0,
        FoodPortionOption(
          id: 'serving',
          label: household?.isNotEmpty == true
              ? '$household (${servingGrams.toStringAsFixed(servingGrams >= 10 ? 0 : 1)} g)'
              : '1 serving (${servingGrams.toStringAsFixed(servingGrams >= 10 ? 0 : 1)} g)',
          amount: 1,
          unit: 'serving',
          grams: servingGrams,
          isDefault: true,
        ),
      );
    }
    final foodMeasures = (food['foodMeasures'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => item.cast<String, dynamic>());
    for (final measure in foodMeasures.take(6)) {
      final grams = FoodNutrients.asDouble(measure['gramWeight']);
      final label = measure['disseminationText']?.toString().trim();
      if (grams == null || grams <= 0 || label == null || label.isEmpty) {
        continue;
      }
      portions.add(
        FoodPortionOption(
          id: 'measure_${_normalize(label)}',
          label: label,
          amount: 1,
          unit: 'measure',
          grams: grams,
        ),
      );
    }
    return _dedupePortions(portions);
  }

  List<FoodSearchItem> _mergeCandidates(
    List<FoodSearchItem> candidates, {
    String? query,
  }) {
    final buckets = <String, List<FoodSearchItem>>{};
    for (final item in candidates) {
      final key = _lookupKey(item);
      buckets.putIfAbsent(key, () => []).add(item);
    }
    final merged = buckets.values
        .map((bucket) => _mergeBucket(bucket, query: query))
        .toList();
    merged.sort(
      (a, b) =>
          _rankItem(b, query: query).compareTo(_rankItem(a, query: query)),
    );
    return merged;
  }

  FoodSearchItem _mergeBucket(List<FoodSearchItem> bucket, {String? query}) {
    final ranked = [...bucket]..sort(
        (a, b) =>
            _rankItem(b, query: query).compareTo(_rankItem(a, query: query)),
      );
    final winner = ranked.first;
    final alternates = ranked
        .skip(1)
        .map(
          (item) => FoodSourceEvidence(
            source: item.source,
            sourceId: item.sourceId,
            matchType: item.matchType,
            nutrientsPer100g: item.nutrientsPer100g,
            qualityScore: item.qualityScore,
            defaultServingLabel: item.defaultPortion.label,
            defaultServingGrams: item.defaultPortion.grams,
            notes: item.notes,
          ),
        )
        .toList();
    final hasConflict = ranked.skip(1).any(
          (item) =>
              _hasConflict(winner.nutrientsPer100g, item.nutrientsPer100g),
        );
    return winner.copyWith(
      alternates: alternates,
      hasConflict: hasConflict,
      warning:
          hasConflict ? 'Nutrition varies across sources.' : winner.warning,
    );
  }

  FoodLookupResponse _withOverrides(
    FoodLookupResponse response,
    List<FoodSearchItem> overrides,
  ) {
    if (overrides.isEmpty) return response;
    final items = <FoodSearchItem>[
      ...overrides,
      ..._dedupeByLookup(response.items, existing: overrides),
    ];
    return FoodLookupResponse(items: items, infoMessage: response.infoMessage);
  }

  List<FoodSearchItem> _dedupeByLookup(
    List<FoodSearchItem> incoming, {
    required List<FoodSearchItem> existing,
  }) {
    final keys = existing.map(_lookupKey).toSet();
    final result = <FoodSearchItem>[];
    for (final item in incoming) {
      if (keys.add(_lookupKey(item))) {
        result.add(item);
      }
    }
    return result;
  }

  List<FoodPortionOption> _dedupePortions(List<FoodPortionOption> options) {
    final seen = <String>{};
    final result = <FoodPortionOption>[];
    for (final option in options) {
      final key = '${option.label}|${option.grams.toStringAsFixed(3)}';
      if (seen.add(key)) {
        result.add(option);
      }
    }
    return result;
  }

  bool _isWeakResult(FoodSearchItem item) {
    return item.nutrientsPer100g.completenessScore() < 6 ||
        item.defaultPortion.grams <= 0;
  }

  int _rankItem(FoodSearchItem item, {String? query}) {
    final queryScore = _queryRelevanceScore(item, query);
    final breadthPenalty = _breadthPenalty(item, query);
    final matchScore = switch (item.matchType) {
      FoodMatchType.custom => 500,
      FoodMatchType.exactBarcode => 400,
      FoodMatchType.exactName => 300,
      FoodMatchType.brandedName => 200,
      FoodMatchType.genericName => 100,
    };
    final sourceScore = switch (item.source) {
      FoodSourceType.custom => 100,
      FoodSourceType.usda => item.kind == FoodKind.generic ? 35 : 25,
      FoodSourceType.openFoodFacts =>
        item.barcode?.isNotEmpty == true ? 30 : 20,
    };
    final portionScore = item.defaultPortion.grams > 0 ? 8 : 0;
    final packageScore = item.packageSize?.isNotEmpty == true ? 4 : 0;
    return queryScore +
        matchScore +
        sourceScore +
        item.qualityScore +
        portionScore +
        packageScore -
        breadthPenalty;
  }

  int _queryRelevanceScore(FoodSearchItem item, String? query) {
    final normalizedQuery = _normalize(query ?? '');
    if (normalizedQuery.isEmpty) {
      return 0;
    }

    final normalizedName = _normalize(item.name);
    final normalizedDisplay = _normalize(item.displayName);
    final normalizedBrand = _normalize(item.brandName ?? '');
    final queryRoot = _singularizeWord(normalizedQuery);
    final nameWords =
        normalizedName.split(' ').where((part) => part.isNotEmpty).toList();
    final displayWords =
        normalizedDisplay.split(' ').where((part) => part.isNotEmpty).toList();
    final queryWords =
        normalizedQuery.split(' ').where((part) => part.isNotEmpty).toList();
    final firstWord = nameWords.isEmpty ? '' : nameWords.first;
    final firstWordRoot = _singularizeWord(firstWord);

    if (normalizedName == normalizedQuery ||
        normalizedDisplay == normalizedQuery) {
      return 3000;
    }
    if (_singularizePhrase(normalizedName) ==
            _singularizePhrase(normalizedQuery) ||
        _singularizePhrase(normalizedDisplay) ==
            _singularizePhrase(normalizedQuery)) {
      return 2900;
    }
    if (item.matchType == FoodMatchType.exactName) {
      return 2800;
    }

    final startsWithQuery = normalizedName.startsWith('$normalizedQuery ') ||
        normalizedDisplay.startsWith('$normalizedQuery ');
    if (startsWithQuery) {
      final rankingWords = nameWords.isEmpty ? displayWords : nameWords;
      final queryTail = rankingWords.skip(queryWords.length);
      final extraWords = rankingWords.length - queryWords.length;
      return 2525 -
          (extraWords * 20) -
          _queryTailPenalty(queryTail, queryWordCount: queryWords.length);
    }

    if (firstWordRoot == queryRoot) {
      final rankingWords = nameWords.isEmpty ? displayWords : nameWords;
      final queryTail = rankingWords.skip(1);
      final extraWords = rankingWords.length - 1;
      return 2200 -
          (extraWords * 35) -
          _queryTailPenalty(queryTail, queryWordCount: 1);
    }

    if (_containsWholeWord(normalizedName, normalizedQuery) ||
        _containsWholeWord(normalizedDisplay, normalizedQuery)) {
      return 1800;
    }
    if (_containsWholeWord(normalizedBrand, normalizedQuery)) {
      return 900;
    }
    if (normalizedName.contains(normalizedQuery) ||
        normalizedDisplay.contains(normalizedQuery)) {
      return 700;
    }
    if (normalizedBrand.contains(normalizedQuery)) {
      return 350;
    }
    return 0;
  }

  FoodMatchType _inferSearchMatchType({
    required String name,
    required String? brandName,
    required String query,
    required FoodMatchType fallback,
  }) {
    final normalizedQuery = _normalize(query);
    if (normalizedQuery.isEmpty) {
      return fallback;
    }
    final normalizedName = _normalize(name);
    if (normalizedName == normalizedQuery ||
        _singularizePhrase(normalizedName) ==
            _singularizePhrase(normalizedQuery)) {
      return FoodMatchType.exactName;
    }
    final normalizedBrand = _normalize(brandName ?? '');
    if (_containsWholeWord(normalizedName, normalizedQuery) ||
        _containsWholeWord(normalizedBrand, normalizedQuery)) {
      return fallback;
    }
    return fallback;
  }

  bool _containsWholeWord(String haystack, String needle) {
    if (haystack.isEmpty || needle.isEmpty) {
      return false;
    }
    return haystack == needle ||
        haystack.startsWith('$needle ') ||
        haystack.endsWith(' $needle') ||
        haystack.contains(' $needle ');
  }

  String _singularizePhrase(String value) {
    return value
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map(_singularizeWord)
        .join(' ');
  }

  String _singularizeWord(String value) {
    if (value.endsWith('ies') && value.length > 3) {
      return '${value.substring(0, value.length - 3)}y';
    }
    if (value.endsWith('oes') && value.length > 3) {
      return value.substring(0, value.length - 2);
    }
    if (value.endsWith('ses') && value.length > 3) {
      return value.substring(0, value.length - 2);
    }
    if (value.endsWith('s') && !value.endsWith('ss') && value.length > 3) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }

  int _queryTailPenalty(
    Iterable<String> words, {
    required int queryWordCount,
  }) {
    final normalizedWords =
        words.map(_singularizeWord).where((word) => word.isNotEmpty).toList();
    if (normalizedWords.isEmpty) {
      return 0;
    }

    var penalty = 0;
    var hasCompoundFoodWord = false;
    for (final word in normalizedWords) {
      if (_descriptorWords.contains(word)) {
        penalty += 8;
        continue;
      }
      if (_compoundFoodWords.contains(word) || _dishWords.contains(word)) {
        penalty += 210;
        hasCompoundFoodWord = true;
        continue;
      }
      penalty += 45;
    }

    if (queryWordCount == 1 && hasCompoundFoodWord) {
      penalty += 80;
    }
    return penalty;
  }

  int _breadthPenalty(FoodSearchItem item, String? query) {
    final normalizedQuery = _normalize(query ?? '');
    if (normalizedQuery.isEmpty) {
      return 0;
    }

    final normalizedName = _normalize(item.name);
    final normalizedDisplay = _normalize(item.displayName);
    final singularQuery = _singularizePhrase(normalizedQuery);
    final hasDirectNameMatch = normalizedName.contains(normalizedQuery) ||
        normalizedDisplay.contains(normalizedQuery) ||
        _singularizePhrase(normalizedName).contains(singularQuery) ||
        _singularizePhrase(normalizedDisplay).contains(singularQuery);
    if (hasDirectNameMatch) {
      return 0;
    }

    var penalty = 160;
    if (item.source == FoodSourceType.openFoodFacts &&
        item.kind == FoodKind.branded) {
      penalty += 180;
    }

    final words = normalizedDisplay
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map(_singularizeWord)
        .toList();
    if (words.any(_broadPackagedWords.contains)) {
      penalty += 220;
    }
    return penalty;
  }

  List<FoodSearchItem> _filterSearchResults(
    List<FoodSearchItem> items, {
    required String query,
    required _FetchOutcome openFoodFacts,
    required _FetchOutcome usda,
  }) {
    if (!_isLikelyGenericQuery(query)) {
      return items;
    }

    final usdaAvailable =
        usda.items.isNotEmpty && !usda.rateLimited && !usda.failed;
    final filtered = items.where((item) {
      if (item.source == FoodSourceType.custom ||
          item.source == FoodSourceType.usda) {
        return true;
      }
      if (item.kind == FoodKind.generic ||
          item.matchType == FoodMatchType.exactName) {
        return true;
      }
      if (!_hasDirectFoodNameMatch(item, query)) {
        return false;
      }
      if (_isBroadPackagedItem(item)) {
        return false;
      }
      if (!usdaAvailable && item.kind == FoodKind.branded) {
        return false;
      }
      return true;
    }).toList();

    if (filtered.isNotEmpty) {
      return filtered;
    }
    return items;
  }

  bool _isLikelyGenericQuery(String query) {
    final words = query.split(' ').where((part) => part.isNotEmpty).toList();
    if (words.isEmpty || words.length > 2) {
      return false;
    }
    if (RegExp(r'\d').hasMatch(query)) {
      return false;
    }
    return !words.any((word) =>
        _dishWords.contains(word) ||
        _compoundFoodWords.contains(word) ||
        _broadPackagedWords.contains(word));
  }

  bool _hasDirectFoodNameMatch(FoodSearchItem item, String query) {
    final normalizedName = _normalize(item.name);
    final normalizedDisplay = _normalize(item.displayName);
    final singularQuery = _singularizePhrase(query);
    return normalizedName.contains(query) ||
        normalizedDisplay.contains(query) ||
        _singularizePhrase(normalizedName).contains(singularQuery) ||
        _singularizePhrase(normalizedDisplay).contains(singularQuery);
  }

  bool _isBroadPackagedItem(FoodSearchItem item) {
    final words = _normalize(item.displayName)
        .split(' ')
        .where((part) => part.isNotEmpty)
        .map(_singularizeWord)
        .toList();
    return words.any(_broadPackagedWords.contains);
  }

  bool _hasConflict(FoodNutrients a, FoodNutrients b) {
    if (_diffAbove(a.calories, b.calories, 0.15)) return true;
    if (_diffAbove(a.proteinG, b.proteinG, 0.20)) return true;
    if (_diffAbove(a.carbsG, b.carbsG, 0.20)) return true;
    if (_diffAbove(a.fatG, b.fatG, 0.20)) return true;
    return false;
  }

  bool _diffAbove(double? left, double? right, double threshold) {
    if (left == null || right == null) return false;
    if (left == 0 && right == 0) return false;
    final maxValue = left.abs() > right.abs() ? left.abs() : right.abs();
    if (maxValue == 0) return false;
    return ((left - right).abs() / maxValue) > threshold;
  }

  double? _readOffCaloriesPer100g(
    Map<String, dynamic> nutriments,
    double? servingGrams,
  ) {
    final direct = _readOffValue(nutriments, 'energy-kcal_100g') ??
        _readOffValue(nutriments, 'energy_kcal_100g');
    if (direct != null) return direct;
    final serving = _readOffValue(nutriments, 'energy-kcal_serving') ??
        _readOffValue(nutriments, 'energy_kcal_serving');
    if (serving != null && servingGrams != null && servingGrams > 0) {
      return serving * (100 / servingGrams);
    }
    final energy = _readOffValue(nutriments, 'energy_100g');
    if (energy == null) return null;
    final unit = _readOffUnit(nutriments, 'energy');
    return _convertValue(energy, unit, _TargetUnit.kcal);
  }

  double? _readOffNutrientPer100g(
    Map<String, dynamic> nutriments, {
    required String base,
    required _TargetUnit targetUnit,
    required double? servingGrams,
  }) {
    final direct = _readOffValue(nutriments, '${base}_100g');
    if (direct != null) {
      final unit = _readOffUnit(nutriments, base);
      return _convertValue(direct, unit, targetUnit);
    }
    final serving = _readOffValue(nutriments, '${base}_serving');
    if (serving == null || servingGrams == null || servingGrams <= 0) {
      return null;
    }
    final unit = _readOffUnit(nutriments, base);
    final converted = _convertValue(serving, unit, targetUnit);
    if (converted == null) return null;
    return converted * (100 / servingGrams);
  }

  double? _readOffValue(Map<String, dynamic> nutriments, String key) {
    final value = nutriments[key];
    return FoodNutrients.asDouble(value);
  }

  String? _readOffUnit(Map<String, dynamic> nutriments, String base) {
    final direct = nutriments['${base}_unit']?.toString();
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    final alt = base.replaceAll('-', '_');
    final altValue = nutriments['${alt}_unit']?.toString();
    if (altValue != null && altValue.trim().isNotEmpty) return altValue.trim();
    return null;
  }

  double? _findUsdaNutrient(
    List<Map<String, dynamic>> nutrients,
    String number,
  ) {
    for (final nutrient in nutrients) {
      if (nutrient['nutrientNumber']?.toString() == number) {
        return FoodNutrients.asDouble(nutrient['value']);
      }
    }
    return null;
  }

  String? _findUsdaUnit(List<Map<String, dynamic>> nutrients, String number) {
    for (final nutrient in nutrients) {
      if (nutrient['nutrientNumber']?.toString() == number) {
        return nutrient['unitName']?.toString();
      }
    }
    return null;
  }

  double? _convertValue(double value, String? unit, _TargetUnit targetUnit) {
    if (targetUnit == _TargetUnit.kcal) {
      final normalized = (unit ?? 'kcal').toLowerCase();
      if (normalized == 'kj') return value / 4.184;
      return value;
    }
    final normalized = (unit ?? '').replaceAll('\u00b5', 'u').toLowerCase();
    final mgValue = switch (normalized) {
      'g' => value * 1000,
      'mg' => value,
      'ug' => value / 1000,
      'mcg' => value / 1000,
      'iu' => null,
      '' => value,
      _ => value,
    };
    if (mgValue == null) return null;
    return switch (targetUnit) {
      _TargetUnit.kcal => mgValue,
      _TargetUnit.mg => mgValue,
      _TargetUnit.mcg => mgValue * 1000,
    };
  }

  double? _parseGrams(
    String? text, {
    double? fallbackValue,
    String? fallbackUnit,
  }) {
    if (fallbackValue != null) {
      final converted = _gramsFromUnit(fallbackValue, fallbackUnit);
      if (converted != null && converted > 0) return converted;
    }
    final raw = text?.trim();
    if (raw == null || raw.isEmpty) return null;
    final paren = RegExp(r'\(([\d.]+)\s*([a-zA-Z]+)\)').firstMatch(raw);
    if (paren != null) {
      final value = double.tryParse(paren.group(1) ?? '');
      final unit = paren.group(2);
      final grams = value == null ? null : _gramsFromUnit(value, unit);
      if (grams != null) return grams;
    }
    final direct = RegExp(r'([\d.]+)\s*([a-zA-Z]+)').firstMatch(raw);
    if (direct != null) {
      final value = double.tryParse(direct.group(1) ?? '');
      final unit = direct.group(2);
      final grams = value == null ? null : _gramsFromUnit(value, unit);
      if (grams != null) return grams;
    }
    return null;
  }

  double? _gramsFromUnit(double? value, String? unit) {
    if (value == null) return null;
    final normalized = unit?.trim().toLowerCase();
    switch (normalized) {
      case 'g':
      case 'grm':
      case 'gram':
      case 'grams':
        return value;
      case 'oz':
      case 'onz':
      case 'ounce':
      case 'ounces':
        return value * 28.3495;
      case 'lb':
      case 'lbs':
      case 'pound':
      case 'pounds':
        return value * 453.592;
      case 'ml':
      case 'milliliter':
      case 'milliliters':
        return value;
      default:
        return normalized == null || normalized.isEmpty ? value : null;
    }
  }

  String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  String _lookupKey(FoodSearchItem item) {
    final barcode = item.barcode?.trim();
    if (barcode != null && barcode.isNotEmpty) {
      return 'barcode:$barcode';
    }
    final brand = _normalize(item.brandName ?? '');
    return 'name:${_normalize(item.name)}|brand:$brand';
  }

  String _titleCase(String input) {
    return input
        .split(' ')
        .where((segment) => segment.isNotEmpty)
        .map((segment) {
      if (segment.length == 1) return segment.toUpperCase();
      return '${segment[0].toUpperCase()}${segment.substring(1).toLowerCase()}';
    }).join(' ');
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  String? _mergeInfoMessage(List<_FetchOutcome> fetches) {
    final rateLimited = fetches.any((fetch) => fetch.rateLimited);
    final failures = fetches.where((fetch) => fetch.failed).length;
    if (rateLimited) {
      return 'One food source is rate limited. Showing available results.';
    }
    if (failures == 1) {
      return 'One food source is unavailable. Showing available results.';
    }
    if (failures >= 2) {
      return 'Food sources are temporarily unavailable.';
    }
    return null;
  }

  String? _searchInfoMessage(
    List<_FetchOutcome> fetches, {
    required String query,
    required List<FoodSearchItem> items,
  }) {
    final genericQuery = _isLikelyGenericQuery(query);
    final usda =
        fetches.length > 1 ? fetches[1] : const _FetchOutcome(items: []);
    if (genericQuery && items.isEmpty && (usda.rateLimited || usda.failed)) {
      return 'Generic food results are temporarily limited. Try again later or search for a packaged food.';
    }
    return _mergeInfoMessage(fetches);
  }

  Map<String, dynamic> _responseToMap(FoodLookupResponse response) {
    return {
      'items': response.items.map((item) => item.toMap()).toList(),
      'info_message': response.infoMessage,
    };
  }

  FoodLookupResponse _responseFromMap(Map<String, dynamic> map) {
    final rawItems = map['items'] as List<dynamic>? ?? const [];
    return FoodLookupResponse(
      items: rawItems
          .whereType<Map>()
          .map((item) => FoodSearchItem.fromMap(item.cast<String, dynamic>()))
          .toList(),
      infoMessage: map['info_message']?.toString(),
    );
  }
}

class _FetchOutcome {
  const _FetchOutcome({
    required this.items,
    this.failed = false,
    this.rateLimited = false,
  });

  final List<FoodSearchItem> items;
  final bool failed;
  final bool rateLimited;
}

class _OffMicroSpec {
  const _OffMicroSpec(this.offKey, this.storageKey, this.targetUnit);

  final String offKey;
  final String storageKey;
  final _TargetUnit targetUnit;
}

class _UsdaMicroSpec {
  const _UsdaMicroSpec(this.number, this.storageKey, this.targetUnit);

  final String number;
  final String storageKey;
  final _TargetUnit targetUnit;
}

enum _TargetUnit { kcal, mg, mcg }

const List<_OffMicroSpec> _offMicroSpecs = [
  _OffMicroSpec('potassium', 'potassium_mg', _TargetUnit.mg),
  _OffMicroSpec('iron', 'iron_mg', _TargetUnit.mg),
  _OffMicroSpec('magnesium', 'magnesium_mg', _TargetUnit.mg),
  _OffMicroSpec('phosphorus', 'phosphorus_mg', _TargetUnit.mg),
  _OffMicroSpec('zinc', 'zinc_mg', _TargetUnit.mg),
  _OffMicroSpec('copper', 'copper_mg', _TargetUnit.mg),
  _OffMicroSpec('calcium', 'calcium_mg', _TargetUnit.mg),
  _OffMicroSpec('biotin', 'biotin_mcg', _TargetUnit.mcg),
  _OffMicroSpec('vitamin-a', 'vitamin_a_mcg', _TargetUnit.mcg),
  _OffMicroSpec('vitamin-c', 'vitamin_c_mg', _TargetUnit.mg),
  _OffMicroSpec('vitamin-d', 'vitamin_d_mcg', _TargetUnit.mcg),
  _OffMicroSpec('vitamin-e', 'vitamin_e_mg', _TargetUnit.mg),
  _OffMicroSpec('vitamin-k', 'vitamin_k_mcg', _TargetUnit.mcg),
  _OffMicroSpec('thiamin', 'thiamin_mg', _TargetUnit.mg),
  _OffMicroSpec('riboflavin', 'riboflavin_mg', _TargetUnit.mg),
  _OffMicroSpec('niacin', 'niacin_mg', _TargetUnit.mg),
  _OffMicroSpec('pantothenic-acid', 'pantothenic_acid_mg', _TargetUnit.mg),
  _OffMicroSpec('vitamin-b6', 'vitamin_b6_mg', _TargetUnit.mg),
  _OffMicroSpec('folates', 'folate_mcg', _TargetUnit.mcg),
  _OffMicroSpec('vitamin-b12', 'vitamin_b12_mcg', _TargetUnit.mcg),
];

const List<_UsdaMicroSpec> _usdaMicroSpecs = [
  _UsdaMicroSpec('301', 'calcium_mg', _TargetUnit.mg),
  _UsdaMicroSpec('303', 'iron_mg', _TargetUnit.mg),
  _UsdaMicroSpec('304', 'magnesium_mg', _TargetUnit.mg),
  _UsdaMicroSpec('305', 'phosphorus_mg', _TargetUnit.mg),
  _UsdaMicroSpec('306', 'potassium_mg', _TargetUnit.mg),
  _UsdaMicroSpec('309', 'zinc_mg', _TargetUnit.mg),
  _UsdaMicroSpec('312', 'copper_mg', _TargetUnit.mg),
  _UsdaMicroSpec('320', 'vitamin_a_mcg', _TargetUnit.mcg),
  _UsdaMicroSpec('323', 'vitamin_e_mg', _TargetUnit.mg),
  _UsdaMicroSpec('328', 'vitamin_d_mcg', _TargetUnit.mcg),
  _UsdaMicroSpec('430', 'vitamin_k_mcg', _TargetUnit.mcg),
  _UsdaMicroSpec('401', 'vitamin_c_mg', _TargetUnit.mg),
  _UsdaMicroSpec('404', 'thiamin_mg', _TargetUnit.mg),
  _UsdaMicroSpec('405', 'riboflavin_mg', _TargetUnit.mg),
  _UsdaMicroSpec('406', 'niacin_mg', _TargetUnit.mg),
  _UsdaMicroSpec('410', 'pantothenic_acid_mg', _TargetUnit.mg),
  _UsdaMicroSpec('415', 'vitamin_b6_mg', _TargetUnit.mg),
  _UsdaMicroSpec('416', 'biotin_mcg', _TargetUnit.mcg),
  _UsdaMicroSpec('418', 'vitamin_b12_mcg', _TargetUnit.mcg),
  _UsdaMicroSpec('435', 'folate_mcg', _TargetUnit.mcg),
];

const Set<String> _dishWords = {
  'soup',
  'salad',
  'chip',
  'fry',
  'frie',
  'stew',
  'casserole',
  'sandwich',
  'pie',
  'cake',
  'cookie',
  'bread',
  'pasta',
  'hash',
  'puree',
  'mashed',
  'bake',
  'baked',
  'roast',
  'roasted',
};

const Set<String> _compoundFoodWords = {
  'patty',
  'pancake',
  'flour',
  'starch',
  'dumpling',
  'wedge',
  'tot',
  'croquette',
  'hashbrown',
  'gnocchi',
};

const Set<String> _descriptorWords = {
  'nfs',
  'ns',
  'raw',
  'cooked',
  'fresh',
  'plain',
  'unsalted',
  'salted',
  'boiled',
  'steamed',
  'mashed',
  'flesh',
  'skin',
  'with',
  'without',
  'peel',
  'peeled',
  'unpeeled',
  'drained',
  'heated',
  'microwaved',
};

const Set<String> _broadPackagedWords = {
  'chip',
  'crisp',
  'snack',
  'pringle',
  'wafer',
  'barbecue',
  'bbq',
  'cream',
  'onion',
  'salted',
  'salt',
  'sour',
  'vinegar',
  'cheese',
  'pesto',
  'mozzarella',
  'flavour',
  'flavor',
};

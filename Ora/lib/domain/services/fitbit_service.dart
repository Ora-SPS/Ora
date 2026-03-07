import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FitbitLinkResult {
  const FitbitLinkResult({
    required this.success,
    this.message,
  });

  final bool success;
  final String? message;
}

class FitbitService {
  FitbitService({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static const String _fitbitClientId =
      String.fromEnvironment('FITBIT_CLIENT_ID', defaultValue: '');
  static const String _fitbitRedirectScheme = 'orafitbit';
  static const String _fitbitRedirectHost = 'auth';
  static const String _fitbitScope = 'activity profile';
  static const String _accessTokenKey = 'fitbit.access_token.v1';
  static const String _refreshTokenKey = 'fitbit.refresh_token.v1';
  static const String _expiresAtKey = 'fitbit.expires_at_ms.v1';
  static const String _clientIdPrefsKey = 'fitbit.client_id.v1';

  final http.Client _http;
  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');
  final Random _random = Random.secure();

  String get redirectUri => '$_fitbitRedirectScheme://$_fitbitRedirectHost';

  Future<String?> getConfiguredClientId() async {
    final prefs = await SharedPreferences.getInstance();
    final persisted = prefs.getString(_clientIdPrefsKey)?.trim();
    if (persisted != null && persisted.isNotEmpty) {
      return persisted;
    }
    final buildTimeId = _fitbitClientId.trim();
    if (buildTimeId.isNotEmpty) {
      return buildTimeId;
    }
    return null;
  }

  Future<bool> isConfigured() async {
    return (await getConfiguredClientId()) != null;
  }

  Future<void> setClientId(String? clientId) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = clientId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(_clientIdPrefsKey);
      return;
    }
    await prefs.setString(_clientIdPrefsKey, trimmed);
  }

  Future<bool> hasLinkedAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    return (accessToken != null && accessToken.isNotEmpty) ||
        (refreshToken != null && refreshToken.isNotEmpty);
  }

  Future<FitbitLinkResult> linkAccount() async {
    if (kIsWeb) {
      return const FitbitLinkResult(
        success: false,
        message: 'Fitbit linking is not supported on web.',
      );
    }
    final clientId = await getConfiguredClientId();
    if (clientId == null) {
      return const FitbitLinkResult(
        success: false,
        message:
            'Fitbit is not configured. Add your Fitbit Client ID in-app, then try again.',
      );
    }
    final codeVerifier = _randomString(96);
    final codeChallenge = _codeChallengeForVerifier(codeVerifier);
    final state = _randomString(24);
    final authUri = Uri.https(
      'www.fitbit.com',
      '/oauth2/authorize',
      {
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': _fitbitScope,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );

    try {
      final callback = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: _fitbitRedirectScheme,
      );
      final callbackUri = Uri.parse(callback);
      final callbackState = callbackUri.queryParameters['state'];
      if (callbackState != state) {
        return const FitbitLinkResult(
          success: false,
          message: 'Fitbit linking failed due to a mismatched auth state.',
        );
      }
      final error = callbackUri.queryParameters['error'];
      if (error != null && error.isNotEmpty) {
        final description = callbackUri.queryParameters['error_description'];
        return FitbitLinkResult(
          success: false,
          message: description == null || description.isEmpty
              ? 'Fitbit linking was denied.'
              : 'Fitbit linking failed: $description',
        );
      }
      final code = callbackUri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        return const FitbitLinkResult(
          success: false,
          message: 'Fitbit did not return an authorization code.',
        );
      }
      final tokens = await _exchangeAuthorizationCode(
        code: code,
        codeVerifier: codeVerifier,
        clientId: clientId,
      );
      if (tokens == null) {
        return const FitbitLinkResult(
          success: false,
          message: 'Unable to exchange Fitbit authorization for access.',
        );
      }
      await _persistTokens(tokens);
      return const FitbitLinkResult(success: true);
    } catch (_) {
      return const FitbitLinkResult(
        success: false,
        message: 'Fitbit linking was cancelled or failed to open.',
      );
    }
  }

  Future<void> unlinkAccount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
    await prefs.remove(_expiresAtKey);
  }

  Future<int?> getStepsForDay(DateTime day) async {
    final accessToken = await _ensureValidAccessToken();
    if (accessToken == null) return null;
    final dateString = _dateFormat.format(day);
    final uri = Uri.parse(
        'https://api.fitbit.com/1/user/-/activities/date/$dateString.json');
    final response = await _http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
      },
    );
    if (response.statusCode == 401) {
      final refreshedToken = await _refreshAccessToken();
      if (refreshedToken == null) {
        return null;
      }
      final retry = await _http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $refreshedToken',
          'Accept': 'application/json',
        },
      );
      if (retry.statusCode != 200) return null;
      return _parseStepsFromDailySummary(retry.body);
    }
    if (response.statusCode != 200) {
      return null;
    }
    return _parseStepsFromDailySummary(response.body);
  }

  int? _parseStepsFromDailySummary(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final summary = decoded['summary'];
      if (summary is! Map<String, dynamic>) return null;
      final raw = summary['steps'];
      if (raw is num) return raw.toInt();
      if (raw is String) return int.tryParse(raw);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _ensureValidAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_accessTokenKey);
    final refreshToken = prefs.getString(_refreshTokenKey);
    final expiresAtMs = prefs.getInt(_expiresAtKey);
    if (accessToken == null || accessToken.isEmpty) {
      return await _refreshAccessToken();
    }
    if (expiresAtMs == null) {
      return accessToken;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final safetyWindowMs = const Duration(minutes: 2).inMilliseconds;
    if (nowMs + safetyWindowMs < expiresAtMs) {
      return accessToken;
    }
    if (refreshToken == null || refreshToken.isEmpty) {
      return accessToken;
    }
    return await _refreshAccessToken();
  }

  Future<String?> _refreshAccessToken() async {
    final clientId = await getConfiguredClientId();
    if (clientId == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString(_refreshTokenKey);
    if (refreshToken == null || refreshToken.isEmpty) return null;
    final response = await _postTokenRequest(
      clientId: clientId,
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      },
    );
    if (response.statusCode != 200) {
      await unlinkAccount();
      return null;
    }
    final tokens = _FitbitTokens.fromTokenResponse(response.body);
    if (tokens == null) {
      await unlinkAccount();
      return null;
    }
    await _persistTokens(tokens);
    return tokens.accessToken;
  }

  Future<_FitbitTokens?> _exchangeAuthorizationCode({
    required String code,
    required String codeVerifier,
    required String clientId,
  }) async {
    final response = await _postTokenRequest(
      clientId: clientId,
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': codeVerifier,
      },
    );
    if (response.statusCode != 200) {
      return null;
    }
    return _FitbitTokens.fromTokenResponse(response.body);
  }

  Future<void> _persistTokens(_FitbitTokens tokens) async {
    final prefs = await SharedPreferences.getInstance();
    final expiresAt = DateTime.now().add(Duration(seconds: tokens.expiresIn));
    await prefs.setString(_accessTokenKey, tokens.accessToken);
    await prefs.setString(_refreshTokenKey, tokens.refreshToken);
    await prefs.setInt(_expiresAtKey, expiresAt.millisecondsSinceEpoch);
  }

  Future<http.Response> _postTokenRequest({
    required String clientId,
    required Map<String, String> body,
  }) async {
    final uri = Uri.parse('https://api.fitbit.com/oauth2/token');
    final firstAttempt = await _http.post(
      uri,
      headers: _tokenHeaders(
        includeAuth: true,
        clientId: clientId,
      ),
      body: body,
    );
    if (firstAttempt.statusCode == 200) {
      return firstAttempt;
    }
    return _http.post(
      uri,
      headers: _tokenHeaders(
        includeAuth: false,
        clientId: clientId,
      ),
      body: body,
    );
  }

  Map<String, String> _tokenHeaders({
    required bool includeAuth,
    required String clientId,
  }) {
    final basic = base64Encode(utf8.encode('$clientId:'));
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    };
    if (includeAuth) {
      headers['Authorization'] = 'Basic $basic';
    }
    return headers;
  }

  String _codeChallengeForVerifier(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier)).bytes;
    return base64UrlEncode(digest).replaceAll('=', '');
  }

  String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final bytes = List<int>.generate(
      length,
      (_) => _random.nextInt(chars.length),
    );
    final buffer = StringBuffer();
    for (final idx in bytes) {
      buffer.write(chars[idx]);
    }
    return buffer.toString();
  }
}

class _FitbitTokens {
  const _FitbitTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final String accessToken;
  final String refreshToken;
  final int expiresIn;

  static _FitbitTokens? fromTokenResponse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final accessToken = decoded['access_token'] as String?;
      final refreshToken = decoded['refresh_token'] as String?;
      final expiresRaw = decoded['expires_in'];
      final expiresIn = expiresRaw is num
          ? expiresRaw.toInt()
          : int.tryParse('$expiresRaw') ?? 3600;
      if (accessToken == null ||
          accessToken.isEmpty ||
          refreshToken == null ||
          refreshToken.isEmpty) {
        return null;
      }
      return _FitbitTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresIn: expiresIn,
      );
    } catch (_) {
      return null;
    }
  }
}

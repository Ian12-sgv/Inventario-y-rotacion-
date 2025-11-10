// lib/screen/api_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Configuración de una API (base URL + API key).
class ApiConfig {
  final String baseUrl;           // ej: https://api2.apipalacio.com
  final String apiKey;            // tu x-api-key
  final Duration timeout;

  const ApiConfig({
    required this.baseUrl,
    required this.apiKey,
    this.timeout = const Duration(seconds: 12),
  });

  Uri uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse(baseUrl);
    final joinedPath = _joinPath(base.path, path);
    return base.replace(
      path: joinedPath,
      queryParameters:
          query?.map((k, v) => MapEntry(k, v?.toString() ?? "")),
    );
  }

  static String _joinPath(String a, String b) {
    final p1 = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final p2 = b.startsWith('/') ? b.substring(1) : b;
    if (p1.isEmpty) return '/$p2';
    if (p2.isEmpty) return p1.isEmpty ? '/' : p1;
    return '$p1/$p2';
  }
}

class ApiException implements IOException {
  final int statusCode;
  final String message;
  final String? body;

  ApiException(this.statusCode, this.message, [this.body]);

  @override
  String toString() => 'ApiException($statusCode): $message ${body ?? ""}';
}

/// Cliente HTTP simple para tus endpoints.
class ApiService {
  final ApiConfig cfg;
  final http.Client _client;

  ApiService(this.cfg, {http.Client? client})
      : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'x-api-key': cfg.apiKey,
        'Accept': 'application/json',
      };

  Future<bool> ping() async {
    final uri = cfg.uri('/api/ping');
    final res =
        await _client.get(uri, headers: _headers).timeout(cfg.timeout);
    if (res.statusCode == 200) {
      try {
        final j = jsonDecode(res.body);
        return j is Map && j['ok'] == true;
      } catch (_) {
        return true;
      }
    }
    if (res.statusCode == 401) {
      throw ApiException(res.statusCode, 'API key inválida', res.body);
    }
    throw ApiException(res.statusCode, 'Ping falló', res.body);
  }

  Future<Map<String, dynamic>?> producto(String codigo) async {
    final uri = cfg.uri('/api/productos/$codigo');
    final res =
        await _client.get(uri, headers: _headers).timeout(cfg.timeout);
    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    if (res.statusCode == 404) return null;
    throw ApiException(res.statusCode, 'Consulta de producto falló', res.body);
  }

  Future<List<dynamic>> productoTodas(String codigo) async {
    final uri = cfg.uri('/api/productos/$codigo/todas');
    return _getJsonList(uri);
  }

  Future<Map<String, dynamic>> productoResumen(String codigo) async {
    final uri = cfg.uri('/api/productos/$codigo/resumen');
    return _getJsonMap(uri);
  }

  Future<List<dynamic>> inventario() async {
    final uri = cfg.uri('/api/inventario');
    return _getJsonList(uri);
  }

  // ---- helpers internos ----

  Future<Map<String, dynamic>> _getJsonMap(Uri uri) async {
    final res =
        await _client.get(uri, headers: _headers).timeout(cfg.timeout);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return {};
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw ApiException(res.statusCode, 'GET ${uri.path} falló', res.body);
  }

  Future<List<dynamic>> _getJsonList(Uri uri) async {
    final res =
        await _client.get(uri, headers: _headers).timeout(cfg.timeout);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return const [];
      final data = jsonDecode(res.body);
      if (data is List) return data;
      // por si tu backend usa { data: [...] }
      if (data is Map && data['data'] is List) return data['data'] as List;
      throw ApiException(
          res.statusCode, 'Forma de JSON inesperada', res.body);
    }
    throw ApiException(res.statusCode, 'GET ${uri.path} falló', res.body);
  }

  void close() => _client.close();
}

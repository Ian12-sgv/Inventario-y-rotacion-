// lib/screen/api_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Configuración de una API (base URL + API key).
class ApiConfig {
  final String baseUrl; // ej: http://127.0.0.1:5100 o https://api2.apipalacio.com
  final String apiKey;  // header x-api-key
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
      queryParameters: query?.map((k, v) => MapEntry(k, v?.toString() ?? "")),
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

/// Modelo de error del backend: { code, message, traceId }
class ApiError {
  final String code;
  final String message;
  final String? traceId;

  const ApiError({required this.code, required this.message, this.traceId});

  factory ApiError.fromJson(Map<String, dynamic> j) => ApiError(
        code: (j['code'] ?? '').toString(),
        message: (j['message'] ?? '').toString(),
        traceId: j['traceId']?.toString(),
      );
}

/// Excepción de alto nivel para UI (mensaje listo para mostrar)
class ApiFailure implements IOException {
  final int? statusCode; // null si no hubo respuesta HTTP (internet/timeout)
  final String code;     // e.g. scan_too_fast, db_error, no_internet, timeout
  final String message;  // mensaje para el usuario
  final String? traceId; // viene del backend cuando aplica
  final String? rawBody; // útil para debug

  ApiFailure({
    required this.code,
    required this.message,
    this.statusCode,
    this.traceId,
    this.rawBody,
  });

  @override
  String toString() =>
      'ApiFailure(status=$statusCode, code=$code, message=$message, traceId=${traceId ?? "-"})';
}

/// Cliente HTTP simple para tus endpoints.
class ApiService {
  final ApiConfig cfg;
  final http.Client _client;

  ApiService(this.cfg, {http.Client? client}) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'x-api-key': cfg.apiKey,
        'Accept': 'application/json',
      };

  Future<bool> ping() async {
    final uri = cfg.uri('/api/ping');
    final res = await _safeGet(uri);

    if (res.statusCode == 200) {
      try {
        final j = jsonDecode(res.body);
        return j is Map && j['ok'] == true;
      } catch (_) {
        return true;
      }
    }

    // Si llega aquí, hubo respuesta no-200: convertir a ApiFailure con mensaje entendible
    throw _mapHttpFailure(res, fallback: 'Ping falló');
  }

  /// Devuelve null si el producto no existe (404 not_found),
  /// o lanza ApiFailure para cualquier otro error.
  Future<Map<String, dynamic>?> producto(String codigo) async {
    final uri = cfg.uri('/api/productos/$codigo');
    final res = await _safeGet(uri);

    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }

    if (res.statusCode == 404) return null;

    throw _mapHttpFailure(res, fallback: 'Consulta de producto falló');
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

  Future<http.Response> _safeGet(Uri uri) async {
    try {
      return await _client.get(uri, headers: _headers).timeout(cfg.timeout);
    } on SocketException {
      throw ApiFailure(
        code: 'no_internet',
        message: 'Sin conexión. Verifica tu internet e intenta nuevamente.',
        statusCode: null,
      );
    } on TimeoutException {
      throw ApiFailure(
        code: 'timeout',
        message: 'La solicitud tardó demasiado. Intenta nuevamente.',
        statusCode: null,
      );
    } on HttpException {
      throw ApiFailure(
        code: 'http_error',
        message: 'Error de red. Intenta nuevamente.',
        statusCode: null,
      );
    } catch (_) {
      throw ApiFailure(
        code: 'unknown_network_error',
        message: 'No se pudo conectar. Intenta nuevamente.',
        statusCode: null,
      );
    }
  }

  Future<Map<String, dynamic>> _getJsonMap(Uri uri) async {
    final res = await _safeGet(uri);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return {};
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw _mapHttpFailure(res, fallback: 'GET ${uri.path} falló');
  }

  Future<List<dynamic>> _getJsonList(Uri uri) async {
    final res = await _safeGet(uri);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return const [];
      final data = jsonDecode(res.body);
      if (data is List) return data;
      // por si tu backend usa { data: [...] }
      if (data is Map && data['data'] is List) return data['data'] as List;
      throw ApiFailure(
        statusCode: res.statusCode,
        code: 'unexpected_json',
        message: 'Respuesta inesperada del servidor.',
        rawBody: res.body,
      );
    }
    throw _mapHttpFailure(res, fallback: 'GET ${uri.path} falló');
  }

  ApiFailure _mapHttpFailure(http.Response res, {required String fallback}) {
    final status = res.statusCode;
    final body = res.body;

    ApiError? apiErr;
    try {
      if (body.isNotEmpty) {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic> &&
            decoded.containsKey('code') &&
            decoded.containsKey('message')) {
          apiErr = ApiError.fromJson(decoded);
        }
      }
    } catch (_) {
      // body no es JSON, ignorar
    }

    // 1) Si el backend envió code/message, lo usamos
    if (apiErr != null && apiErr.code.isNotEmpty) {
      // Mensajes “amigables” por code (puedes ajustar)
      final msg = _friendlyMessageForCode(apiErr.code, apiErr.message, status);
      return ApiFailure(
        statusCode: status,
        code: apiErr.code,
        message: msg,
        traceId: apiErr.traceId,
        rawBody: body,
      );
    }

    // 2) Si no vino JSON estandar, usar statusCode
    return ApiFailure(
      statusCode: status,
      code: _codeFromStatus(status),
      message: _friendlyMessageForStatus(status, fallback),
      rawBody: body,
    );
  }

  static String _codeFromStatus(int status) {
    if (status == 401) return 'invalid_api_key';
    if (status == 404) return 'not_found';
    if (status == 429) return 'scan_too_fast';
    if (status == 503) return 'db_error';
    if (status == 504) return 'db_timeout';
    if (status == 400) return 'bad_request';
    return 'http_$status';
  }

  static String _friendlyMessageForStatus(int status, String fallback) {
    switch (status) {
      case 400:
        return 'Solicitud inválida. Verifica el código e intenta nuevamente.';
      case 401:
        return 'Acceso no autorizado. Verifica el API key.';
      case 404:
        return 'Producto no encontrado.';
      case 429:
        return 'Escaneo muy rápido. Espera un momento y vuelve a intentar.';
      case 503:
        return 'No se pudo consultar la base de datos. Intenta de nuevo.';
      case 504:
        return 'La consulta tardó demasiado. Intenta nuevamente.';
      default:
        return 'Error del servidor ($status). ${fallback.isNotEmpty ? fallback : "Intenta más tarde."}';
    }
  }

  static String _friendlyMessageForCode(String code, String backendMessage, int status) {
    // Si el backend ya envía un mensaje adecuado, lo respetamos,
    // pero para códigos conocidos priorizamos mensajes consistentes.
    switch (code) {
      case 'scan_too_fast':
        return 'Escaneo muy rápido. Espera un momento y vuelve a intentar.';
      case 'no_internet':
        return 'Sin conexión. Verifica tu internet e intenta nuevamente.';
      case 'timeout':
      case 'db_timeout':
        return 'La consulta tardó demasiado. Intenta nuevamente.';
      case 'db_error':
        return 'No se pudo consultar la base de datos. Intenta de nuevo.';
      case 'invalid_api_key':
        return 'Acceso no autorizado. Verifica el API key.';
      case 'invalid_code':
        return 'Código inválido. Vuelve a escanear.';
      case 'not_found':
        return 'Producto no encontrado.';
      case 'server_error':
        return 'Ocurrió un error interno. Intenta más tarde.';
      default:
        // Si no es un code conocido, usar el message del backend si existe
        if (backendMessage.trim().isNotEmpty) return backendMessage.trim();
        return _friendlyMessageForStatus(status, 'Intenta nuevamente.');
    }
  }

  void close() => _client.close();
}

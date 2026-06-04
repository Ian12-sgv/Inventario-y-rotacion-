// lib/screen/consultaprecio.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;

import '../app_session.dart';
import '../platform_support.dart';
import '../scanner_support.dart';

// ===== Config API PRINCIPAL =====
const String kApiBase = String.fromEnvironment('API_BASE',
    defaultValue: 'https://api2.apipalacio.com');
const String kTasaApiKey = String.fromEnvironment('API_KEY',
    defaultValue: 'k9mWIm4Nd3j9KomxkT28cBqJY4eYeWm58X+Fmp1Kq0g=');

// ===== Config API TASA =====
const String kTasaBase = String.fromEnvironment(
  'TASA_BASE',
  // Solo la base, sin /api/tasa
  defaultValue: 'https://api4.apipalacio.com',
);

class ScreenConsulta extends StatefulWidget {
  const ScreenConsulta({
    super.key,
    required this.session,
  });

  final AppSession session;

  @override
  State<ScreenConsulta> createState() => _ScreenConsultaState();
}

class _ScreenConsultaState extends State<ScreenConsulta> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  Map<String, dynamic>? _producto;

  // Datos de stock
  List<Map<String, dynamic>> _stock = [];
  List<Map<String, dynamic>> _stockCasaMatriz = [];
  Map<String, List<Map<String, dynamic>>> _stockPorRegion = {};
  Map<String, int> _totalesPorRegion = {};

  int _totalGeneral = 0;
  int _totalCasaMatriz = 0;
  int _totalTiendas = 0;

  bool _loading = false;

  // Bandera para ocultar todo y mostrar solo el mensaje
  bool _sinExistencia = false;

  // Datos de tasa (cada una con su fecha)
  double? _tasaOficial;
  double? _tasaMayor;
  String? _tasaFechaOficial;
  String? _tasaFechaMayor;
  bool _loadingTasa = false;
  String? _tasaError;

  bool _asBool(dynamic value) {
    if (value is bool) return value;

    final normalized = (value ?? '').toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }

  bool _isBodega(Map<String, dynamic> row) {
    if (row.containsKey('EsBodega') && row['EsBodega'] != null) {
      return _asBool(row['EsBodega']);
    }

    if (row.containsKey('Tipo') && row['Tipo'] != null) {
      return !_asBool(row['Tipo']);
    }

    return false;
  }

  Map<String, String> get _apiHeaders => widget.session.authHeaders;

  @override
  void initState() {
    super.initState();
    _cargarTasa(); // Carga la tasa de cambio al abrir la pantalla
  }

  // ==== NUEVO: Normalización EAN/UPC para evitar 404 por formato ====
  // - deja solo dígitos
  // - si viene UPC-A (12), lo transforma a EAN-13 agregando "0" al inicio
  // - si viene EAN-13 que empieza con 0, también podremos probar sin el 0 (fallback)
  String _normalizeCodigo(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';
    if (digits.length == 12) return '0$digits';
    return digits;
  }

  // Crea lista de candidatos a probar (para reducir falsos 404 por 12/13 dígitos)
  List<String> _codigoCandidates(String raw) {
    final digitsOnly = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitsOnly.isEmpty) return const [];

    final normalized = _normalizeCodigo(raw);
    final candidates = <String>{};

    // 1) Lo normalizado primero
    if (normalized.isNotEmpty) candidates.add(normalized);

    // 2) El original solo-dígitos también (por si backend guarda distinto)
    candidates.add(digitsOnly);

    // 3) Si normalizado quedó con 13 y empieza con 0, probar sin 0
    if (normalized.length == 13 && normalized.startsWith('0')) {
      candidates.add(normalized.substring(1)); // 12 dígitos
    }

    // 4) Si viene 12, probar con 0 al inicio (13)
    if (digitsOnly.length == 12) {
      candidates.add('0$digitsOnly');
    }

    return candidates.toList();
  }

  // ==== Consumir API de TASA ====
  Future<void> _cargarTasa() async {
    if (mounted) {
      setState(() {
        _loadingTasa = true;
        _tasaError = null;
      });
    }

    try {
      final uri = Uri.parse('$kTasaBase/api/tasa');
      final resp = await http.get(uri, headers: {
        'x-api-key': kTasaApiKey
      }).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data is List && data.isNotEmpty) {
          // Fila 0 -> Oficial
          final first = Map<String, dynamic>.from(data[0] as Map);
          _tasaFechaOficial = first['fecha']?.toString();
          _tasaOficial = double.tryParse(first['valor'].toString());

          // Fila 1 -> Mayorista (si existe)
          if (data.length > 1) {
            final second = Map<String, dynamic>.from(data[1] as Map);
            _tasaFechaMayor = second['fecha']?.toString();
            _tasaMayor = double.tryParse(second['valor'].toString());
          } else {
            _tasaFechaMayor = null;
            _tasaMayor = null;
          }

          _tasaError = _tasaOficial == null
              ? 'No hay tasa disponible en este momento.'
              : null;
        } else {
          _tasaError = 'No hay tasa disponible en este momento.';
        }
      } else if (resp.statusCode == 401) {
        _tasaError = 'No se pudo autorizar la consulta de la tasa.';
      } else {
        _tasaError = 'No se pudo cargar la tasa del dia.';
      }
    } on TimeoutException {
      _tasaError = 'La consulta de tasa tardo demasiado.';
    } catch (_) {
      _tasaError = 'No se pudo cargar la tasa del dia.';
    } finally {
      if (mounted) {
        setState(() {
          _loadingTasa = false;
        });
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchProductoTodas(String codigo) async {
    final uri = Uri.parse('$kApiBase/api/productos/$codigo/todas');

    http.Response resp;
    try {
      resp = await http
          .get(uri, headers: _apiHeaders)
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw 'La solicitud tardó demasiado. Intenta nuevamente.';
    } on SocketException {
      throw 'Sin conexión. Verifica tu internet e intenta nuevamente.';
    } on http.ClientException {
      throw 'Error de red. Intenta nuevamente.';
    } catch (_) {
      throw 'No se pudo conectar. Intenta nuevamente.';
    }

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      if (data is List) {
        // Filtra filas de totales si vinieran en la respuesta
        return data.whereType<Map>().cast<Map<String, dynamic>>().where((m) {
          final tienda = (m['Tienda'] ?? '').toString().toUpperCase();
          return !(tienda.startsWith('TOTAL '));
        }).toList();
      }
      throw 'Respuesta inesperada del servidor.';
    }

    if (resp.statusCode == 404) {
      return [];
    }

    // NUEVO: mensajes claros según JSON {code,message} o statusCode
    throw _apiErrorMessage(resp);
  }

  String _apiErrorMessage(http.Response resp) {
    final status = resp.statusCode;
    final body = resp.body;

    // 1) Intentar leer el contrato { code, message, traceId }
    try {
      if (body.isNotEmpty) {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          final code = (map['code'] ?? '').toString();
          final msg = (map['message'] ?? '').toString();

          if (code.isNotEmpty) {
            switch (code) {
              case 'scan_too_fast':
                return 'Escaneo muy rápido. Espera un momento y vuelve a intentar.';
              case 'db_timeout':
                return 'La consulta tardó demasiado. Intenta nuevamente.';
              case 'db_error':
                return 'No se pudo consultar la base de datos. Intenta de nuevo.';
              case 'invalid_api_key':
              case 'invalid_credentials':
                return 'Acceso no autorizado. Verifica tu usuario y contrasena.';
              case 'invalid_code':
                return 'Código inválido. Vuelve a escanear.';
              case 'not_found':
                return 'Producto no encontrado.';
              case 'server_error':
                return 'Ocurrió un error interno. Intenta más tarde.';
              default:
                // Si backend manda un mensaje útil, usarlo
                if (msg.trim().isNotEmpty) return msg.trim();
                break;
            }
          }

          // Si no hay code, pero hay message
          if (msg.trim().isNotEmpty) return msg.trim();
        }
      }
    } catch (_) {
      // Si no es JSON válido, seguimos con status code
    }

    // 2) Fallback por status code
    switch (status) {
      case 400:
        return 'Solicitud inválida. Verifica el código e intenta nuevamente.';
      case 401:
        return 'Acceso no autorizado. Verifica tu usuario y contrasena.';
      case 404:
        return 'Producto no encontrado.';
      case 429:
        return 'Escaneo muy rápido. Espera un momento y vuelve a intentar.';
      case 503:
        return 'No se pudo consultar la base de datos. Intenta de nuevo.';
      case 504:
        return 'La consulta tardó demasiado. Intenta nuevamente.';
      default:
        return 'Error del servidor (HTTP $status). Intenta nuevamente.';
    }
  }

  Future<void> _buscarRegistroPorCodigo(String codigoBarra) async {
    // ===== CAMBIO: normaliza + prueba candidatos para evitar 404 por UPC/EAN =====
    final candidates = _codigoCandidates(codigoBarra);
    if (candidates.isEmpty) return;

    setState(() {
      _loading = true;
      _sinExistencia = false; // reset
    });

    try {
      List<Map<String, dynamic>> rows = [];

      // Intentar cada candidato hasta conseguir data
      for (final c in candidates) {
        rows = await _fetchProductoTodas(c);
        if (rows.isNotEmpty) break;
      }

      if (rows.isEmpty) {
        // No existe el producto en la consulta
        setState(() {
          _producto = null;
          _stock = [];
          _stockCasaMatriz = [];
          _stockPorRegion = {};
          _totalesPorRegion = {};
          _totalGeneral = 0;
          _totalCasaMatriz = 0;
          _totalTiendas = 0;
          _sinExistencia = true; // mostramos la tarjeta de “sin existencia”
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Código no encontrado')),
          );
        }
        return;
      }

      // Cabecera de producto
      final header = rows.first;

      // Separa Bodegas vs Tiendas y calcula totales
      int total = 0;
      int totalCM = 0;
      final List<Map<String, dynamic>> casaMatriz = [];
      final List<Map<String, dynamic>> tiendas = [];

      for (final r in rows) {
        final ex = _asInt(r['Existencia']);
        total += ex;

        if (_isBodega(r)) {
          totalCM += ex;
          casaMatriz.add(r);
        } else {
          tiendas.add(r);
        }
      }

      // Agrupar solo TIENDAS por región
      final Map<String, List<Map<String, dynamic>>> byRegion = {};
      final Map<String, int> totalsRegion = {};
      for (final r in tiendas) {
        final ex = _asInt(r['Existencia']);
        final regionRaw = _asString(r['Region']);
        final region = regionRaw.isEmpty ? 'Sin región' : regionRaw;

        byRegion.putIfAbsent(region, () => []).add(r);
        totalsRegion.update(region, (old) => old + ex, ifAbsent: () => ex);
      }

      final totalTiendas = total - totalCM;

      // Si NO hay existencias en ninguna parte → mostrar solo mensaje
      if (total == 0) {
        setState(() {
          _producto = null; // no mostramos card de producto
          _stock = [];
          _stockCasaMatriz = [];
          _stockPorRegion = {};
          _totalesPorRegion = {};
          _totalGeneral = 0;
          _totalCasaMatriz = 0;
          _totalTiendas = 0;
          _sinExistencia = true;
        });
      } else {
        setState(() {
          _producto = {
            'CodigoBarra': header['CodigoBarra'],
            'Referencia': header['Referencia'],
            'Nombre': header['Nombre'],
            'PrecioDetal': header['PrecioDetal'],
            'CostoDolar': header['CostoDolar'],
            'PrecioMayor': header['PrecioMayor'],
            'DolarMayor': header['dolarMayor'], // backend: 'dolarMayor'
            'PrecioPromocion': header['PrecioPromocion'],
          };
          _stock = rows;
          _stockCasaMatriz = casaMatriz;
          _stockPorRegion = byRegion;
          _totalesPorRegion = totalsRegion;
          _totalGeneral = total;
          _totalCasaMatriz = totalCM;
          _totalTiendas = totalTiendas;
          _sinExistencia = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
      _searchController.clear();
      _focusNode.requestFocus();
    }
  }

  Future<void> _scanBarcode() async {
    if (isDesktopPlatform) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'En escritorio usa el teclado o un lector USB y presiona Enter.',
          ),
        ),
      );
      _focusNode.requestFocus();
      return;
    }

    try {
      final scanned = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const ScanPage()),
      );
      if (scanned != null && scanned.isNotEmpty) {
        await _buscarRegistroPorCodigo(scanned);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ==== helpers de coerción seguros ====
  int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  String _asString(dynamic v) => (v ?? '').toString().trim();

  @override
  Widget build(BuildContext context) {
    final p = _producto;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: cs.surface.withOpacity(0.98),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const PageStorageKey<String>('consulta-scroll'),
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Título + buscador
              Text(
                'Consulta de precios',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 10),
              _SearchField(
                controller: _searchController,
                focusNode: _focusNode,
                onSearch: () =>
                    _buscarRegistroPorCodigo(_searchController.text),
                onScan: _scanBarcode,
              ),

              const SizedBox(height: 10),

              if (_loading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],

              const SizedBox(height: 18),

              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _TasaCard(
                  fechaOficial: _tasaFechaOficial,
                  fechaMayor: _tasaFechaMayor,
                  tasaOficial: _tasaOficial,
                  tasaMayor: _tasaMayor,
                  isLoading: _loadingTasa,
                  errorMessage: _tasaError,
                  onRetry: _cargarTasa,
                ),
              ),

              // SOLO mensaje cuando no hay existencias
              if (!_loading && _sinExistencia) ...[
                const _SinExistenciaCard(),
              ]
              // Producto + listas + totales cuando sí hay existencias
              else ...[
                // Tasa entre barra de búsqueda y producto (acordeón)
                if (p != null) _ProductoCard(p),
                const SizedBox(height: 16),

                if (_stock.isNotEmpty) ...[
                  // ========== BODEGAS ==========
                  if (_stockCasaMatriz.isNotEmpty) ...[
                    const _SectionHeader(
                      icon: Icons.home_filled,
                      title: 'Bodegas',
                    ),
                    const SizedBox(height: 8),
                    ..._stockCasaMatriz.map((r) {
                      final tienda = _asString(r['Tienda']);
                      final existencia = _asInt(r['Existencia']);
                      final status = r['Status'];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _StockTile(
                          tienda: tienda,
                          existencia: existencia,
                          status: status,
                          isCasaMatriz: true,
                        ),
                      );
                    }),
                    const SizedBox(height: 12),
                  ],

                  // ========== TIENDAS POR REGIÓN ==========
                  const _SectionHeader(
                    icon: Icons.map_rounded,
                    title: 'Existencia por región (tiendas)',
                  ),
                  const SizedBox(height: 8),

                  _RegionGroups(
                    stockPorRegion: _stockPorRegion,
                    totalesPorRegion: _totalesPorRegion,
                    asInt: _asInt,
                    asString: _asString,
                  ),

                  const SizedBox(height: 14),

                  // ========== TOTALES ==========
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TotalTile(
                        label: 'Total Bodegas',
                        total: _totalCasaMatriz,
                        color: Colors.indigo,
                      ),
                      const SizedBox(height: 10),
                      _TotalTile(
                        label: 'Total Tiendas',
                        total: _totalTiendas,
                        color: Colors.deepPurple,
                      ),
                      const SizedBox(height: 10),
                      _TotalTile(
                        label: 'Total General',
                        total: _totalGeneral,
                        color: Colors.teal,
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RegionGroups extends StatelessWidget {
  final Map<String, List<Map<String, dynamic>>> stockPorRegion;
  final Map<String, int> totalesPorRegion;
  final int Function(dynamic v) asInt;
  final String Function(dynamic v) asString;

  const _RegionGroups({
    required this.stockPorRegion,
    required this.totalesPorRegion,
    required this.asInt,
    required this.asString,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Theme(
      data: theme.copyWith(
        expansionTileTheme: ExpansionTileThemeData(
          backgroundColor: cs.surface,
          collapsedBackgroundColor: cs.surface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          collapsedShape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      ),
      child: Column(
        children: stockPorRegion.entries.map((e) {
          final region = e.key;
          final items = e.value;
          final totalRegion = totalesPorRegion[region] ?? 0;

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                )
              ],
            ),
            child: ExpansionTile(
              key: PageStorageKey<String>('region-$region'),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      region,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _QtyPill(value: totalRegion),
                ],
              ),
              children: items.map((r) {
                final tienda = asString(r['Tienda']);
                final existencia = asInt(r['Existencia']);
                final status = r['Status'];
                return _StockTile(
                  tienda: tienda,
                  existencia: existencia,
                  status: status,
                  isCasaMatriz: false,
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSearch;
  final Future<void> Function() onScan;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onSearch,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))
        ],
      ),
      child: TextField(
        focusNode: focusNode,
        controller: controller,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => onSearch(),
        decoration: InputDecoration(
          hintText: 'Buscar código de barras',
          hintStyle: const TextStyle(color: Colors.black45),
          prefixIcon: IconButton(
            icon: const Icon(Icons.search),
            onPressed: onSearch,
          ),
          suffixIcon: isDesktopPlatform
              ? null
              : IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: onScan,
                  tooltip: 'Escanear',
                ),
          filled: true,
          fillColor: cs.surface,
          border: OutlineInputBorder(
            borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.4)),
            borderRadius: BorderRadius.circular(14),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide:
                BorderSide(color: cs.primary.withOpacity(0.6), width: 1.4),
            borderRadius: BorderRadius.circular(14),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: cs.outlineVariant.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(14),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: cs.primary.withOpacity(.1),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: cs.primary, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Divider(
            thickness: 1,
            color: cs.outlineVariant.withOpacity(0.4),
          ),
        ),
      ],
    );
  }
}

class _ProductoCard extends StatelessWidget {
  final Map<String, dynamic> p;
  const _ProductoCard(this.p);

  String _val(String k) => (p[k] ?? '').toString();
  String _valOrZero(String k) {
    final s = _val(k).trim();
    return s.isEmpty ? '0' : s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final detal = _valOrZero('PrecioDetal');
    final dolarDetal = _val('CostoDolar');
    final mayor = _valOrZero('PrecioMayor');
    final dolarMayor = _val('DolarMayor'); // viene de 'dolarMayor' en backend
    final promo = _valOrZero('PrecioPromocion');

    bool has(String s) => s.isNotEmpty && s != '0' && s != '0.0' && s != '0.00';

    final detalLine = has(dolarDetal)
        ? 'Detal: $detal Bs - Dolar: $dolarDetal'
        : 'Detal: $detal Bs';
    final mayorLine = has(dolarMayor)
        ? 'Mayor: $mayor Bs - Dolar mayor: $dolarMayor'
        : 'Mayor: $mayor Bs';

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _val('Nombre'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.qr_code_2, size: 16, color: Colors.black45),
                const SizedBox(width: 6),
                Text(
                  'Código: ${_val('CodigoBarra')}',
                  style: const TextStyle(color: Colors.black87),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.tag, size: 16, color: Colors.black45),
                const SizedBox(width: 6),
                Text(
                  'Referencia: ${_val('Referencia')}',
                  style: const TextStyle(color: Colors.black87),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                _PricePill(text: detalLine),
                _PricePill(text: mayorLine),
                _PricePill(text: 'Promo: $promo Bs'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Tarjeta para Tasa de Cambio (ACORDEÓN, con fecha por cada tasa)
class _TasaCard extends StatelessWidget {
  final String? fechaOficial;
  final String? fechaMayor;
  final double? tasaOficial;
  final double? tasaMayor;
  final bool isLoading;
  final String? errorMessage;
  final Future<void> Function() onRetry;

  const _TasaCard({
    required this.fechaOficial,
    required this.fechaMayor,
    required this.tasaOficial,
    this.tasaMayor,
    required this.isLoading,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withOpacity(0.25)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const PageStorageKey<String>('consulta-tasa-card'),
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Row(
            children: const [
              Icon(Icons.attach_money, size: 22),
              SizedBox(width: 8),
              Text(
                'Tasa del dia',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          children: [
            if (isLoading && tasaOficial == null) ...[
              Row(
                children: const [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Cargando tasa del dia...',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ] else if (tasaOficial != null) ...[
              Row(
                children: [
                  Text(
                    'Oficial: ${tasaOficial!.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (fechaOficial != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      fechaOficial!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              if (tasaMayor != null)
                Row(
                  children: [
                    Text(
                      'Mayorista: ${tasaMayor!.toStringAsFixed(2)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    if (fechaMayor != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        fechaMayor!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ],
                ),
            ] else ...[
              const Text(
                'La tasa no esta disponible por ahora.',
                style: TextStyle(fontSize: 13),
              ),
            ],
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage!,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => onRetry(),
                icon: const Icon(Icons.refresh),
                label: const Text('Actualizar'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PricePill extends StatelessWidget {
  final String text;
  const _PricePill({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.primary.withOpacity(.15)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: cs.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StockTile extends StatelessWidget {
  final String tienda;
  final int existencia;
  final dynamic status;
  final bool isCasaMatriz;
  const _StockTile({
    required this.tienda,
    required this.existencia,
    required this.status,
    this.isCasaMatriz = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isCasaMatriz
        ? Colors.amber.shade100
        : cs.surfaceVariant.withOpacity(.4);
    final icon = isCasaMatriz ? Icons.home_filled : Icons.storefront;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: Colors.white,
          child: Icon(icon, size: 18, color: Colors.black54),
        ),
        title: Text(
          tienda,
          style: const TextStyle(fontWeight: FontWeight.w700),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _QtyPill(value: existencia),
            const SizedBox(width: 8),
            _StatusPill(status: status),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _QtyPill extends StatelessWidget {
  final int value;
  const _QtyPill({required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primary.withOpacity(0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$value',
        style: TextStyle(
          color: cs.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: .2,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final dynamic status;
  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final raw = (status ?? '').toString().trim();
    final hasStatus = raw.isNotEmpty;
    final normalized = raw.toLowerCase();
    final isActive =
        normalized == '1' || normalized == 'true' || normalized == 'activo';
    final label = !hasStatus
        ? 'Sin estado'
        : isActive
            ? 'Activo'
            : 'Inactivo';
    final bgColor = !hasStatus
        ? cs.surfaceVariant.withOpacity(0.65)
        : isActive
            ? Colors.green.withOpacity(0.14)
            : Colors.red.withOpacity(0.12);
    final textColor = !hasStatus
        ? cs.onSurfaceVariant
        : isActive
            ? Colors.green.shade800
            : Colors.red.shade800;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w800,
          letterSpacing: .1,
        ),
      ),
    );
  }
}

class _TotalTile extends StatelessWidget {
  final String label;
  final int total;
  final Color color;
  const _TotalTile(
      {required this.label, required this.total, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [color.withOpacity(.95), color.withOpacity(.80)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            '$total',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

// Mensaje cuando no hay existencias en ninguna parte
class _SinExistenciaCard extends StatelessWidget {
  const _SinExistenciaCard();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: Row(
        children: const [
          Icon(Icons.info_outline),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Sin existencia en ninguna sucursal ni bodega.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// ==============
///  ScanPage
/// ==============
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _handled = false;
  bool _startingScanner = true;
  String? _cameraNotice;

  // ===== NUEVO: estabilidad para evitar códigos “inventados” =====
  String? _lastValue;
  int _stableHits = 0;
  DateTime? _lastSeen;

  @override
  void initState() {
    super.initState();
    unawaited(_startScanner());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _startScanner({bool clearNotice = false}) async {
    if (mounted) {
      setState(() {
        _startingScanner = true;
        if (clearNotice) {
          _cameraNotice = null;
        }
      });
    }

    final notice = await startScannerWithFallback(controller);

    if (!mounted) return;
    setState(() {
      _startingScanner = false;
      _cameraNotice = notice;
    });
  }

  // ===== NUEVO: helpers para filtrar/validar EAN-13 y UPC-A =====
  String _onlyDigits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  bool _isValidEan13(String digits13) {
    if (digits13.length != 13) return false;
    if (!RegExp(r'^\d{13}$').hasMatch(digits13)) return false;

    int sum = 0;
    // posiciones 1..12 (0..11)
    for (int i = 0; i < 12; i++) {
      final d = digits13.codeUnitAt(i) - 48;
      // EAN-13: posiciones pares (2,4,6,...) multiplican por 3
      sum += (i % 2 == 0) ? d : (d * 3);
    }
    final mod = sum % 10;
    final check = (10 - mod) % 10;
    final last = digits13.codeUnitAt(12) - 48;
    return check == last;
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;

    // 1) Elegir el mejor candidato: dígitos + longitud 12/13 + checksum válido
    String? candidate;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null || raw.isEmpty) continue;

      final digits = _onlyDigits(raw);
      if (digits.length == 13) {
        if (_isValidEan13(digits)) {
          candidate = digits;
          break;
        }
      } else if (digits.length == 12) {
        // UPC-A: validar como EAN-13 con prefijo 0
        final ean13 = '0$digits';
        if (_isValidEan13(ean13)) {
          // Devuelve el UPC-A en 12 (tu lógica de normalización lo maneja)
          candidate = digits;
          break;
        }
      }
    }

    // si no hay un candidato confiable, no hacemos nada
    if (candidate == null) return;

    // 2) Estabilidad: exigir 2 lecturas iguales seguidas dentro de 800ms
    final now = DateTime.now();
    final lastSeen = _lastSeen;

    final withinWindow = lastSeen != null &&
        now.difference(lastSeen) < const Duration(milliseconds: 1500);

    if (_lastValue == candidate && withinWindow) {
      _stableHits++;
    } else {
      _stableHits = 1;
      _lastValue = candidate;
    }
    _lastSeen = now;

    if (_stableHits >= 2) {
      _handled = true;
      Navigator.of(context).pop(candidate);
    }
  }

  @override
  Widget build(BuildContext context) {
    const double scanSize = 260.0; // mismo tamaño que el recuadro

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Escanear código'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: _startingScanner
                ? null
                : () async {
                    await controller.switchCamera();
                    if (!mounted) return;
                    setState(() {
                      _cameraNotice = null;
                    });
                  },
            tooltip: 'Cambiar cámara',
          ),
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => controller.toggleTorch(),
            tooltip: 'Linterna',
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;

          // Ventana de escaneo centrada (solo aquí detecta)
          final scanWindow = Rect.fromCenter(
            center: Offset(size.width / 2, size.height / 2),
            width: scanSize,
            height: scanSize,
          );

          return Stack(
            children: [
              MobileScanner(
                controller: controller,
                onDetect: _onDetect,
                errorBuilder: (context, error, child) => ScannerErrorView(
                  error: error,
                  onRetry: () => _startScanner(clearNotice: true),
                ),
                scanWindow: scanWindow, // <-- limita detección al recuadro
              ),
              if (_startingScanner)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              Align(
                alignment: Alignment.center,
                child: Container(
                  width: scanSize,
                  height: scanSize,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (_cameraNotice != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _cameraNotice!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

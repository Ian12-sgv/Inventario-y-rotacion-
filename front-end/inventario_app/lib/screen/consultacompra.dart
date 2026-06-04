// lib/screen/consultacompra.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;

import '../app_session.dart';
import '../platform_support.dart';
import '../scanner_support.dart';

// ===== Config de API (se puede sobreescribir con --dart-define) =====
const String kComprasApiBase = String.fromEnvironment('COMPRAS_API_BASE',
    defaultValue: 'https://api3.apipalacio.com');

class ScreenCompras extends StatefulWidget {
  const ScreenCompras({
    super.key,
    required this.session,
  });

  final AppSession session;

  @override
  State<ScreenCompras> createState() => _ScreenComprasState();
}

class _ScreenComprasState extends State<ScreenCompras> {
  final TextEditingController _searchController = TextEditingController();
  bool _loading = false;

  List<Map<String, dynamic>> _registros = [];
  int _totalCantidad = 0;

  Future<List<Map<String, dynamic>>> _fetchComprasPorCodigo(
      String codigo) async {
    final uri = Uri.parse('$kComprasApiBase/api/productos/$codigo');
    final resp = await http.get(uri, headers: widget.session.authHeaders);

    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body);
      // El backend podría devolver una LISTA (ideal) o un OBJETO (fila única).
      if (body is List) {
        return body.whereType<Map>().cast<Map<String, dynamic>>().toList();
      } else if (body is Map<String, dynamic>) {
        return [body];
      } else {
        throw Exception('Respuesta inesperada del servidor.');
      }
    }

    if (resp.statusCode == 404) {
      return []; // no encontrado
    }

    Object? parsedBody;
    try {
      parsedBody = jsonDecode(resp.body);
    } catch (_) {}

    if (parsedBody is Map<String, dynamic>) {
      final error = (parsedBody['error'] ?? '').toString();
      if (error == 'invalid_credentials' || error == 'invalid_api_key') {
        throw Exception(
            'Acceso no autorizado. Verifica tu usuario y contrasena.');
      }

      final title = (parsedBody['title'] ?? '').toString();
      final detail = (parsedBody['detail'] ?? '').toString();
      if (title.isNotEmpty || detail.isNotEmpty) {
        final prefix = title.isNotEmpty ? '$title: ' : '';
        throw Exception(
            '${prefix}${detail.isNotEmpty ? detail : 'Fallo en la solicitud.'}');
      }
    }

    if (resp.statusCode == 401) {
      throw Exception(
          'Acceso no autorizado. Verifica tu usuario y contrasena.');
    }

    throw Exception('HTTP ${resp.statusCode}: ${resp.reasonPhrase}');
  }

  Future<void> _buscarRegistrosPorCodigo(String codigoBarra) async {
    final code = codigoBarra.trim();
    if (code.isEmpty) return;

    setState(() => _loading = true);
    try {
      final result = await _fetchComprasPorCodigo(code);

      // Ordena (si vienen varios): FechaCompra DESC, Documento ASC
      result.sort((a, b) {
        int byFecha = _compareFechaDesc(a['FechaCompra'], b['FechaCompra']);
        if (byFecha != 0) return byFecha;
        return _asString(a['Documento']).compareTo(_asString(b['Documento']));
      });

      final total = result.fold<int>(
        0,
        (sum, r) => sum + _asInt(r['Cantidad']),
      );

      setState(() {
        _registros = result;
        _totalCantidad = total;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _searchController.clear();
      }
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
      return;
    }

    try {
      final scanned = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const ScanPage()),
      );
      if (scanned != null && scanned.isNotEmpty) {
        await _buscarRegistrosPorCodigo(scanned);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  // ===== Helpers =====
  int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is double) return v.round();
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  String _asString(dynamic v) => (v ?? '').toString().trim();

  int _compareFechaDesc(dynamic a, dynamic b) {
    final sa = _asString(a);
    final sb = _asString(b);
    final da = DateTime.tryParse(sa);
    final db = DateTime.tryParse(sb);
    if (da == null && db == null) return 0;
    if (da == null) return 1; // nulos van después
    if (db == null) return -1;
    return db.compareTo(da); // DESC
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface.withOpacity(0.98),
      body: SafeArea(
        child: Column(
          children: [
            // Buscador
            Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: BoxDecoration(
                  color: cs.surface,
                  border: Border.all(color: cs.outlineVariant.withOpacity(.3)),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 6,
                        offset: Offset(0, 3))
                  ],
                ),
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => _buscarRegistrosPorCodigo(v),
                  decoration: InputDecoration(
                    hintText: 'Buscar código de barras',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    border: InputBorder.none,
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: () =>
                              _buscarRegistrosPorCodigo(_searchController.text),
                        ),
                        if (!isDesktopPlatform)
                          IconButton(
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: _scanBarcode,
                            tooltip: 'Escanear',
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: CircularProgressIndicator(),
              ),

            // Resumen
            if (!_loading && _registros.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text('Resultados: ${_registros.length}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('Total Cant.: $_totalCantidad',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),

            const SizedBox(height: 8),

            Expanded(child: _buildListaDeResultados(cs)),
          ],
        ),
      ),
    );
  }

  // UI: lista de resultados
  Widget _buildListaDeResultados(ColorScheme cs) {
    if (_loading) {
      return const SizedBox.shrink();
    }
    if (_registros.isEmpty) {
      return const Center(
        child: Text('No se encontraron resultados.',
            style: TextStyle(fontSize: 16, color: Colors.grey)),
      );
    }

    return ListView.builder(
      itemCount: _registros.length,
      itemBuilder: (context, index) {
        final r = _registros[index];
        final doc = _asString(r['Documento']);
        final cant = _asInt(r['Cantidad']);
        final fecha = _asString(r['FechaCompra']);

        return Card(
          elevation: 0.5,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildRegistroCabecera('Grupo Palacios', doc),
                const Divider(),
                _buildRegistroDetalle(
                    Icons.qr_code, 'Código', _asString(r['CodigoBarra'])),
                _buildRegistroDetalle(
                    Icons.article, 'Referencia', _asString(r['Referencia'])),
                _buildRegistroDetalle(
                    Icons.label, 'Nombre', _asString(r['Nombre'])),
                _buildRegistroDetalle(Icons.shopping_cart, 'Cantidad', '$cant'),
                _buildRegistroDetalle(Icons.date_range, 'Fecha Compra', fecha),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRegistroCabecera(String galpon, String documento) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(galpon,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF646464))),
        Text('Doc: $documento',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500, color: Colors.grey)),
      ],
    );
  }

  Widget _buildRegistroDetalle(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.blueGrey),
          const SizedBox(width: 10),
          Text('$label:',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

/// =======================
///   ScanPage embebida
/// =======================
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final MobileScannerController controller = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _handled = false;
  bool _startingScanner = true;
  String? _cameraNotice;

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

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final raw = barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;

    _handled = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
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
              tooltip: 'Cambiar cámara'),
          IconButton(
              icon: const Icon(Icons.flash_on),
              onPressed: () => controller.toggleTorch(),
              tooltip: 'Linterna'),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: controller,
            onDetect: _onDetect,
            errorBuilder: (context, error, child) => ScannerErrorView(
              error: error,
              onRetry: () => _startScanner(clearNotice: true),
            ),
          ),
          if (_startingScanner)
            const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 260,
              height: 260,
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
      ),
    );
  }
}

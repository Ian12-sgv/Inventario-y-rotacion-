// lib/screen/consultaprecio.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;

// ===== Config API =====
// Puedes inyectar por --dart-define (recomendado) y dejar estos como fallback.
const String kApiBase =
    String.fromEnvironment('API_BASE', defaultValue: 'https://api2.apipalacio.com');
const String kApiKey =
    String.fromEnvironment('API_KEY', defaultValue: 'k9mWIm4Nd3j9KomxkT28cBqJY4eYeWm58X+Fmp1Kq0g=');

class ScreenConsulta extends StatefulWidget {
  const ScreenConsulta({super.key});
  @override
  State<ScreenConsulta> createState() => _ScreenConsultaState();
}

class _ScreenConsultaState extends State<ScreenConsulta> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  Map<String, dynamic>? _producto;

  // Lista completa (para decidir si hay datos)
  List<Map<String, dynamic>> _stock = [];

  // Casa Matriz (se muestra aparte)
  List<Map<String, dynamic>> _stockCasaMatriz = [];

  // Agrupado por región (solo TIENDAS, sin Casa Matriz)
  Map<String, List<Map<String, dynamic>>> _stockPorRegion = {};
  Map<String, int> _totalesPorRegion = {};

  int _totalGeneral = 0;
  int _totalCasaMatriz = 0;
  int _totalTiendas = 0;

  bool _loading = false;

  bool _isCasaMatriz(String tienda) {
    final t = tienda.toLowerCase();
    return t.contains('casa matriz') || t.contains('matriz') || t.contains('principal');
  }

  Future<List<Map<String, dynamic>>> _fetchProductoTodas(String codigo) async {
    final uri = Uri.parse('$kApiBase/api/productos/$codigo/todas');
    final resp = await http.get(uri, headers: {'x-api-key': kApiKey});

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body);
      if (data is List) {
        // Filtra filas de totales (si el backend las incluye al final)
        return data
            .whereType<Map>()
            .cast<Map<String, dynamic>>()
            .where((m) {
              final tienda = (m['Tienda'] ?? '').toString().toUpperCase();
              return !(tienda.startsWith('TOTAL '));
            })
            .toList();
      }
      throw Exception('Respuesta inesperada del servidor.');
    }

    if (resp.statusCode == 404) {
      return []; // no encontrado
    }

    // Intenta leer ProblemDetails
    try {
      final p = jsonDecode(resp.body);
      final title = p['title'] ?? 'Error';
      final detail = p['detail'] ?? 'Fallo en la solicitud.';
      throw Exception('$title: $detail');
    } catch (_) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.reasonPhrase}');
    }
  }

  Future<void> _buscarRegistroPorCodigo(String codigoBarra) async {
    final code = codigoBarra.trim();
    if (code.isEmpty) return;

    setState(() => _loading = true);
    try {
      final rows = await _fetchProductoTodas(code);

      if (rows.isEmpty) {
        setState(() {
          _producto = null;
          _stock = [];
          _stockCasaMatriz = [];
          _stockPorRegion = {};
          _totalesPorRegion = {};
          _totalGeneral = 0;
          _totalCasaMatriz = 0;
          _totalTiendas = 0;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Código no encontrado')),
          );
        }
        return;
      }

      // La primera fila sirve como "cabecera" de producto
      final header = rows.first;

      // Separa Casa Matriz vs Tiendas y calcula totales
      int total = 0;
      int totalCM = 0;
      final List<Map<String, dynamic>> casaMatriz = [];
      final List<Map<String, dynamic>> tiendas = [];

      for (final r in rows) {
        final ex = _asInt(r['Existencia']);
        final tienda = _asString(r['Tienda']);
        total += ex;

        if (_isCasaMatriz(tienda)) {
          totalCM += ex;
          casaMatriz.add(r);
        } else {
          tiendas.add(r);
        }
      }

      // Agrupar solo tiendas por región
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

      setState(() {
        _producto = {
          'CodigoBarra': header['CodigoBarra'],
          'Referencia': header['Referencia'],
          'Nombre': header['Nombre'],
          'PrecioDetal': header['PrecioDetal'],
          'CostoDolar': header['CostoDolar'],
          'PrecioMayor': header['PrecioMayor'],
          'DolarMayor': header['dolarMayor'], // ojo: backend la envía como 'dolarMayor'
          'PrecioPromocion': header['PrecioPromocion'],
        };
        _stock = rows;
        _stockCasaMatriz = casaMatriz;
        _stockPorRegion = byRegion;
        _totalesPorRegion = totalsRegion;
        _totalGeneral = total;
        _totalCasaMatriz = totalCM;
        _totalTiendas = totalTiendas;
      });
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

  // Scan con mobile_scanner
  Future<void> _scanBarcode() async {
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
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Título + buscador
              Text('Consulta de precios',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  )),
              const SizedBox(height: 10),
              _SearchField(
                controller: _searchController,
                focusNode: _focusNode,
                onSearch: () => _buscarRegistroPorCodigo(_searchController.text),
                onScan: _scanBarcode,
              ),

              if (_loading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],

              const SizedBox(height: 18),

              // Producto + precios
              if (!_loading && p != null) _ProductoCard(p),

              const SizedBox(height: 16),

              if (!_loading && _stock.isNotEmpty) ...[
                // ========== CASA MATRIZ (fuera del agrupado) ==========
                if (_stockCasaMatriz.isNotEmpty) ...[
                  const _SectionHeader(
                    icon: Icons.home_filled,
                    title: 'Casa Matriz',
                  ),
                  const SizedBox(height: 8),
                  ..._stockCasaMatriz.map((r) {
                    final tienda = _asString(r['Tienda']);
                    final existencia = _asInt(r['Existencia']);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _StockTile(
                        tienda: tienda,
                        existencia: existencia,
                        isCasaMatriz: true,
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                ],

                // ========== TIENDAS AGRUPADAS POR REGIÓN ==========
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
                        label: 'Total Casa Matriz',
                        total: _totalCasaMatriz,
                        color: Colors.indigo),
                    const SizedBox(height: 10),
                    _TotalTile(
                        label: 'Total Tiendas',
                        total: _totalTiendas,
                        color: Colors.deepPurple),
                    const SizedBox(height: 10),
                    _TotalTile(
                        label: 'Total General',
                        total: _totalGeneral,
                        color: Colors.teal),
                  ],
                ),
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                return _StockTile(
                  tienda: tienda,
                  existencia: existencia,
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
          suffixIcon: IconButton(
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

    bool has(String s) =>
        s.isNotEmpty && s != '0' && s != '0.0' && s != '0.00';

    final detalLine =
        has(dolarDetal) ? 'Detal: $detal Bs - Dolar: $dolarDetal' : 'Detal: $detal Bs';
    final mayorLine =
        has(dolarMayor) ? 'Mayor: $mayor Bs - Dolar mayor: $dolarMayor' : 'Mayor: $mayor Bs';

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))],
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
                Text('Código: ${_val('CodigoBarra')}',
                    style: const TextStyle(color: Colors.black87)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.tag, size: 16, color: Colors.black45),
                const SizedBox(width: 6),
                Text('Referencia: ${_val('Referencia')}',
                    style: const TextStyle(color: Colors.black87)),
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
  final bool isCasaMatriz;
  const _StockTile({
    required this.tienda,
    required this.existencia,
    this.isCasaMatriz = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg =
        isCasaMatriz ? Colors.amber.shade100 : cs.surfaceVariant.withOpacity(.4);
    final icon = isCasaMatriz ? Icons.home_filled : Icons.storefront;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        dense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
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
        trailing: _QtyPill(value: existencia),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
        'x$value',
        style: TextStyle(
          color: cs.primary,
          fontWeight: FontWeight.w800,
          letterSpacing: .2,
        ),
      ),
    );
  }
}

class _TotalTile extends StatelessWidget {
  final String label;
  final int total;
  final Color color;
  const _TotalTile({required this.label, required this.total, required this.color});

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
              style:
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          Text('$total',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
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
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _handled = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final codes = capture.barcodes;
    final raw = (codes.isNotEmpty ? codes.first.rawValue : null);
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
              onPressed: () => controller.switchCamera(),
              tooltip: 'Cambiar cámara'),
          IconButton(
              icon: const Icon(Icons.flash_on),
              onPressed: () => controller.toggleTorch(),
              tooltip: 'Linterna'),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: controller, onDetect: _onDetect),
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
        ],
      ),
    );
  }
}

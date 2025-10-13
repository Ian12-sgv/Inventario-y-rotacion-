import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';
import '../database.dart';

class ScreenConsulta extends StatefulWidget {
  const ScreenConsulta({super.key});
  @override
  State<ScreenConsulta> createState() => _ScreenConsultaState();
}

class _ScreenConsultaState extends State<ScreenConsulta> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  Map<String, dynamic>? _producto;
  // Lista plana (por compatibilidad si la necesitas luego)
  List<Map<String, dynamic>> _stock = [];

  // Agrupado por región
  Map<String, List<Map<String, dynamic>>> _stockPorRegion = {};
  Map<String, int> _totalesPorRegion = {};

  int _totalGeneral = 0;
  int _totalCasaMatriz = 0;
  int _totalTiendas = 0;

  bool _isCasaMatriz(String tienda) {
    final t = (tienda).toLowerCase();
    return RegExp(r'\bcasa\s*matriz\b', caseSensitive: false).hasMatch(t);
  }

  Future<void> _buscarRegistroPorCodigo(String codigoBarra) async {
    final code = codigoBarra.trim();
    if (code.isEmpty) return;

    final Database db = await openDatabaseConnection();

    // Producto (inventarioc): ahora incluye CostoDolar y DolarMayor
    final prod = await db.query(
      'inventarioc',
      where: 'CodigoBarra = ?',
      whereArgs: [code],
      limit: 1,
    );

    // Stock dinámico (tienda / region / existencia)
    final stk = await db.query(
      'stock',
      columns: ['Tienda', 'Region', 'Existencia'],
      where: 'CodigoBarra = ?',
      whereArgs: [code],
      orderBy: 'Region COLLATE NOCASE ASC, Tienda COLLATE NOCASE ASC',
    );

    // Totales y agrupación por región
    int total = 0;
    int totalCM = 0;
    final Map<String, List<Map<String, dynamic>>> byRegion = {};
    final Map<String, int> totalsRegion = {};

    for (final r in stk) {
      final ex = (r['Existencia'] as int?) ?? 0;
      final tienda = (r['Tienda'] as String?) ?? '';
      final regionRaw = (r['Region'] as String?) ?? '';
      final region = regionRaw.trim().isEmpty ? 'Sin región' : regionRaw.trim();

      total += ex;
      if (_isCasaMatriz(tienda)) totalCM += ex;

      byRegion.putIfAbsent(region, () => []).add(r);
      totalsRegion.update(region, (old) => old + ex, ifAbsent: () => ex);
    }

    final totalOtras = total - totalCM;

    setState(() {
      _producto = prod.isNotEmpty ? prod.first : null;
      _stock = stk;
      _stockPorRegion = byRegion;
      _totalesPorRegion = totalsRegion;
      _totalGeneral = total;
      _totalCasaMatriz = totalCM;
      _totalTiendas = totalOtras;
    });

    _searchController.clear();
    _focusNode.requestFocus();

    if (_producto == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Código no encontrado')),
      );
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

  String _val(Map<String, dynamic> map, String k) => (map[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final p = _producto;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Buscador
            Container(
              decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 3))],
              ),
              child: TextField(
                focusNode: _focusNode,
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: 'Buscar código de barras',
                  prefixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () => _buscarRegistroPorCodigo(_searchController.text),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_scanner),
                    onPressed: _scanBarcode,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                ),
                onSubmitted: (v) => _buscarRegistroPorCodigo(v),
              ),
            ),
            const SizedBox(height: 20),

            // Producto + precios
            if (p != null) _ProductoCard(p),

            const SizedBox(height: 16),

            // Existencia agrupada por región
            if (_stock.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Existencia por región', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),

                  ..._stockPorRegion.entries.map((e) {
                    final region = e.key;
                    final items = e.value;
                    final totalRegion = _totalesPorRegion[region] ?? 0;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.white, borderRadius: BorderRadius.circular(12),
                        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))],
                      ),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                        title: Text('$region — $totalRegion', style: const TextStyle(fontWeight: FontWeight.w700)),
                        childrenPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        children: items.map((r) {
                          final tienda = '${r['Tienda'] ?? ''}';
                          final existencia = (r['Existencia'] as int?) ?? 0;
                          final esCM = _isCasaMatriz(tienda);
                          return _StockTile(
                            tienda: tienda,
                            existencia: existencia,
                            isCasaMatriz: esCM,
                          );
                        }).toList(),
                      ),
                    );
                  }),

                  const SizedBox(height: 12),

                  // TOTALES
                  _TotalTile(label: 'Total Casa Matriz', total: _totalCasaMatriz, color: Colors.indigo),
                  const SizedBox(height: 8),
                  _TotalTile(label: 'Total Tiendas', total: _totalTiendas, color: Colors.deepPurple),
                  const SizedBox(height: 8),
                  _TotalTile(label: 'Total General', total: _totalGeneral, color: Colors.teal),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ProductoCard extends StatelessWidget {
  final Map<String, dynamic> p;
  const _ProductoCard(this.p);

  String _val(String k) => (p[k] ?? '').toString();
  String _valOrZero(String k) {
    final s = _val(k).trim();
    return s.isEmpty ? '0' : s; // si viene vacío, mostramos 0
  }

  @override
  Widget build(BuildContext context) {
    // Valores (texto o número del SQLite)
    final detal      = _valOrZero('PrecioDetal');
    final dolarDetal = _val('CostoDolar');   // dólar detal (opcional)
    final mayor      = _valOrZero('PrecioMayor');
    final dolarMayor = _val('DolarMayor');   // dólar mayor (opcional)
    final promo      = _valOrZero('PrecioPromocion'); // siempre mostrar

    bool _has(String s) =>
        s.isNotEmpty && s != '0' && s != '0.0' && s != '0.00';

    final detalLine = _has(dolarDetal)
        ? 'Detal: $detal Bs - Dolar: $dolarDetal'
        : 'Detal: $detal Bs';

    final mayorLine = _has(dolarMayor)
        ? 'Mayor: $mayor Bs - Dolar mayor: $dolarMayor'
        : 'Mayor: $mayor Bs';

    return Card(
      elevation: 0.5,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_val('Nombre'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Código: ${_val('CodigoBarra')}'),
            Text('Referencia: ${_val('Referencia')}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                Text(detalLine),
                Text(mayorLine),
                Text('Promo: $promo Bs'), // siempre se muestra (con 0 si aplica)
              ],
            ),
          ],
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
    final bg = isCasaMatriz ? Colors.amber.shade100 : Colors.grey.shade100;
    final icon = isCasaMatriz ? Icons.home_filled : Icons.storefront;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: bg, borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.black54),
          const SizedBox(width: 8),
          Expanded(child: Text(tienda, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text('x$existencia', style: const TextStyle(fontSize: 16)),
        ],
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          Text('$total', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
    final raw = capture.barcodes.firstOrNull?.rawValue;
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
          IconButton(icon: const Icon(Icons.cameraswitch), onPressed: () => controller.switchCamera(), tooltip: 'Cambiar cámara'),
          IconButton(icon: const Icon(Icons.flash_on), onPressed: () => controller.toggleTorch(), tooltip: 'Linterna'),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: 260, height: 260,
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

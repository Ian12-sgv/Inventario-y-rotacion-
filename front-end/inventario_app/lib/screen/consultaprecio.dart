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
  List<Map<String, dynamic>> _stock = [];
  int _totalGeneral = 0;

  Future<void> _buscarRegistroPorCodigo(String codigoBarra) async {
    final code = codigoBarra.trim();
    if (code.isEmpty) return;

    final Database db = await openDatabaseConnection();

    // Producto (inventarioc)
    final prod = await db.query(
      'inventarioc',
      where: 'CodigoBarra = ?',
      whereArgs: [code],
      limit: 1,
    );

    // Stock dinámico (tienda / existencia)
    final stk = await db.query(
      'stock',
      columns: ['Tienda', 'Existencia'],
      where: 'CodigoBarra = ?',
      whereArgs: [code],
      orderBy: 'Tienda COLLATE NOCASE ASC',
    );

    final total = stk.fold<int>(0, (sum, r) => sum + (r['Existencia'] as int? ?? 0));

    setState(() {
      _producto = prod.isNotEmpty ? prod.first : null;
      _stock = stk;
      _totalGeneral = total;
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

  @override
  Widget build(BuildContext context) {
    final p = _producto;

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
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

            if (p != null) _ProductoCard(p),

            const SizedBox(height: 16),

            if (_stock.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Existencia por tienda', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._stock.map((r) => _StockTile(tienda: '${r['Tienda']}', existencia: (r['Existencia'] as int?) ?? 0)),
                  const SizedBox(height: 8),
                  _TotalTile(total: _totalGeneral),
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

  @override
  Widget build(BuildContext context) {
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
                Text('Detal: ${_val('PrecioDetal')}'),
                Text('Mayor: ${_val('PrecioMayor')}'),
                Text('Promo: ${_val('PrecioPromocion')}'),
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
  const _StockTile({required this.tienda, required this.existencia});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade100, borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(child: Text(tienda, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text('x$existencia', style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}

class _TotalTile extends StatelessWidget {
  final int total;
  const _TotalTile({required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.teal, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Total General', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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

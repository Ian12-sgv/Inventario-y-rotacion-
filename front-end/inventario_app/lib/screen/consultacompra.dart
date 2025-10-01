import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:sqflite/sqflite.dart';

import '../database.dart'; // usa la conexión central (no recrea tablas aquí)

class ScreenCompras extends StatefulWidget {
  const ScreenCompras({super.key});

  @override
  State<ScreenCompras> createState() => _ScreenComprasState();
}

class _ScreenComprasState extends State<ScreenCompras> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _registros = [];
  int _totalCantidad = 0;

  Future<void> _buscarRegistrosPorCodigo(String codigoBarra) async {
    final code = codigoBarra.trim();
    if (code.isEmpty) return;

    final Database db = await openDatabaseConnection();

    final result = await db.query(
      'comprasgalpones',
      where: 'CodigoBarra = ?',
      whereArgs: [code],
      orderBy: 'FechaCompra DESC, Documento ASC',
    );

    final total = result.fold<int>(
      0,
      (sum, r) => sum + (r['Cantidad'] is int ? r['Cantidad'] as int : int.tryParse('${r['Cantidad']}') ?? 0),
    );

    setState(() {
      _registros = result;
      _totalCantidad = total;
    });

    _searchController.clear();
  }

  // Escaneo con mobile_scanner
  Future<void> _scanBarcode() async {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: 'Buscar código de barras',
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: InputBorder.none,
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.search),
                        onPressed: () => _buscarRegistrosPorCodigo(_searchController.text),
                      ),
                      IconButton(
                        icon: const Icon(Icons.qr_code_scanner),
                        onPressed: _scanBarcode,
                      ),
                    ],
                  ),
                ),
                onSubmitted: (v) => _buscarRegistrosPorCodigo(v),
              ),
            ),
          ),

          // Resumen
          if (_registros.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('Resultados: ${_registros.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('Total Cant.: $_totalCantidad', style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),

          const SizedBox(height: 8),

          Expanded(child: _buildListaDeResultados()),
        ],
      ),
    );
  }

  // UI: lista de resultados
  Widget _buildListaDeResultados() {
    if (_registros.isEmpty) {
      return const Center(
        child: Text('No se encontraron resultados.', style: TextStyle(fontSize: 16, color: Colors.grey)),
      );
    }

    return ListView.builder(
      itemCount: _registros.length,
      itemBuilder: (context, index) {
        final r = _registros[index];
        final doc = '${r['Documento'] ?? ''}';
        final cant = r['Cantidad'] is int ? r['Cantidad'] as int : int.tryParse('${r['Cantidad']}') ?? 0;
        final fecha = '${r['FechaCompra'] ?? ''}';

        return Card(
          elevation: 0.5,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildRegistroCabecera('Grupo Palacios', doc),
                const Divider(),
                _buildRegistroDetalle(Icons.qr_code, 'Código', '${r['CodigoBarra'] ?? ''}'),
                _buildRegistroDetalle(Icons.article, 'Referencia', '${r['Referencia'] ?? ''}'),
                _buildRegistroDetalle(Icons.label, 'Nombre', '${r['Nombre'] ?? ''}'),
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
        Text(galpon, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF646464))),
        Text('Doc: $documento', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.grey)),
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
          Text('$label:', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Colors.grey)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.grey),
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

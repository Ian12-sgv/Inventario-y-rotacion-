// lib/screen/actualizardatos.dart
import 'package:flutter/material.dart';
import '../ftp_service.dart';
import '../import_csv.dart';

class ScreenActualizarDatos extends StatefulWidget {
  const ScreenActualizarDatos({super.key});

  @override
  State<ScreenActualizarDatos> createState() => _ScreenActualizarDatosState();
}

class _ScreenActualizarDatosState extends State<ScreenActualizarDatos> {
  bool _busy = false;
  String _status = 'Presiona el botón para descargar e importar los archivos';
  double? _progress; // 0..1

  // Si quieres centralizar estas credenciales, muévelas a algún config.
  final _ftp = FTPService(const FtpConfig(
    host: 'ftp.textilesyessica.com',
    user: 'Reportes@textilesyessica.com',
    pass: 'j305317909', // <- clave corregida (antes estaba distinta)
    remoteDir: '/exports',
    useFtpes: true,
  ));

  final _importer = CsvImporter();

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Iniciando sincronización…';
      _progress = null;
    });

    try {
      // === 1) INVENTARIO ===
      setState(() {
        _status = 'Descargando inventario.csv.gz…';
        _progress = null;
      });
      final invGz = await _ftp.downloadFromBase('inventario.csv.gz');

      int invDone = 0, invTotal = 0;
      setState(() {
        _status = 'Importando inventario…';
        _progress = 0.0;
      });
      await _importer.importInventario(invGz, (cur, total) {
        invDone = cur; invTotal = total;
        if (total > 0) {
          setState(() {
            _status = 'Importando inventario: $cur/$total';
            _progress = cur / total;
          });
        }
      });

      // === 2) COMPRAS ===
      setState(() {
        _status = 'Descargando compras.csv.gz…';
        _progress = null;
      });
      final comGz = await _ftp.downloadFromBase('compras.csv.gz');

      int comDone = 0, comTotal = 0;
      setState(() {
        _status = 'Importando compras…';
        _progress = 0.0;
      });
      await _importer.importCompras(comGz, (cur, total) {
        comDone = cur; comTotal = total;
        if (total > 0) {
          setState(() {
            _status = 'Importando compras: $cur/$total';
            _progress = cur / total;
          });
        }
      });

      setState(() {
        _status = '¡Listo! Inventario ($invDone/$invTotal) y Compras ($comDone/$comTotal) importados ✅';
        _progress = 1.0;
      });
    } catch (e) {
      setState(() {
        _status = 'ERROR: $e';
        _progress = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bar = _progress == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: LinearProgressIndicator(value: _progress),
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Actualizar Datos'),
        centerTitle: true,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                bar,
                const SizedBox(height: 20),
                _busy
                    ? const CircularProgressIndicator(strokeWidth: 6)
                    : ElevatedButton.icon(
                        onPressed: _run,
                        icon: const Icon(Icons.cloud_download),
                        label: const Text('Actualizar Datos'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                          textStyle: const TextStyle(fontSize: 18),
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

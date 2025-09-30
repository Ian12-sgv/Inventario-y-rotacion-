// lib/screen/actualizardatos.dart
import 'dart:io';
import 'package:flutter/material.dart';

import '../ftp_service.dart';
import '../database.dart';
import '../import_csv.dart';

class ScreenActualizarDatos extends StatefulWidget {
  const ScreenActualizarDatos({super.key});

  @override
  State<ScreenActualizarDatos> createState() => _ScreenActualizarDatosState();
}

class _ScreenActualizarDatosState extends State<ScreenActualizarDatos> {
  bool _busy = false;
  String _status = 'Presiona el botón para actualizar la base de datos';
  double? _progress; // 0..1 (indeterminada cuando es null)

  // Config FTP
  static const FtpConfig _ftpCfg = FtpConfig(
    host: 'ftp.textilesyessica.com',
    // si tu FTPService no usa fallbackIp o preferIPv4, quita estas dos líneas
    fallbackIp: '162.215.130.176',
    preferIPv4: true,
    user: 'Reportes@textilesyessica.com',
    pass: 'j305317909',
    remoteDir: '/exports',
    useFtpes: false, // pon true si usas FTPS estable
  );

  final FTPService _ftp = const FTPService(_ftpCfg);
  final CsvImporter _importer = CsvImporter();

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Conectando al FTP…';
      _progress = null;
    });

    String fmt(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(2);
    final swTotal = Stopwatch()..start();

    Duration dlInv = Duration.zero,
        impInv = Duration.zero,
        dlComp = Duration.zero,
        impComp = Duration.zero;
    String? comprasNote;

    try {
      // ============ 1) INVENTARIO ============
      setState(() {
        _status = 'Descargando inventario.csv…';
        _progress = null;
      });
      final t1 = Stopwatch()..start();
      final invCsvPath = await _ftp.downloadFromBase('inventario.csv');
      t1.stop(); dlInv = t1.elapsed;

      final invBytes = await File(invCsvPath).length();
      final invMB = invBytes / (1024 * 1024);
      final invSecs = dlInv.inMilliseconds / 1000.0;
      final invMbps = invSecs > 0 ? (invMB / invSecs) : 0.0;

      setState(() {
        _status = 'Descarga inventario: ${invMB.toStringAsFixed(2)} MB en '
            '${invSecs.toStringAsFixed(2)} s (${invMbps.toStringAsFixed(2)} MB/s). '
            'Importando…';
        _progress = 0.0;
      });

      final t2 = Stopwatch()..start();
      await _importer.importInventario(invCsvPath, (cur, total) {
        if (!mounted) return;
        if (total <= 0) {
          setState(() => _progress = null);
        } else {
          setState(() {
            _progress = (cur / total).clamp(0.0, 1.0);
            _status = 'Importando inventario… $cur / $total';
          });
        }
      });
      t2.stop(); impInv = t2.elapsed;

      // ============ 2) COMPRAS ============
      try {
        setState(() {
          _status = 'Descargando compras.csv…';
          _progress = null;
        });
        final t3 = Stopwatch()..start();
        final compCsvPath = await _ftp.downloadFromBase('compras.csv');
        t3.stop(); dlComp = t3.elapsed;

        setState(() {
          _status = 'Importando compras.csv…';
          _progress = 0.0;
        });
        final t4 = Stopwatch()..start();
        await _importer.importCompras(compCsvPath, (cur, total) {
          if (!mounted) return;
          if (total <= 0) {
            setState(() => _progress = null);
          } else {
            setState(() {
              _progress = (cur / total).clamp(0.0, 1.0);
              _status = 'Importando compras… $cur / $total';
            });
          }
        });
        t4.stop(); impComp = t4.elapsed;
      } catch (e) {
        // compras.csv no existe o falló: seguimos con OK parcial
        comprasNote = 'Compras omitidas: $e';
      }

      await openDatabaseConnection(); // “calienta”/valida

      swTotal.stop();
      final comprasTxt = (dlComp == Duration.zero && impComp == Duration.zero)
          ? (comprasNote ?? 'Compras: (no importadas)')
          : 'Compras → Descarga: ${fmt(dlComp)}s | Importación: ${fmt(impComp)}s';

      setState(() {
        _status = 'OK ✅\n'
            'Inventario → Descarga: ${fmt(dlInv)}s | Importación: ${fmt(impInv)}s\n'
            '$comprasTxt\n'
            'Total: ${fmt(swTotal.elapsed)}s';
        _progress = 1.0;
      });
    } catch (e) {
      swTotal.stop();
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
      if (mounted) setState(() => _busy = false);
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
                          padding: const EdgeInsets.symmetric(
                            horizontal: 40,
                            vertical: 14,
                          ),
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

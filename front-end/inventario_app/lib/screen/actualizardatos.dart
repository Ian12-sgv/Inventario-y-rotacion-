// lib/screen/actualizardatos.dart
import 'dart:io';
import 'package:flutter/material.dart';
import '../ftp_service.dart';
import '../database.dart';

class ScreenActualizarDatos extends StatefulWidget {
  const ScreenActualizarDatos({super.key});

  @override
  State<ScreenActualizarDatos> createState() => _ScreenActualizarDatosState();
}

class _ScreenActualizarDatosState extends State<ScreenActualizarDatos> {
  bool _busy = false;
  String _status = 'Presiona el botón para actualizar la base de datos';
  double? _progress; // 0..1 (indeterminada cuando es null)

  // Config FTP — actualmente SIN TLS para diagnóstico (más estable en AVD).
  // Cuando quieras volver a FTPS, cambia useFtpes a true.
  static const FtpConfig _ftpCfg = FtpConfig(
    host: 'ftp.textilesyessica.com',
    user: 'Reportes@textilesyessica.com',
    pass: 'j305317909',
    remoteDir: '/exports',
    useFtpes: false, // ← pon true para FTPS (producción)
  );
  final FTPService _ftp = const FTPService(_ftpCfg);

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Conectando al FTP…';
      _progress = null;
    });

    String fmt(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(2);
    final swTotal = Stopwatch()..start();

    try {
      // 1) Descargar el paquete de base de datos listo
      setState(() {
        _status = 'Descargando my_database.db.gz…';
        _progress = null; // barra indeterminada
      });

      final swDl = Stopwatch()..start();
      final dbGzPath = await _ftp.downloadFromBase('my_database.db.gz');
      swDl.stop();

      // Métricas de descarga
      final bytes = await File(dbGzPath).length();
      final mb = bytes / (1024 * 1024);
      final secs = swDl.elapsedMilliseconds / 1000.0;
      final mbps = secs > 0 ? (mb / secs) : 0.0;

      setState(() {
        _status =
            'Descarga completada: ${mb.toStringAsFixed(2)} MB en '
            '${secs.toStringAsFixed(2)} s '
            '(${mbps.toStringAsFixed(2)} MB/s). Preparando reemplazo…';
        _progress = null;
      });

      // 2) Reemplazar la base local (swap atómico)
      final swSwap = Stopwatch()..start();
      await replaceDatabaseFromGzip(dbGzPath); // valida GZIP y cabecera SQLite
      // Abre para calentar conexión / validar esquema
      await openDatabaseConnection();
      swSwap.stop();

      swTotal.stop();
      setState(() {
        _status = 'OK ✅\n'
            'Descarga: ${fmt(swDl.elapsed)}s (${mb.toStringAsFixed(2)} MB @ ${mbps.toStringAsFixed(2)} MB/s)\n'
            'Reemplazo: ${fmt(swSwap.elapsed)}s\n'
            'Total: ${fmt(swTotal.elapsed)}s';
        _progress = 1.0; // completa
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

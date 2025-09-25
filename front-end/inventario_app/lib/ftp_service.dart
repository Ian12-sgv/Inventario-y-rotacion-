// lib/ftp_service.dart
import 'dart:io';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FtpConfig {
  final String host;
  final String user;
  final String pass;
  final int port;
  final String remoteDir;   // p. ej. "/exports"
  final bool useFtpes;      // true = FTP explícito sobre TLS
  final Duration timeout;

  const FtpConfig({
    required this.host,
    required this.user,
    required this.pass,
    this.port = 21,
    this.remoteDir = '/exports',
    this.useFtpes = true,
    this.timeout = const Duration(seconds: 45),
  });
}

class FTPService {
  final FtpConfig cfg;
  const FTPService(this.cfg);

  /// Descarga un archivo del FTP y devuelve la ruta local.
  /// [remoteFilePath] puede ser "inventario.csv.gz" o una ruta como "/exports/inventario.csv.gz".
  /// [localFileName] opcional para renombrar localmente.
  Future<String> download({
    required String remoteFilePath,
    String? localFileName,
  }) async {
    final normalized = p.posix.normalize(remoteFilePath);
    final remoteDirFromArg = p.posix.dirname(normalized);    // "." si no trae carpeta
    final remoteName = p.posix.basename(normalized);

    final ftp = FTPConnect(
      cfg.host,
      user: cfg.user,
      pass: cfg.pass,
      port: cfg.port,
      showLog: true,
      securityType: cfg.useFtpes ? SecurityType.ftpes : SecurityType.ftp,
      timeout: cfg.timeout.inSeconds,
    );

    await ftp.connect();
    try {
      // Decide a qué directorio cambiar: el pasado en el path o el de config
      final targetDir = (remoteDirFromArg == '.' || remoteDirFromArg.isEmpty)
          ? cfg.remoteDir
          : remoteDirFromArg;

      if (targetDir == '/') {
        await ftp.changeDirectory('/');
      } else if (targetDir.isNotEmpty) {
        // Intento directo
        final okAbs = await ftp.changeDirectory(targetDir);
        if (!okAbs) {
          // Fallback: paso a paso, iniciando desde raíz
          await ftp.changeDirectory('/');
          for (final seg in targetDir.split('/').where((s) => s.isNotEmpty)) {
            final ok = await ftp.changeDirectory(seg);
            if (!ok) {
              throw Exception('FTP_CHANGE_DIR_FAILED: $targetDir (segmento "$seg")');
            }
          }
        }
      }

      // Guardar en carpeta temporal
      final tmp = await getTemporaryDirectory();
      final localPath = p.join(tmp.path, localFileName ?? remoteName);
      await File(localPath).create(recursive: true);

      final ok = await ftp.downloadFile(remoteName, File(localPath));
      if (!ok) {
        throw Exception('FTP_DOWNLOAD_FAILED: $remoteName');
      }
      return localPath;
    } finally {
      try { await ftp.disconnect(); } catch (_) {}
    }
  }

  /// Azúcar sintáctico: descarga desde el directorio base de la config.
  Future<String> downloadFromBase(String fileName) =>
      download(remoteFilePath: fileName);
}

// lib/ftp_service.dart
import 'dart:io';
import 'package:ftpconnect/ftpconnect.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class FtpConfig {
  final String host;
  final String user;
  final String pass;
  final String remoteDir;   // ej: /exports
  final bool useFtpes;      // true = FTPS explícito
  final int port;
  final Duration timeout;

  const FtpConfig({
    required this.host,
    required this.user,
    required this.pass,
    required this.remoteDir,
    this.useFtpes = true,
    this.port = 21,
    this.timeout = const Duration(seconds: 30),
  });
}

class FTPService {
  final FtpConfig cfg;
  const FTPService(this.cfg);

  FTPConnect _client() => FTPConnect(
        cfg.host,
        user: cfg.user,
        pass: cfg.pass,
        port: cfg.port,
        securityType: cfg.useFtpes ? SecurityType.ftpes : SecurityType.ftp,
        timeout: cfg.timeout.inSeconds,
        showLog: true, // deja logs útiles en consola
      );

  /// Descarga un archivo ubicado en [cfg.remoteDir] con nombre [fileName].
  /// Devuelve la ruta local donde se guardó (en cache/).
  Future<String> downloadFromBase(String fileName, {String? localName}) async {
    final ftp = _client();
    try {
      print('[FTP] Connecting...');
      final ok = await ftp.connect();
      if (!ok) throw Exception('FTP_CONNECT_FAILED');

      // Cambiar a remoteDir
      final dir = cfg.remoteDir.trim().isEmpty ? '/' : cfg.remoteDir;
      if (dir == '/') {
        await ftp.changeDirectory('/');
      } else {
        // avanzar segmento a segmento por compatibilidad
        await ftp.changeDirectory('/');
        for (final seg in dir.split('/')) {
          if (seg.isEmpty) continue;
          final ok = await ftp.changeDirectory(seg);
          if (!ok) throw Exception('FTP_CHANGE_DIR_FAILED: $dir (seg:$seg)');
        }
      }

      // destino local en cache
      final tmpDir = await getTemporaryDirectory();
      final localPath = p.join(tmpDir.path, localName ?? fileName);

      // asegurar carpeta local
      await Directory(p.dirname(localPath)).create(recursive: true);

      print('[FTP] Download $fileName -> $localPath');
      final okDl = await ftp.downloadFile(fileName, File(localPath));
      if (!okDl) {
        throw Exception('FTP_DOWNLOAD_FAILED: $fileName');
      }

      print('[FTP] OK downloaded: $localPath');
      return localPath;
    } finally {
      try {
        await ftp.disconnect();
      } catch (_) {}
    }
  }
}

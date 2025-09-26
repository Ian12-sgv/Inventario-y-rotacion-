// lib/ftp_service.dart
import 'dart:async';
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
    this.timeout = const Duration(seconds: 90),
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
        showLog: true,
      );

  Future<void> _cdToRemoteDir(FTPConnect ftp) async {
    final dir = cfg.remoteDir.trim().isEmpty ? '/' : cfg.remoteDir;
    await ftp.changeDirectory('/');
    if (dir == '/' || dir == '') return;
    for (final seg in dir.split('/')) {
      if (seg.isEmpty) continue;
      final ok = await ftp.changeDirectory(seg);
      if (!ok) {
        throw SocketException('FTP_CHANGE_DIR_FAILED: $dir (seg: $seg)');
      }
    }
  }

  Future<String> downloadFromBase(
    String fileName, {
    String? localName,
    int maxRetries = 3,
  }) async {
    final tmpDir = await getTemporaryDirectory();
    final destPath = p.join(tmpDir.path, localName ?? fileName);
    final partPath = '$destPath.part';

    await Directory(p.dirname(destPath)).create(recursive: true);

    SocketException? lastSock;
    TimeoutException? lastTimeout;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      final ftp = _client();
      try {
        print('[FTP] Connecting (attempt $attempt/$maxRetries)…');
        final ok = await ftp.connect();
        if (!ok) throw const SocketException('FTP_CONNECT_FAILED');

        await _cdToRemoteDir(ftp);

        // Limpia restos
        try {
          if (await File(partPath).exists()) await File(partPath).delete();
          if (attempt == 1 && await File(destPath).exists()) {
            await File(destPath).delete();
          }
        } catch (_) {}

        // Fuerza BINARIO para evitar corrupción de .gz
        await ftp.setTransferType(TransferType.binary);

        print('[FTP] Download $fileName -> $partPath (binary)');
        final okDl = await ftp.downloadFile(
          fileName,
          File(partPath),
        );
        if (!okDl) {
          throw const SocketException('FTP_DOWNLOAD_FAILED');
        }

        // Validación rápida GZIP si aplica
        if (fileName.toLowerCase().endsWith('.gz')) {
          final raf = await File(partPath).open();
          final hdr = await raf.read(2);
          await raf.close();
          final isGzip = hdr.length == 2 && hdr[0] == 0x1f && hdr[1] == 0x8b;
          if (!isGzip) {
            try { await File(partPath).delete(); } catch (_) {}
            throw const FormatException('Archivo descargado no es GZIP válido');
          }
        }

        await File(partPath).rename(destPath);
        print('[FTP] OK downloaded: $destPath');
        return destPath;
      } on SocketException catch (e) {
        lastSock = e;
        print('[FTP] SocketException: $e');
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
          continue;
        }
        rethrow;
      } on TimeoutException catch (e) {
        lastTimeout = e;
        print('[FTP] Timeout: $e');
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
          continue;
        }
        rethrow;
      } finally {
        try { await ftp.disconnect(); } catch (_) {}
      }
    }

    throw lastTimeout ?? lastSock ?? const SocketException('FTP_RETRIES_EXHAUSTED');
  }
}

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
  final bool preferIPv4;    // fuerza IPv4 si hay AAAA problemático
  final String? fallbackIp; // IP a usar si falla DNS

  const FtpConfig({
    required this.host,
    required this.user,
    required this.pass,
    required this.remoteDir,
    this.useFtpes = true,
    this.port = 21,
    this.timeout = const Duration(seconds: 90),
    this.preferIPv4 = true,
    this.fallbackIp,
  });
}

class FTPService {
  final FtpConfig cfg;
  const FTPService(this.cfg);

  Future<String> _resolveHostForConnect() async {
    try {
      final addrs = await InternetAddress.lookup(cfg.host);
      if (cfg.preferIPv4) {
        final v4 = addrs.where((a) => a.type == InternetAddressType.IPv4);
        if (v4.isNotEmpty) return v4.first.address;
      }
      return addrs.first.address;
    } catch (e) {
      if (cfg.fallbackIp != null) {
        // Fallback si el DNS del emulador se cae
        // ignore: avoid_print
        print('[DNS] lookup falló ($e). Usando fallback ${cfg.fallbackIp}');
        return cfg.fallbackIp!;
      }
      rethrow;
    }
  }

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

  /// Descarga un archivo (p.ej. inventario.csv) a /cache de forma atómica.
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
      final hostForConnect = await _resolveHostForConnect();
      final ftp = FTPConnect(
        hostForConnect,
        user: cfg.user,
        pass: cfg.pass,
        port: cfg.port,
        timeout: cfg.timeout.inSeconds, // segundos
        showLog: true,
        securityType: cfg.useFtpes ? SecurityType.ftpes : SecurityType.ftp,
      );

      try {
        // ignore: avoid_print
        print('[FTP] Connecting to ${cfg.host} -> $hostForConnect:${cfg.port} (attempt $attempt/$maxRetries)…');
        final ok = await ftp.connect();
        if (!ok) throw const SocketException('FTP_CONNECT_FAILED');

        // CSV también se baja en binario para evitar traducciones de EOL
        await ftp.setTransferType(TransferType.binary);

        await _cdToRemoteDir(ftp);

        // Limpieza previa
        try {
          if (await File(partPath).exists()) await File(partPath).delete();
          if (attempt == 1 && await File(destPath).exists()) await File(destPath).delete();
        } catch (_) {}

        // Descarga a .part y rename atómico
        // ignore: avoid_print
        print('[FTP] Download $fileName -> $partPath (binary)');
        final okDl = await ftp.downloadFile(fileName, File(partPath));
        if (!okDl) throw const SocketException('FTP_DOWNLOAD_FAILED');

        final sz = await File(partPath).length();
        if (sz <= 0) {
          await File(partPath).delete().catchError((_) {});
          throw const SocketException('FTP_EMPTY_DOWNLOAD');
        }

        await File(partPath).rename(destPath);
        // ignore: avoid_print
        print('[FTP] OK downloaded: $destPath ($sz bytes)');
        return destPath;
      } on SocketException catch (e) {
        lastSock = e;
        // ignore: avoid_print
        print('[FTP] SocketException: $e');
        if (attempt < maxRetries) {
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
          continue;
        }
        rethrow;
      } on TimeoutException catch (e) {
        lastTimeout = e;
        // ignore: avoid_print
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

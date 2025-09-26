// lib/database.dart
import 'dart:convert' show gzip;
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

Database? _cachedDb;

/// Abre (y cachea) la conexión a 'my_database.db' ya preconstruida.
/// No crea tablas ni migra: el .db viene listo desde el backend.
Future<Database> openDatabaseConnection() async {
  if (_cachedDb != null && _cachedDb!.isOpen) return _cachedDb!;
  final databasesPath = await getDatabasesPath();
  final dbPath = p.join(databasesPath, 'my_database.db');

  // Si no existe, avisa claramente (útil en primeras corridas)
  final exists = await File(dbPath).exists();
  if (!exists) {
    throw Exception(
      'Base de datos no encontrada en $dbPath. '
      'Ve a "Actualizar" para descargarla primero.'
    );
  }

  _cachedDb = await openDatabase(dbPath); // sin onCreate/onUpgrade
  return _cachedDb!;
}

/// Cierra la conexión cacheada (si existe).
Future<void> closeDatabase() async {
  if (_cachedDb != null) {
    final db = _cachedDb!;
    _cachedDb = null;
    await db.close();
  }
}

/// Reemplaza la base local con un .gz descargado:
/// 1) Valida que sea GZIP por magic bytes (1F 8B)
/// 2) Descomprime a .tmp
/// 3) Valida cabecera SQLite ("SQLite format 3\0")
/// 4) Swap atómico a my_database.db (con backup opcional)
Future<void> replaceDatabaseFromGzip(
  String gzPath, {
  bool keepBackup = true,
  int minAcceptableBytes = 256, // evita archivos ridículamente pequeños
}) async {
  // Asegura que no haya handlers abiertos
  await closeDatabase();

  final databasesPath = await getDatabasesPath();
  final dbPath  = p.join(databasesPath, 'my_database.db');
  final tmpPath = '$dbPath.tmp';
  final bakPath = '$dbPath.bak';

  // Asegura carpeta
  await Directory(databasesPath).create(recursive: true);

  // ===== Validación del .gz =====
  final gzFile = File(gzPath);
  if (!await gzFile.exists()) {
    throw Exception('Archivo no encontrado: $gzPath');
  }
  final gzLen = await gzFile.length();
  if (gzLen < minAcceptableBytes) {
    throw Exception('Paquete remoto demasiado pequeño: $gzLen bytes');
  }

  // Magic bytes GZIP (1F 8B)
  RandomAccessFile raf = await gzFile.open();
  final gzHeader = await raf.read(2);
  await raf.close();
  final isGzip = gzHeader.length == 2 && gzHeader[0] == 0x1F && gzHeader[1] == 0x8B;
  if (!isGzip) {
    throw Exception('Paquete inválido: no es GZIP (bytes iniciales $gzHeader, tamaño $gzLen bytes)');
  }

  // Limpieza previa de .tmp
  try { await File(tmpPath).delete(); } catch (_) {}

  // ===== Descompresión por streaming =====
  try {
    final input = gzFile.openRead();
    final out = File(tmpPath).openWrite();
    await input.transform(gzip.decoder).pipe(out);
    await out.close();
  } on FormatException catch (e) {
    // GZIP corrupto / truncado
    try { await File(tmpPath).delete(); } catch (_) {}
    throw Exception('Archivo GZIP corrupto o incompleto: $e (tamaño $gzLen bytes)');
  }

  // ===== Validación cabecera SQLite =====
  final tmpFile = File(tmpPath);
  final tmpLen = await tmpFile.length();
  if (tmpLen < 100) {
    try { await tmpFile.delete(); } catch (_) {}
    throw Exception('Archivo SQLite inválido (demasiado pequeño): $tmpLen bytes');
  }
  raf = await tmpFile.open();
  final sqliteHdr = await raf.read(16);
  await raf.close();
  final expected = 'SQLite format 3\u0000'.codeUnits;
  final looksLikeSqlite = sqliteHdr.length == 16 &&
      List.generate(16, (i) => sqliteHdr[i] == expected[i]).every((ok) => ok);
  if (!looksLikeSqlite) {
    try { await tmpFile.delete(); } catch (_) {}
    throw Exception('Archivo descomprimido no parece SQLite válido (cabecera: $sqliteHdr)');
  }

  // ===== Swap atómico (con backup opcional) =====
  if (keepBackup && await File(dbPath).exists()) {
    try { await File(bakPath).delete(); } catch (_) {}
    await File(dbPath).rename(bakPath);
  } else {
    try { await File(dbPath).delete(); } catch (_) {}
  }
  await File(tmpPath).rename(dbPath);
}

/// (Opcional) Chequeo rápido de que el .db tenga las tablas esperadas.
Future<bool> databaseHasExpectedSchema() async {
  final db = await openDatabaseConnection();
  final res = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
    "('inventarioc','stock','comprasgalpones');"
  );
  return res.length == 3;
}

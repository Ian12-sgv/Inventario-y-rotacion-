// lib/database.dart
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

Database? _cachedDb;

/// Abre (y crea si no existe) `my_database.db` y asegura el esquema mínimo.
/// Mantiene una conexión cacheada para reutilizarla.
Future<Database> openDatabaseConnection() async {
  if (_cachedDb != null && _cachedDb!.isOpen) return _cachedDb!;

  final databasesPath = await getDatabasesPath();
  await Directory(databasesPath).create(recursive: true);
  final dbPath = p.join(databasesPath, 'my_database.db');

  final db = await openDatabase(dbPath);
  await _ensureSchema(db); // crea las tablas si faltan

  _cachedDb = db;
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

/// Crea tablas/índices si no existen (idempotente).
Future<void> _ensureSchema(Database db) async {
  // (opcional) activar claves foráneas si las usas en el futuro
  await db.execute('PRAGMA foreign_keys = ON;');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS inventarioc (
      CodigoBarra TEXT PRIMARY KEY,
      Referencia  TEXT,
      Nombre      TEXT,
      PrecioDetal TEXT,
      PrecioMayor TEXT,
      PrecioPromocion TEXT,
      CREACION    TEXT
    );
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS stock (
      CodigoBarra TEXT,
      Tienda      TEXT,
      Existencia  INTEGER,
      PRIMARY KEY (CodigoBarra, Tienda)
    );
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS comprasgalpones (
      NombreGalpon TEXT,
      CodigoBarra  TEXT,
      Referencia   TEXT,
      Nombre       TEXT,
      Documento    TEXT,
      Cantidad     INTEGER,
      FechaCompra  TEXT
    );
  ''');

  // Índices útiles (opcionales)
  await db.execute('CREATE INDEX IF NOT EXISTS idx_stock_cod ON stock (CodigoBarra);');
  await db.execute('CREATE INDEX IF NOT EXISTS idx_comp_doc ON comprasgalpones (Documento);');
}

/// Verificación rápida de que existen las tablas esperadas.
Future<bool> databaseHasExpectedSchema() async {
  final db = await openDatabaseConnection();
  final res = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' "
    "AND name IN ('inventarioc','stock','comprasgalpones');"
  );
  return res.length == 3;
}

/// Compatibilidad: ya no usamos paquetes .gz. Si alguien lo llama por error, avisamos.
@Deprecated('Ya no se usa; el flujo actual importa CSV directamente.')
Future<void> replaceDatabaseFromGzip(
  String _,
  {bool keepBackup = true, int minAcceptableBytes = 256}
) async {
  throw UnsupportedError('replaceDatabaseFromGzip() está obsoleto. Usa el importador CSV.');
}

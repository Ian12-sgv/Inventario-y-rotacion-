// lib/database.dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

Database? _cachedDb;

/// Abre (o retorna) la conexión SQLite (singleton).
Future<Database> openDatabaseConnection() async {
  if (_cachedDb != null && _cachedDb!.isOpen) return _cachedDb!;

  final databasesPath = await getDatabasesPath();
  final dbPath = p.join(databasesPath, 'my_database.db');

  _cachedDb = await openDatabase(
    dbPath,
    version: 9, // ⬅️ subimos versión para crear 'stock'
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON;');
      await db.execute('PRAGMA journal_mode = WAL;');
      await db.execute('PRAGMA synchronous = NORMAL;');
    },
    onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS inventarioc (
          CodigoBarra TEXT,
          Nombre TEXT,
          Referencia TEXT,
          PrecioDetal TEXT,
          PrecioMayor TEXT,
          PrecioPromocion TEXT,
          CREACION TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS comprasgalpones (
          NombreGalpon TEXT,
          CodigoBarra TEXT,
          Referencia TEXT,
          Nombre TEXT,
          Documento TEXT,
          Cantidad INTEGER,
          FechaCompra TEXT
        )
      ''');

      -- Crear tabla dinámica por tienda
      await db.execute('''
        CREATE TABLE IF NOT EXISTS stock (
          CodigoBarra TEXT NOT NULL,
          Tienda TEXT NOT NULL,
          Existencia INTEGER NOT NULL,
          PRIMARY KEY (CodigoBarra, Tienda)
        )
      ''');

      // Índices útiles
      await db.execute('CREATE INDEX IF NOT EXISTS idx_inv_codigo ON inventarioc (CodigoBarra);');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_stock_codigo ON stock (CodigoBarra);');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_stock_tienda ON stock (Tienda);');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_compras_codigo ON comprasgalpones (CodigoBarra);');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_compras_fecha  ON comprasgalpones (FechaCompra DESC);');
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 9) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS stock (
            CodigoBarra TEXT NOT NULL,
            Tienda TEXT NOT NULL,
            Existencia INTEGER NOT NULL,
            PRIMARY KEY (CodigoBarra, Tienda)
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_stock_codigo ON stock (CodigoBarra);');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_stock_tienda ON stock (Tienda);');
      }
    },
  );

  return _cachedDb!;
}

// lib/import_csv.dart
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';
//import 'package:path/path.dart' as p;
import 'database.dart';

class CsvImporter {
  /// Importa INVENTARIO desde .gz/.csv con columnas:
  /// CodigoBarra, Referencia, (NombreProducto|Nombre), PrecioDetal, PrecioMayor, PrecioPromocion, (ExistenciaPorTienda|Existencia), (Tienda|NombreTienda)
  Future<void> importInventario(String path, void Function(int cur, int total) onProgress) async {
    final csvPath = await _ensureCsv(path);
    final db = await openDatabaseConnection();

    final file = File(csvPath);
    if (!await file.exists()) return;

    final content = await file.readAsString();
    if (content.trim().isEmpty) return;

    final rows = const CsvToListConverter(
      eol: '\n', fieldDelimiter: ',', shouldParseNumbers: false,
    ).convert(content.replaceAll('\r\n', '\n'));

    if (rows.isEmpty) return;

    final headers = rows.first.map((e) => e.toString()).toList();
    int col(String name) {
      final i = headers.indexOf(name);
      if (i < 0) throw FormatException('CSV_HEADER_MISSING: $name');
      return i;
    }

    final iCodigo = col('CodigoBarra');
    final iRef = col('Referencia');
    final iNombre = headers.contains('NombreProducto') ? headers.indexOf('NombreProducto') : col('Nombre');
    final iPD = headers.contains('PrecioDetal') ? headers.indexOf('PrecioDetal') : -1;
    final iPM = headers.contains('PrecioMayor') ? headers.indexOf('PrecioMayor') : -1;
    final iPP = headers.contains('PrecioPromocion') ? headers.indexOf('PrecioPromocion') : -1;
    final iExist = headers.contains('ExistenciaPorTienda') ? headers.indexOf('ExistenciaPorTienda') :
                   headers.contains('Existencia') ? headers.indexOf('Existencia') : -1;
    final iTienda = headers.contains('Tienda') ? headers.indexOf('Tienda') :
                    headers.contains('NombreTienda') ? headers.indexOf('NombreTienda') : col('Tienda');

    final total = rows.length - 1;
    var done = 0;

    await db.transaction((txn) async {
      // Reset
      await txn.delete('inventarioc');
      await txn.delete('stock');

      final batch = txn.batch();
      final seen = <String>{};
      const chunk = 1000;

      for (var r = 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.isEmpty) continue;

        final codigo = _s(row, iCodigo);
        if (codigo.isEmpty) continue;

        // Upsert "inventarioc" solo 1 vez por producto
        if (seen.add(codigo)) {
          batch.insert('inventarioc', {
            'CodigoBarra': codigo,
            'Referencia': _s(row, iRef),
            'Nombre': _s(row, iNombre),
            'PrecioDetal': _s(row, iPD),
            'PrecioMayor': _s(row, iPM),
            'PrecioPromocion': _s(row, iPP),
            'CREACION': '', // si no viene en CSV, queda vacío
          });
        }

        // Inserta stock dinámico (tienda y existencia)
        final tienda = _s(row, iTienda);
        final existencia = _i(row, iExist);
        if (tienda.isNotEmpty) {
          batch.insert(
            'stock',
            {
              'CodigoBarra': codigo,
              'Tienda': tienda,
              'Existencia': existencia,
            },
            conflictAlgorithm: ConflictAlgorithm.replace, // PK (CodigoBarra,Tienda)
          );
        }

        done++;
        if (done % chunk == 0) {
          await batch.commit(noResult: true);
          onProgress(done, total);
        }
      }

      await batch.commit(noResult: true);
      onProgress(done, total);
    });
  }

  /// Importa COMPRAS (sin cambios)
  Future<void> importCompras(String path, void Function(int cur, int total) onProgress) async {
    final csvPath = await _ensureCsv(path);
    final db = await openDatabaseConnection();

    final file = File(csvPath);
    if (!await file.exists()) return;

    final content = await file.readAsString();
    if (content.trim().isEmpty) return;

    final rows = const CsvToListConverter(
      eol: '\n', fieldDelimiter: ',', shouldParseNumbers: false,
    ).convert(content.replaceAll('\r\n', '\n'));

    if (rows.isEmpty) return;

    final headers = rows.first.map((e) => e.toString()).toList();
    int col(String name) {
      final i = headers.indexOf(name);
      if (i < 0) throw FormatException('CSV_HEADER_MISSING: $name');
      return i;
    }

    final iCodigo = col('CodigoBarra');
    final iRef = col('Referencia');
    final iNombre = headers.contains('NombreProducto') ? headers.indexOf('NombreProducto') : col('Nombre');
    final iDoc = col('Documento');
    final iCant = headers.contains('Cantidad') ? headers.indexOf('Cantidad') : col('cantidad');
    final iFecha = headers.contains('Fecha') ? headers.indexOf('Fecha') :
                   headers.contains('FechaCompra') ? headers.indexOf('FechaCompra') : col('Fecha');

    final total = rows.length - 1;
    var done = 0;

    await db.transaction((txn) async {
      await txn.delete('comprasgalpones');
      final batch = txn.batch();
      const chunk = 1000;

      for (var r = 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.isEmpty) continue;

        batch.insert('comprasgalpones', {
          'NombreGalpon': '',
          'CodigoBarra': _s(row, iCodigo),
          'Referencia': _s(row, iRef),
          'Nombre': _s(row, iNombre),
          'Documento': _s(row, iDoc),
          'Cantidad': _i(row, iCant),
          'FechaCompra': _s(row, iFecha),
        });

        done++;
        if (done % chunk == 0) {
          await batch.commit(noResult: true);
          onProgress(done, total);
        }
      }

      await batch.commit(noResult: true);
      onProgress(done, total);
    });
  }

  // ------- utils -------
  Future<String> _ensureCsv(String path) async {
    if (!path.toLowerCase().endsWith('.gz')) return path;
    final csvPath = path.substring(0, path.length - 3);
    final input = File(path).openRead();
    final sink = File(csvPath).openWrite();
    await input.transform(gzip.decoder).pipe(sink);
    return csvPath;
  }

  String _s(List row, int idx) {
    if (idx < 0 || idx >= row.length) return '';
    return row[idx]?.toString() ?? '';
  }

  int _i(List row, int idx) {
    if (idx < 0 || idx >= row.length) return 0;
    return int.tryParse(row[idx]?.toString() ?? '') ?? 0;
  }
}

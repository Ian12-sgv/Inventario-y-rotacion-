// lib/import_csv.dart
import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';

import 'database.dart';

class CsvImporter {
  /// Importa INVENTARIO desde CSV plano.
  /// Si [delimiter] es null => se autodetecta (',', ';', '|', '\t').
  Future<void> importInventario(
    String path,
    void Function(int cur, int total) onProgress, {
    String? delimiter,
    int batchSize = 1000,
  }) async {
    final csvPath = await _ensureCsv(path);
    final f = File(csvPath);
    if (!await f.exists()) {
      throw Exception('CSV no encontrado: $csvPath');
    }

    // Autodetecta separador si no lo pasan
    final delim = delimiter ?? await _pickDelimiter(f);

    final db = await openDatabaseConnection();

    final lines =
        f.openRead().transform(utf8.decoder).transform(const LineSplitter());
    final csvLine = CsvToListConverter(
      fieldDelimiter: delim,
      eol: '\n',
      shouldParseNumbers: false,
    );

    // índices (se asignan 1 sola vez al leer el header)
    late final int iCodigo, iRef, iNombre, iPD, iPM, iPP, iExist, iTienda;
    bool mapped = false;

    // progreso total (opcional)
    final cnt = await f
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .fold<int>(0, (acc, _) => acc + 1);
    final total = (cnt > 0) ? cnt - 1 : 0;
    var done = 0;

    await db.transaction((txn) async {
      // asegura esquema
      await txn.execute('''
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
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS stock (
          CodigoBarra TEXT,
          Tienda      TEXT,
          Existencia  INTEGER,
          PRIMARY KEY (CodigoBarra, Tienda)
        );
      ''');

      await txn.delete('inventarioc');
      await txn.delete('stock');

      final seen = <String>{};
      Batch batch = txn.batch();

      bool isFirst = true;
      await for (final line in lines) {
        if (line.trim().isEmpty) continue;

        final parsed = csvLine.convert(line);
        if (parsed.isEmpty) continue;
        final row = parsed.first.map((e) => e?.toString() ?? '').toList();

        if (isFirst) {
          final headers = row.map((e) => e.toString()).toList();

          // ---- Mapear índices tolerantes (una sola vez) ----
          iCodigo = _colAny(headers, [
            'CodigoBarra','Codigo_Barra','CodigoBarras','CodBarra','CB',
            'Barcode','bar_code','barcode','EAN','Codigo','CodigoEAN'
          ]);
          iRef = _colAny(headers, [
            'Referencia','Ref','CodigoProducto','Codigo_Producto',
            'CodigoInterno','SKU','reference'
          ]);
          iNombre = _colAny(headers, [
            'NombreProducto','Nombre','Descripcion','DescripcionProducto',
            'product_name','product','productname'
          ]);
          iPD = _colAny(headers, [
            'PrecioDetal','PrecioDetalle','Precio_Detal',
            'price_detal','price_detail','price_retail','retail_price'
          ], required: false);
          iPM = _colAny(headers, [
            'PrecioMayor','Precio_Mayor','price_mayor','price_wholesale',
            'wholesale_price'
          ], required: false);
          iPP = _colAny(headers, [
            'PrecioPromocion','PrecioPromo','Precio_Promocion',
            'price_promo','promo_price','discount_price'
          ], required: false);
          iExist = _colAny(headers, [
            'ExistenciaPorTienda','Existencia','Stock','ExistenciaTienda',
            'stock','qty','quantity'
          ], required: false);
          iTienda = _colAny(headers, [
            'Tienda','NombreTienda','Sucursal','Almacen','Bodega','NombreSucursal',
            'store_name','store','branch','warehouse'
          ]);

          mapped = true;
          isFirst = false;
          continue;
        }

        if (!mapped) {
          throw FormatException(
              'CSV sin encabezado válido (no se pudieron mapear columnas requeridas).');
        }

        final codigo = _s(row, iCodigo);
        if (codigo.isEmpty) {
          done++;
          if (done % batchSize == 0) {
            await batch.commit(noResult: true);
            batch = txn.batch();
            onProgress(done, total);
          }
          continue;
        }

        // Tabla inventarioc: solo 1 vez por producto
        if (seen.add(codigo)) {
          batch.insert('inventarioc', {
            'CodigoBarra': codigo,
            'Referencia': _s(row, iRef),
            'Nombre': _s(row, iNombre),
            'PrecioDetal': _s(row, iPD),
            'PrecioMayor': _s(row, iPM),
            'PrecioPromocion': _s(row, iPP),
            'CREACION': '',
          });
        }

        // Tabla stock: por tienda
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
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        done++;
        if (done % batchSize == 0) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          onProgress(done, total);
        }
      }

      await batch.commit(noResult: true);
      onProgress(done, total);
    });
  }

  /// Importa COMPRAS desde CSV plano.
  Future<void> importCompras(
    String path,
    void Function(int cur, int total) onProgress, {
    String? delimiter,
    int batchSize = 1000,
  }) async {
    final csvPath = await _ensureCsv(path);
    final f = File(csvPath);
    if (!await f.exists()) {
      throw Exception('CSV no encontrado: $csvPath');
    }

    final delim = delimiter ?? await _pickDelimiter(f);
    final db = await openDatabaseConnection();

    final lines =
        f.openRead().transform(utf8.decoder).transform(const LineSplitter());
    final csvLine = CsvToListConverter(
      fieldDelimiter: delim,
      eol: '\n',
      shouldParseNumbers: false,
    );

    late final int iCodigo, iRef, iNombre, iDoc, iCant, iFecha;
    bool mapped = false;

    final cnt = await f
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .fold<int>(0, (acc, _) => acc + 1);
    final total = (cnt > 0) ? cnt - 1 : 0;
    var done = 0;

    await db.transaction((txn) async {
      await txn.execute('''
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
      await txn.delete('comprasgalpones');

      bool isFirst = true;
      Batch batch = txn.batch();

      await for (final line in lines) {
        if (line.trim().isEmpty) continue;

        final parsed = csvLine.convert(line);
        if (parsed.isEmpty) continue;
        final row = parsed.first.map((e) => e?.toString() ?? '').toList();

        if (isFirst) {
          final headers = row.map((e) => e.toString()).toList();

          iCodigo = _colAny(headers, [
            'CodigoBarra','CodBarra','CB','Barcode','barcode','EAN','Codigo'
          ]);
          iRef = _colAny(headers, [
            'Referencia','Ref','CodigoProducto','CodigoInterno','SKU','reference'
          ]);
          iNombre = _colAny(headers, [
            'NombreProducto','Nombre','Descripcion','product_name','product'
          ]);
          iDoc = _colAny(headers, [
            'Documento','NroDocumento','NumeroDocumento','Doc','Factura','NumDoc',
            'document','invoice','invoice_number'
          ]);
          iCant = _colAny(headers, [
            'Cantidad','cant','Unidades','quantity','qty'
          ]);
          iFecha = _colAny(headers, [
            'Fecha','FechaCompra','FecCompra','Fecha_Doc','date','purchase_date'
          ]);

          mapped = true;
          isFirst = false;
          continue;
        }

        if (!mapped) {
          throw FormatException(
              'CSV sin encabezado válido (no se pudieron mapear columnas requeridas).');
        }

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
        if (done % batchSize == 0) {
          await batch.commit(noResult: true);
          batch = txn.batch();
          onProgress(done, total);
        }
      }

      await batch.commit(noResult: true);
      onProgress(done, total);
    });
  }

  // ===== utils =====

  /// CSV-only: si llega .gz, falla explícito.
  Future<String> _ensureCsv(String path) async {
    if (path.toLowerCase().endsWith('.gz')) {
      throw UnsupportedError('Este build sólo acepta CSV plano, no .gz.');
    }
    return path;
  }

  /// Autodetecta separador simple mirando la primera línea (sin considerar comillas anidadas).
  Future<String> _pickDelimiter(File f) async {
    final stream = f.openRead(0, 8192);
    final head = await stream.transform(utf8.decoder).join();
    final firstLine = head.split(RegExp(r'\r?\n')).first;
    final candidates = {',': 0, ';': 0, '|': 0, '\t': 0};
    for (final c in candidates.keys.toList()) {
      candidates[c] = _count(firstLine, c);
    }
    final best = candidates.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return best.value == 0 ? ',' : best.key;
  }

  int _count(String s, String ch) => s.split(ch).length - 1;

  String _s(List row, int idx) {
    if (idx < 0 || idx >= row.length) return '';
    final v = row[idx];
    return v == null ? '' : v.toString();
  }

  /// Acepta enteros con coma o punto; vacío → 0.
  int _i(List row, int idx) {
    if (idx < 0 || idx >= row.length) return 0;
    final s = (row[idx]?.toString() ?? '').trim();
    if (s.isEmpty) return 0;
    final d = double.tryParse(s.replaceAll(',', '.'));
    return d?.round() ?? 0;
  }

  // Normaliza encabezados: quita BOM, tildes, separadores y pone minúsculas.
  String _norm(String s) {
    var t = s.replaceAll('\uFEFF', '').trim().toLowerCase();
    const src = 'áéíóúüñ';
    const dst = 'aeiouun';
    for (var i = 0; i < src.length; i++) {
      t = t.replaceAll(src[i], dst[i]);
    }
    t = t.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return t;
  }

  /// Busca cualquiera de los alias normalizados; si no encuentra y [required]=true, lanza error claro.
  int _colAny(List<String> headers, List<String> aliases, {bool required = true}) {
    final normHeaders = headers.map(_norm).toList();
    final normAliases = aliases.map(_norm).toList();
    for (var i = 0; i < normHeaders.length; i++) {
      if (normAliases.contains(normHeaders[i])) return i;
    }
    if (!required) return -1;
    throw FormatException(
      'CSV_HEADER_MISSING: alguna de ${aliases.join('/')}.\n'
      'Encabezados reales: ${headers.join(', ')}',
    );
  }
}

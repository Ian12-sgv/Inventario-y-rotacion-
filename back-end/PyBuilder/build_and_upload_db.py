# build_and_upload_db.py
# Construye un SQLite desde los CSV .gz (inventario y compras) y lo sube por FTPS a /exports
# Requisitos: python-dotenv (el resto es stdlib)
#   pip install python-dotenv
#
# .env (ejemplo):
#   FTP_HOST=ftp.textilesyessica.com
#   FTP_USER=Reportes@textilesyessica.com
#   FTP_PASS=j305317909
#   FTP_DIR=/exports
#   INV_GZ=D:/ian proyectos/aplicacion/back-end/Exporter/out/inventario.csv.gz
#   COM_GZ=D:/ian proyectos/aplicacion/back-end/ExporterCompras/out/compras.csv.gz

from __future__ import annotations

import os
import csv
import re
import json
import time
import gzip
import hashlib
import sqlite3
import unicodedata
from pathlib import Path
from typing import Tuple, List, Dict, Optional
from ftplib import FTP_TLS
from dotenv import load_dotenv

# =========================
#  Carga configuración
# =========================
load_dotenv()

FTP_HOST = os.environ.get("FTP_HOST", "").strip()
FTP_USER = os.environ.get("FTP_USER", "").strip()
FTP_PASS = os.environ.get("FTP_PASS", "").strip()
FTP_DIR  = os.environ.get("FTP_DIR", "/exports").strip() or "/exports"

INV_GZ   = os.environ.get("INV_GZ", "").strip()
COM_GZ   = os.environ.get("COM_GZ", "").strip()

DB_NAME  = "my_database.db"
DB_GZ    = DB_NAME + ".gz"
MANIFEST = "manifest.json"

# =========================
#  Utilidades generales
# =========================
def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def _norm(s: str) -> str:
    """Normaliza nombre de columna: sin BOM, sin acentos, minúsculas, [a-z0-9]."""
    if not s:
        return ""
    s = s.replace("\ufeff", "").strip()
    s = "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", "", s)
    return s

def _find_col(headers: List[str], candidates: List[str]) -> str:
    """Devuelve el nombre REAL de cabecera que mejor coincide con una lista de candidatos."""
    norm_map = {_norm(h): h for h in headers}
    cand_norm = [_norm(c) for c in candidates]

    # Match exacto por normalización
    for cn in cand_norm:
        if cn in norm_map:
            return norm_map[cn]

    # Match parcial (contains)
    for cn in cand_norm:
        for nh, real in norm_map.items():
            if cn and (cn in nh or nh in cn):
                return real

    raise KeyError(
        f"No se encontró ninguna de estas columnas: {candidates}\n"
        f"Cabeceras disponibles: {headers}"
    )

def open_gz_csv_dict(path: str) -> Tuple[List[str], csv.DictReader, gzip.GzipFile]:
    """
    Abre .gz como CSV con delimitador detectado. Devuelve (headers, dict_reader, file_handle).
    ¡Recuerda cerrar fh.close() al finalizar!
    """
    fh = gzip.open(path, "rt", newline="", encoding="utf-8", errors="replace")
    sample = fh.read(8192)
    fh.seek(0)
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",;|\t")
    except Exception:
        dialect = csv.excel  # por defecto ','

    reader = csv.DictReader(fh, dialect=dialect)
    headers = [(h or "").lstrip("\ufeff").strip() for h in (reader.fieldnames or [])]
    return headers, reader, fh

def gzip_file(src: str, dst_gz: str, level: int = 6) -> None:
    with open(src, "rb") as f_in, gzip.open(dst_gz, "wb", compresslevel=level) as f_out:
        for chunk in iter(lambda: f_in.read(1024 * 1024), b""):
            f_out.write(chunk)

# =========================
#  FTPS helpers
# =========================
def _ftps_connect() -> FTP_TLS:
    ftps = FTP_TLS()
    ftps.connect(FTP_HOST, 21, timeout=45)
    ftps.auth()   # AUTH TLS
    ftps.prot_p() # canal de datos protegido
    ftps.login(FTP_USER, FTP_PASS)
    return ftps

def upload_ftps(local_path: str, remote_name: str) -> None:
    """Sube un archivo por FTPS con rename atómico y VERIFICACIÓN DE TAMAÑO."""
    ftps = _ftps_connect()
    try:
        # Ir a /exports (crearlo si no existe)
        try:
            ftps.cwd(FTP_DIR)
        except Exception:
            try:
                ftps.mkd(FTP_DIR)
            except Exception:
                pass
            ftps.cwd(FTP_DIR)

        tmp_name = remote_name + ".part"

        # Limpieza de .part huérfano
        try:
            ftps.delete(tmp_name)
        except Exception:
            pass

        # === SUBIR a .part ===
        with open(local_path, "rb") as f:
            ftps.storbinary(f"STOR {tmp_name}", f, blocksize=1024 * 128)

        # === RENAME ATÓMICO ===
        try:
            ftps.delete(remote_name)
        except Exception:
            pass
        ftps.rename(tmp_name, remote_name)

        # === VERIFICACIÓN DE TAMAÑO ===
        # (Pure-FTPd soporta SIZE y devuelve bytes)
        resp = []
        try:
            ftps.retrlines("LIST " + remote_name, resp.append)  # opcional, útil para depurar
        except Exception:
            pass

        remote_sz = ftps.size(remote_name)  # bytes
        local_sz = os.path.getsize(local_path)

        if remote_sz is None or int(remote_sz) != int(local_sz):
            # Intento de limpieza del remoto corrupto
            try:
                ftps.delete(remote_name)
            except Exception:
                pass
            raise RuntimeError(f"SIZE mismatch: remote={remote_sz} local={local_sz}")

        print(f"[OK] Subida verificada. ({local_sz} bytes)")
    finally:
        try:
            ftps.quit()
        except Exception:
            pass

def download_ftps_file(remote_path: str, local_path: str) -> None:
    ftps = _ftps_connect()
    try:
        dirn, name = os.path.split(remote_path)
        if dirn:
            ftps.cwd(dirn)
        Path(local_path).parent.mkdir(parents=True, exist_ok=True)
        with open(local_path, "wb") as f:
            ftps.retrbinary(f"RETR " + name, f.write)
    finally:
        try:
            ftps.quit()
        except Exception:
            pass

def ensure_local_csv_gz(local_path: str, remote_name: str) -> str:
    """
    Si local_path existe lo usa; si no, descarga remote_name (p. ej. '/exports/inventario.csv.gz')
    a 'tmp/<filename>.gz' y devuelve esa ruta.
    """
    if local_path and Path(local_path).exists():
        return local_path

    fname = Path(remote_name).name
    tmp = Path("tmp") / fname
    print(f"[*] Local no existe: {local_path or '(no definido)'} → descargando {remote_name} desde FTPS…")
    download_ftps_file(remote_name, str(tmp))
    return str(tmp)

# =========================
#  Build SQLite
# =========================
def build_db(inv_gz: str, com_gz: str, out_db: str) -> Dict[str, int]:
    if Path(out_db).exists():
        Path(out_db).unlink()

    conn = sqlite3.connect(out_db)
    cur  = conn.cursor()

    # PRAGMAs de rendimiento (solo durante la carga)
    cur.execute("PRAGMA journal_mode=WAL;")
    cur.execute("PRAGMA synchronous=OFF;")
    cur.execute("PRAGMA temp_store=MEMORY;")
    cur.execute("PRAGMA cache_size=-20000;")

    # Esquema
    cur.executescript("""
    DROP TABLE IF EXISTS inventarioc;
    DROP TABLE IF EXISTS comprasgalpones;
    DROP TABLE IF EXISTS stock;

    CREATE TABLE inventarioc (
      CodigoBarra TEXT,
      Nombre TEXT,
      Referencia TEXT,
      PrecioDetal TEXT,
      PrecioMayor TEXT,
      PrecioPromocion TEXT,
      CREACION TEXT
    );

    CREATE TABLE comprasgalpones (
      NombreGalpon TEXT,
      CodigoBarra TEXT,
      Referencia TEXT,
      Nombre TEXT,
      Documento TEXT,
      Cantidad INTEGER,
      FechaCompra TEXT
    );

    CREATE TABLE stock (
      CodigoBarra TEXT NOT NULL,
      Tienda TEXT NOT NULL,
      Existencia INTEGER NOT NULL,
      PRIMARY KEY (CodigoBarra, Tienda)
    );
    """)

    # ========== INVENTARIO ==========
    inv_headers, inv_rows, inv_fh = open_gz_csv_dict(inv_gz)
    print("[INFO] Cabeceras inventario:", inv_headers)
    try:
        # Soporta ES/EN: barcode, reference, product_name, price_*, stock, store_name
        c_cod = _find_col(inv_headers, [
            "CodigoBarra","codigo","codigobarra","codigo_barras","codigodebarras","barcode","ean"
        ])
        c_ref = _find_col(inv_headers, [
            "Referencia","ref","reference"
        ])
        c_nom = _find_col(inv_headers, [
            "NombreProducto","Nombre","descripcion","producto","nombre_producto",
            "product_name","productname","product"
        ])

        # columnas opcionales de precio
        try:
            c_pd  = _find_col(inv_headers, [
                "PrecioDetal","precio_detal","precioventa","precio",
                "price_detal","price","retail_price","unit_price"
            ])
        except KeyError:
            c_pd = None
        try:
            c_pm  = _find_col(inv_headers, [
                "PrecioMayor","precio_mayor","mayor",
                "price_mayor","wholesale_price"
            ])
        except KeyError:
            c_pm = None
        try:
            c_pp  = _find_col(inv_headers, [
                "PrecioPromocion","promo","promocion","preciopromocion",
                "price_promo","promo_price","discount_price"
            ])
        except KeyError:
            c_pp = None

        # existencia por tienda
        c_exi = _find_col(inv_headers, [
            "ExistenciaPorTienda","Existencia","stock","existencias","cantidad","qty","quantity"
        ])
        c_tnd = _find_col(inv_headers, [
            "Tienda","NombreTienda","sucursal","almacen","bodega","galpon",
            "store_name","store","shop","branch"
        ])

        print(f"[MAP] inventario: CodigoBarra→{c_cod}, Referencia→{c_ref}, Nombre→{c_nom}, "
              f"PrecioDetal→{c_pd}, PrecioMayor→{c_pm}, PrecioPromocion→{c_pp}, "
              f"Existencia→{c_exi}, Tienda→{c_tnd}")

        def _get(row: Dict[str, str], col: Optional[str]) -> str:
            return "" if col is None else (row.get(col) or "").strip()

        seen_cod = set()
        batch_inv: List[tuple] = []
        batch_stock: List[tuple] = []
        inv_count = 0
        stock_count = 0
        CHUNK = 10_000

        insert_inv_sql = """
            INSERT INTO inventarioc
              (CodigoBarra, Nombre, Referencia, PrecioDetal, PrecioMayor, PrecioPromocion, CREACION)
            VALUES (?,?,?,?,?,?,?)
        """
        insert_stock_sql = """
            INSERT OR REPLACE INTO stock
              (CodigoBarra, Tienda, Existencia)
            VALUES (?,?,?)
        """

        for row in inv_rows:
            cod = _get(row, c_cod)
            if not cod:
                continue

            if cod not in seen_cod:
                seen_cod.add(cod)
                batch_inv.append((
                    cod,
                    _get(row, c_nom),
                    _get(row, c_ref),
                    _get(row, c_pd),
                    _get(row, c_pm),
                    _get(row, c_pp),
                    "",  # CREACION vacío si no existiera
                ))
                inv_count += 1

            tienda = _get(row, c_tnd)
            exi_raw = (row.get(c_exi) or "0").strip()
            try:
                existencia = int(float(exi_raw))
            except Exception:
                existencia = 0

            if tienda:
                batch_stock.append((cod, tienda, existencia))
                stock_count += 1

            if len(batch_inv) >= CHUNK:
                cur.executemany(insert_inv_sql, batch_inv)
                batch_inv.clear()

            if len(batch_stock) >= CHUNK:
                cur.executemany(insert_stock_sql, batch_stock)
                batch_stock.clear()

        if batch_inv:
            cur.executemany(insert_inv_sql, batch_inv)
        if batch_stock:
            cur.executemany(insert_stock_sql, batch_stock)

        # Índices
        cur.execute("CREATE INDEX IF NOT EXISTS idx_inv_codigo ON inventarioc (CodigoBarra);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_stock_codigo ON stock (CodigoBarra);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_stock_tienda ON stock (Tienda);")

    finally:
        try:
            inv_fh.close()
        except Exception:
            pass

    # ========== COMPRAS ==========
    com_headers, com_rows, com_fh = open_gz_csv_dict(com_gz)
    print("[INFO] Cabeceras compras:", com_headers)
    try:
        cc_cod = _find_col(com_headers, [
            "CodigoBarra","codigo","codigobarra","barcode","ean"
        ])
        cc_ref = _find_col(com_headers, [
            "Referencia","ref","reference"
        ])
        cc_nom = _find_col(com_headers, [
            "NombreProducto","Nombre","descripcion","producto",
            "product_name","productname","product"
        ])
        cc_doc = _find_col(com_headers, [
            "Documento","doc","numdoc","document","invoice","receipt","doc_number","documento"
        ])
        cc_can = _find_col(com_headers, [
            "Cantidad","cantidad","cant","qty","quantity"
        ])
        cc_fec = _find_col(com_headers, [
            "Fecha","FechaCompra","fecha_compra","fecha","date","purchase_date"
        ])

        print(f"[MAP] compras: CodigoBarra→{cc_cod}, Referencia→{cc_ref}, Nombre→{cc_nom}, "
              f"Documento→{cc_doc}, Cantidad→{cc_can}, Fecha→{cc_fec}")

        CHUNK = 10_000
        batch_com: List[tuple] = []
        com_count = 0

        insert_com_sql = """
            INSERT INTO comprasgalpones
              (NombreGalpon, CodigoBarra, Referencia, Nombre, Documento, Cantidad, FechaCompra)
            VALUES (?,?,?,?,?,?,?)
        """

        for row in com_rows:
            cant_raw = (row.get(cc_can) or "0").strip()
            try:
                cantidad = int(float(cant_raw))
            except Exception:
                cantidad = 0

            batch_com.append((
                "",  # NombreGalpon no viene en el CSV actual
                (row.get(cc_cod) or "").strip(),
                (row.get(cc_ref) or "").strip(),
                (row.get(cc_nom) or "").strip(),
                (row.get(cc_doc) or "").strip(),
                cantidad,
                (row.get(cc_fec) or "").strip(),
            ))
            com_count += 1

            if len(batch_com) >= CHUNK:
                cur.executemany(insert_com_sql, batch_com)
                batch_com.clear()

        if batch_com:
            cur.executemany(insert_com_sql, batch_com)

        # Índices
        cur.execute("CREATE INDEX IF NOT EXISTS idx_compras_codigo ON comprasgalpones (CodigoBarra);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_compras_fecha ON comprasgalpones (FechaCompra DESC);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_compras_doc   ON comprasgalpones (Documento);")

    finally:
        try:
            com_fh.close()
        except Exception:
            pass

    conn.commit()

    # Restaurar durabilidad estándar y compactar
    cur.execute("PRAGMA synchronous=NORMAL;")
    cur.execute("VACUUM;")
    conn.close()

    return {"inv_rows": inv_count, "stock_rows": stock_count, "com_rows": com_count}

# =========================
#  Main
# =========================
def main() -> None:
    if not FTP_HOST or not FTP_USER or not FTP_PASS:
        raise RuntimeError("Faltan variables FTP_HOST/FTP_USER/FTP_PASS en .env")

    out_dir = Path("output")
    out_dir.mkdir(parents=True, exist_ok=True)

    db_path    = str(out_dir / DB_NAME)
    db_gz_path = str(out_dir / DB_GZ)
    man_path   = str(out_dir / MANIFEST)

    t0 = time.time()
    print("[*] Construyendo SQLite desde CSV…")

    # Asegura fuentes locales; si no existen intenta bajar del FTP fijo (/exports/xxx)
    inv_local = ensure_local_csv_gz(INV_GZ, f"{FTP_DIR}/inventario.csv.gz")
    com_local = ensure_local_csv_gz(COM_GZ, f"{FTP_DIR}/compras.csv.gz")

    stats = build_db(inv_local, com_local, db_path)
    print(f"    inventarioc: {stats['inv_rows']} filas")
    print(f"    stock      : {stats['stock_rows']} filas")
    print(f"    compras    : {stats['com_rows']} filas")

    print("[*] Comprimiendo DB…")
    if Path(db_gz_path).exists():
        Path(db_gz_path).unlink()
    gzip_file(db_path, db_gz_path, level=9)
    sha = sha256_file(db_gz_path)

    # Manifest opcional (trazabilidad)
    man = {
        "db_gz": DB_GZ,
        "sha256": sha,
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "rows": stats,
    }
    with open(man_path, "w", encoding="utf-8") as mf:
        json.dump(man, mf, ensure_ascii=False, indent=2)

    print("[*] Subiendo por FTPS (rename atómico)…")
    upload_ftps(db_gz_path, DB_GZ)
    upload_ftps(man_path, MANIFEST)

    print(f"[OK] Listo en {time.time()-t0:.2f}s → {DB_GZ} (sha256={sha[:12]}…)")

if __name__ == "__main__":
    main()

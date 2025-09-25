# Aplicación Inventario (Flutter + .NET Exporter)

Monorepo con:
- `back-end/Exporter` (.NET 8) → consulta SQL → CSV → GZIP → FTP (FileZilla)
- `app/` (Flutter) → descarga `.gz`, descomprime y carga en SQLite

## Configuración rápida

1. Copiar `appsettings.example.json` a `appsettings.json` y completar credenciales (NO lo subas a Git).
2. Backend:
   ```bash
   cd back-end/Exporter
   dotnet build -c Release
   dotnet run   -c Release

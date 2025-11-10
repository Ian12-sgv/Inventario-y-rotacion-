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

Test-Path .\appsettings.json      
Get-Content .\appsettings.json | Write-Host      
dotnet run -c Release

3. front

flutter clean                    
flutter pub get
flutter run -t lib/main.dart

4. para crear el apk

flutter pub get                  
dart run flutter_launcher_icons
flutter build apk --release  

https
reiniciar y correr de nuevo

# Ver si está escuchando
netstat -ano | findstr :5100

# (si está corriendo) Apaga el servicio
nssm stop ExporterApi   # o: sc stop ExporterApi

# Verifica que ya liberó el puerto
netstat -ano | findstr :5100

# Ahora sí, corre en consola
dotnet run
Cuando termines, vuelve a dejar el servicio en producción:

powershell
Copiar código
nssm start ExporterApi
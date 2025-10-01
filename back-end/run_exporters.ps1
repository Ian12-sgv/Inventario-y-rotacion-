# run_exporters.ps1
# Compila y ejecuta Exporter y ExporterCompras en Release y guarda logs con timestamp.

$ErrorActionPreference = 'Stop'

# Rutas de los proyectos (.csproj)
$EXP_INV = 'D:\ian proyectos\aplicacion\back-end\Exporter'
$EXP_COM = 'D:\ian proyectos\aplicacion\back-end\ExporterCompras'

# dotnet (ruta completa si PATH no está disponible en el Programador de tareas)
$DOTNET = "$env:ProgramFiles\dotnet\dotnet.exe"
if (-not (Test-Path $DOTNET)) { $DOTNET = 'dotnet' }

# Carpeta de logs
$LOGDIR = 'D:\ian proyectos\aplicacion\back-end\logs'
New-Item -ItemType Directory -Force -Path $LOGDIR | Out-Null

$ts = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

function Invoke-Exporter {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Dir
    )
    $log = Join-Path $LOGDIR "$Name`_$ts.log"
    try {
        "[$(Get-Date)] ===== $Name START =====" | Tee-Object -FilePath $log -Append | Out-Null
        Push-Location $Dir

        # Build
        "[$(Get-Date)] dotnet build -c Release" | Tee-Object -FilePath $log -Append | Out-Null
        & $DOTNET build -c Release *>> $log
        if ($LASTEXITCODE -ne 0) {
            throw "BUILD FAILED ($Name) exit $LASTEXITCODE"
        }

        # Run
        "[$(Get-Date)] dotnet run -c Release" | Tee-Object -FilePath $log -Append | Out-Null
        & $DOTNET run -c Release *>> $log
        if ($LASTEXITCODE -ne 0) {
            throw "RUN FAILED ($Name) exit $LASTEXITCODE"
        }

        "[$(Get-Date)] ===== $Name OK =====" | Tee-Object -FilePath $log -Append | Out-Null
        return $true
    }
    catch {
        "[$(Get-Date)] *** $Name ERROR: $($_.Exception.Message)" | Tee-Object -FilePath $log -Append | Out-Null
        return $false
    }
    finally {
        Pop-Location | Out-Null
    }
}

$ok1 = Invoke-Exporter -Name 'Exporter'        -Dir $EXP_INV
$ok2 = Invoke-Exporter -Name 'ExporterCompras' -Dir $EXP_COM

if ($ok1 -and $ok2) { exit 0 } else { exit 1 }

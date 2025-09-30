using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Globalization;
using FluentFTP;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

#region POCOs de config
public sealed class SqlConfig { public string ConnectionString { get; init; } = ""; }
public sealed class FtpConfig {
    public string Host { get; init; } = "";
    public int Port { get; init; } = 21;
    public string User { get; init; } = "";
    public string Pass { get; init; } = "";
    public string RemoteDir { get; init; } = "/exports";
    public bool UseFtpes { get; init; } = true;
}
public sealed class OutputConfig {
    public string Directory { get; init; } = "out";
    public string CsvName { get; init; } = "inventario.csv";
}
public sealed class QueryConfig { public string SqlText { get; init; } = ""; }
#endregion

public static class Program {
    public static async Task<int> Main() {
        var cfg    = BuildConfig();
        var sql    = cfg.GetRequiredSection("Sql").Get<SqlConfig>()!;
        var ftpCfg = cfg.GetRequiredSection("Ftp").Get<FtpConfig>()!;
        var outCfg = cfg.GetRequiredSection("Output").Get<OutputConfig>()!;
        var qry    = cfg.GetRequiredSection("Query").Get<QueryConfig>()!;

        var outDir   = Path.GetFullPath(outCfg.Directory);
        Directory.CreateDirectory(outDir);
        var csvPath  = Path.Combine(outDir, outCfg.CsvName);

        var remoteDir   = TrimSlash(ftpCfg.RemoteDir);
        var tmpRemote   = $"{remoteDir}/{outCfg.CsvName}.part";
        var finalRemote = $"{remoteDir}/{outCfg.CsvName}";

        try {
            Log("=== ExporterInventario (CSV plano) ===");

            Log("1) SQL → CSV …");
            await ExportCsvAsync(sql.ConnectionString, qry.SqlText, csvPath);

            Log($"2) FTP conectar {(ftpCfg.UseFtpes ? "(FTPS explícito)" : "(FTP plano)")} …");
            using var client = new FtpClient(ftpCfg.Host, ftpCfg.User, ftpCfg.Pass, ftpCfg.Port) {
                Config = {
                    EncryptionMode         = ftpCfg.UseFtpes ? FtpEncryptionMode.Explicit : FtpEncryptionMode.None,
                    ValidateAnyCertificate = ftpCfg.UseFtpes, // en PROD valida tu cert real
                    DataConnectionType     = FtpDataConnectionType.AutoPassive,
                    ReadTimeout            = 30000,
                    ConnectTimeout         = 15000
                }
            };

            client.Connect();

            Log($"2.1) Asegurar directorio remoto: {remoteDir}");
            client.CreateDirectory(remoteDir);

            Log($"2.2) Subiendo temporal: {tmpRemote}");
            var status = client.UploadFile(
                localPath: csvPath,
                remotePath: tmpRemote,
                existsMode: FtpRemoteExists.Overwrite,
                createRemoteDir: true
            );
            if (status != FtpStatus.Success && status != FtpStatus.Skipped)
                throw new Exception($"Upload status inesperado: {status}");

            Log("2.3) Rename atómico a destino final …");
            if (client.FileExists(finalRemote))
                client.DeleteFile(finalRemote);
            client.Rename(tmpRemote, finalRemote);

            Log("OK ✅ Proceso completado (CSV)");
            client.Disconnect();
            return 0;
        } catch (Exception ex) {
            Log($"ERROR ❌ {ex.GetType().Name}: {ex.Message}");
            Log(ex.StackTrace ?? "");
            return 1;
        }
    }

    #region Helpers
    private static IConfiguration BuildConfig() =>
        new ConfigurationBuilder()
            .SetBasePath(Directory.GetCurrentDirectory())
            .AddJsonFile("appsettings.json", optional: true, reloadOnChange: false)
            .AddEnvironmentVariables()
            .Build();

    private static string TrimSlash(string s) => string.IsNullOrWhiteSpace(s) ? "" : s.Replace('\\', '/').TrimEnd('/');

    private static void Log(string msg) => Console.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {msg}");

    // Escribe CSV UTF-8 sin BOM, con comas y comillas escapadas.
    // Números/fechas en CultureInfo.InvariantCulture → punto decimal.
    private static async Task ExportCsvAsync(string connStr, string sql, string csvPath) {
        await using var conn = new SqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var rdr = await cmd.ExecuteReaderAsync();

        await using var fs = new FileStream(csvPath, FileMode.Create, FileAccess.Write, FileShare.None);
        await using var sw = new StreamWriter(fs, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)) {
            NewLine = "\n" // normaliza a LF (opcional)
        };

        // Encabezados
        for (int i = 0; i < rdr.FieldCount; i++) {
            if (i > 0) await sw.WriteAsync(',');
            await sw.WriteAsync(rdr.GetName(i));
        }
        await sw.WriteLineAsync();

        // Filas
        while (await rdr.ReadAsync()) {
            for (int i = 0; i < rdr.FieldCount; i++) {
                if (i > 0) await sw.WriteAsync(',');
                var cell = FormatValue(rdr.GetValue(i)); // invariante
                await sw.WriteAsync(CsvEscape(cell));
            }
            await sw.WriteLineAsync();
        }
        await sw.FlushAsync();
    }

    private static string FormatValue(object? v) {
        if (v is null || v is DBNull) return "";
        // Fuerza punto decimal y formato estable para números y fechas
        return v switch {
            IFormattable f => f.ToString(null, CultureInfo.InvariantCulture) ?? "",
            _ => v.ToString() ?? ""
        };
    }

    private static string CsvEscape(string s) {
        bool needsQuotes = s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r');
        return needsQuotes ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
    }
    #endregion
}

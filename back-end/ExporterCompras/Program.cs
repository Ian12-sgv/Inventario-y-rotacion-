using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Threading.Tasks;
using FluentFTP;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

#region Config POCOs
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
    public string CsvName { get; init; } = "compras.csv";
    public string GzipName { get; init; } = "compras.csv.gz";
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
        var gzPath   = Path.Combine(outDir, outCfg.GzipName);

        var tmpRemote   = $"{TrimSlash(ftpCfg.RemoteDir)}/{outCfg.GzipName}.part";
        var finalRemote = $"{TrimSlash(ftpCfg.RemoteDir)}/{outCfg.GzipName}";

        try {
            Log("=== ExporterCompras ===");

            Log("1) SQL → CSV …");
            await ExportCsvAsync(sql.ConnectionString, qry.SqlText, csvPath);

            Log("2) CSV → GZIP …");
            Gzip(csvPath, gzPath);

            Log($"3) FTP conectar {(ftpCfg.UseFtpes ? "(FTPS explícito)" : "(FTP plano)")} …");
            using var client = new FtpClient(ftpCfg.Host, ftpCfg.User, ftpCfg.Pass, ftpCfg.Port);
            client.Config.EncryptionMode         = ftpCfg.UseFtpes ? FtpEncryptionMode.Explicit : FtpEncryptionMode.None;
            client.Config.ValidateAnyCertificate = ftpCfg.UseFtpes; // en PROD valida tu cert real
            client.Config.DataConnectionType     = FtpDataConnectionType.AutoPassive;
            client.Config.ReadTimeout            = 30000;
            client.Config.ConnectTimeout         = 15000;

            client.Connect();

            Log($"3.1) Asegurar directorio remoto: {ftpCfg.RemoteDir}");
            client.CreateDirectory(ftpCfg.RemoteDir);

            Log($"3.2) Subiendo temporal: {tmpRemote}");
            var status = client.UploadFile(
                localPath: gzPath,
                remotePath: tmpRemote,
                existsMode: FtpRemoteExists.Overwrite,
                createRemoteDir: true
            );
            if (status != FtpStatus.Success && status != FtpStatus.Skipped)
                throw new Exception($"Upload status inesperado: {status}");

            Log("3.3) Rename atómico a destino final …");
            if (client.FileExists(finalRemote))
                client.DeleteFile(finalRemote);

            client.Rename(tmpRemote, finalRemote);

            Log("OK ✅ Proceso completado");
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

    private static async Task ExportCsvAsync(string connStr, string sql, string csvPath) {
        await using var conn = new SqlConnection(connStr);
        await conn.OpenAsync();

        await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
        await using var rdr = await cmd.ExecuteReaderAsync();

        await using var fs = new FileStream(csvPath, FileMode.Create, FileAccess.Write, FileShare.None);
        await using var sw = new StreamWriter(fs, new UTF8Encoding(false)); // UTF-8 sin BOM

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
                string cell = rdr.IsDBNull(i) ? "" : rdr.GetValue(i).ToString() ?? "";
                await sw.WriteAsync(CsvEscape(cell));
            }
            await sw.WriteLineAsync();
        }
        await sw.FlushAsync();
    }

    private static string CsvEscape(string s) {
        bool needsQuotes = s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r');
        return needsQuotes ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
    }

    private static void Gzip(string inputPath, string outputPath) {
        using var src = new FileStream(inputPath, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var dst = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None);
        using var gz  = new GZipStream(dst, CompressionLevel.SmallestSize);
        src.CopyTo(gz);
    }
    #endregion
}

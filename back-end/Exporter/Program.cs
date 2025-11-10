// Program.cs
using System;
using System.Collections.Generic;
using System.Data;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.SqlClient;
using Microsoft.AspNetCore.Builder; // WebApplication
using Microsoft.AspNetCore.Http;    // Results, StatusCodes

// ===== Build =====
var builder = WebApplication.CreateBuilder(args);

// Carga de configuración (appsettings.json + variables de entorno)
builder.Configuration
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: false, reloadOnChange: false)
    .AddEnvironmentVariables();

var cfg     = builder.Configuration;
var apiKey  = cfg["ApiKey"] ?? throw new InvalidOperationException("Falta ApiKey en appsettings.json");
var sqlCfg  = cfg.GetRequiredSection("Sql").Get<SqlConfig>()!;
var qryCfg  = cfg.GetRequiredSection("Query").Get<QueryConfig>()!;
var connStr = sqlCfg.ConnectionString;
var sqlText = qryCfg.SqlText;

var app = builder.Build();

// ===== Auth por API-Key (solo /api/*) =====
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        var key = ctx.Request.Headers["x-api-key"].ToString();
        if (!string.Equals(key, apiKey, StringComparison.Ordinal))
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await ctx.Response.WriteAsJsonAsync(new { error = "invalid_api_key" });
            return;
        }
    }
    await next();
});

// ===== Endpoints =====
app.MapGet("/api/ping", () => Results.Ok(new { ok = true }));

// Health público (sin API key)
app.MapGet("/healthz", () => Results.Ok(new { ok = true }));

// SELECT completo → JSON (o CSV con ?format=csv)
app.MapGet("/api/inventario", async (HttpContext http) =>
{
    try
    {
        string format = http.Request.Query["format"];
        if (string.Equals(format, "csv", StringComparison.OrdinalIgnoreCase))
        {
            var bytes = await ExportCsvAsync(connStr, sqlText);
            return Results.File(bytes, "text/csv; charset=utf-8", "inventario.csv");
        }
        else
        {
            var rows = await QueryAsDictsAsync(connStr, sqlText);
            return Results.Ok(rows);
        }
    }
    catch (Exception ex)
    {
        return Results.Problem(title: "Inventario falló", detail: ex.Message, statusCode: 500);
    }
});

// 1) Una sola fila (primera coincidencia por Código de barras)
app.MapGet("/api/productos/{codigo}", async (string codigo) =>
{
    try
    {
        var sql  = WrapWithWhere(sqlText, "CodigoBarra", "= @codigo", outerOrderBy: "ORDER BY src.Tienda, src.Region");
        var rows = await QueryAsDictsAsync(connStr, sql, new SqlParameter("@codigo", codigo));
        return rows.Count == 0 ? Results.NotFound() : Results.Ok(rows[0]);
    }
    catch (Exception ex)
    {
        return Results.Problem(title: "Consulta de producto falló", detail: ex.Message, statusCode: 500);
    }
});

// 2) Todas las sucursales + 3 totales al final
app.MapGet("/api/productos/{codigo}/todas", async (string codigo) =>
{
    try
    {
        var sql  = WrapWithWhere(sqlText, "CodigoBarra", "= @codigo", outerOrderBy: "ORDER BY src.Tienda, src.Region");
        var rows = await QueryAsDictsAsync(connStr, sql, new SqlParameter("@codigo", codigo));
        if (rows.Count == 0) return Results.NotFound();

        // Sumar existencias separando Casa Matriz vs Tiendas
        decimal sumMatriz = 0m, sumTiendas = 0m;
        foreach (var r in rows)
        {
            r.TryGetValue("Existencia", out var exObj);
            r.TryGetValue("Tienda", out var tiendaObj);
            var ex = ToDecimal(exObj);
            var esMatriz = EsCasaMatriz(tiendaObj?.ToString());
            if (esMatriz) sumMatriz += ex; else sumTiendas += ex;
        }
        var total = sumMatriz + sumTiendas;

        // Cabecera de producto para los totales
        var header = rows[0];
        var totMatriz  = CabeceraProducto(header);
        var totTiendas = CabeceraProducto(header);
        var totGeneral = CabeceraProducto(header);

        totMatriz["Tienda"]     = "TOTAL CASA MATRIZ";
        totMatriz["Region"]     = "—";
        totMatriz["Existencia"] = sumMatriz;

        totTiendas["Tienda"]     = "TOTAL TIENDAS";
        totTiendas["Region"]     = "—";
        totTiendas["Existencia"] = sumTiendas;

        totGeneral["Tienda"]     = "TOTAL GENERAL";
        totGeneral["Region"]     = "—";
        totGeneral["Existencia"] = total;

        var outList = new List<Dictionary<string, object?>>(rows.Count + 3);
        outList.AddRange(rows);
        outList.Add(totMatriz);
        outList.Add(totTiendas);
        outList.Add(totGeneral);

        return Results.Ok(outList);
    }
    catch (Exception ex)
    {
        return Results.Problem(title: "Consulta de sucursales falló", detail: ex.Message, statusCode: 500);
    }
});

// 3) Resumen — SOLO TOTALES
app.MapGet("/api/productos/{codigo}/resumen", async (string codigo) =>
{
    try
    {
        var sql  = WrapWithWhere(sqlText, "CodigoBarra", "= @codigo", outerOrderBy: "ORDER BY src.Tienda, src.Region");
        var rows = await QueryAsDictsAsync(connStr, sql, new SqlParameter("@codigo", codigo));
        if (rows.Count == 0) return Results.NotFound();

        decimal sumMatriz = 0m, sumTiendas = 0m;
        foreach (var r in rows)
        {
            var ex = ToDecimal(Get(r, "Existencia"));
            var esMatriz = EsCasaMatriz(Get(r, "Tienda")?.ToString());
            if (esMatriz) sumMatriz += ex; else sumTiendas += ex;
        }
        var total = sumMatriz + sumTiendas;

        var totales = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
        {
            ["casaMatriz"] = sumMatriz,
            ["tiendas"]    = sumTiendas,
            ["general"]    = total
        };

        return Results.Ok(totales);
    }
    catch (Exception ex)
    {
        return Results.Problem(title: "Resumen falló", detail: ex.Message, statusCode: 500);
    }
});

app.Run();

// ===== Helpers =====
static async Task<List<Dictionary<string, object?>>> QueryAsDictsAsync(string connStr, string sql, params SqlParameter[]? parameters)
{
    using var conn = new SqlConnection(connStr);
    await conn.OpenAsync();

    using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
    if (parameters is { Length: > 0 }) cmd.Parameters.AddRange(parameters);

    using var rdr = await cmd.ExecuteReaderAsync();
    var result = new List<Dictionary<string, object?>>(512);

    var names = new string[rdr.FieldCount];
    for (int i = 0; i < rdr.FieldCount; i++) names[i] = rdr.GetName(i);

    while (await rdr.ReadAsync())
    {
        var row = new Dictionary<string, object?>(rdr.FieldCount, StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < rdr.FieldCount; i++)
            row[names[i]] = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
        result.Add(row);
    }
    return result;
}

static async Task<byte[]> ExportCsvAsync(string connStr, string sql)
{
    using var conn = new SqlConnection(connStr);
    await conn.OpenAsync();

    using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 120 };
    using var rdr = await cmd.ExecuteReaderAsync();

    using var ms = new MemoryStream();
    using var sw = new StreamWriter(ms, new UTF8Encoding(false)) { NewLine = "\n" };

    // Encabezados
    for (int i = 0; i < rdr.FieldCount; i++)
    {
        if (i > 0) await sw.WriteAsync(',');
        await sw.WriteAsync(rdr.GetName(i));
    }
    await sw.WriteLineAsync();

    // Filas
    while (await rdr.ReadAsync())
    {
        for (int i = 0; i < rdr.FieldCount; i++)
        {
            if (i > 0) await sw.WriteAsync(',');
            var cell = FormatValue(rdr.IsDBNull(i) ? null : rdr.GetValue(i));
            await sw.WriteAsync(CsvEscape(cell));
        }
        await sw.WriteLineAsync();
    }

    await sw.FlushAsync();
    return ms.ToArray();

    static string FormatValue(object? v) =>
        v is null ? "" :
        v is IFormattable f ? f.ToString(null, CultureInfo.InvariantCulture) ?? "" :
        v.ToString() ?? "";

    static string CsvEscape(string s) =>
        (s.Contains(',') || s.Contains('"') || s.Contains('\n') || s.Contains('\r'))
        ? "\"" + s.Replace("\"", "\"\"") + "\""
        : s;
}

// Quita el último ORDER BY (para permitir envolver en subconsulta)
static string StripOrderBy(string sql)
{
    var s = sql.TrimEnd().TrimEnd(';');
    var idx = LastIndexOfOrdinalIgnoreCase(s, "ORDER BY");
    if (idx < 0) return s;
    return s[..idx].TrimEnd();
}

static int LastIndexOfOrdinalIgnoreCase(string source, string value)
{
    for (int i = source.Length - value.Length; i >= 0; i--)
    {
        if (string.Compare(source, i, value, 0, value.Length, true, CultureInfo.InvariantCulture) == 0)
            return i;
    }
    return -1;
}

// Envuelve el SQL base (sin ORDER BY) y aplica WHERE + ORDER BY externo opcional
static string WrapWithWhere(string originalSql, string column, string opAndParam, string? outerOrderBy = null)
{
    var baseNoOrder = StripOrderBy(originalSql);
    var wrapped = $"SELECT * FROM ({baseNoOrder}) AS src WHERE src.{column} {opAndParam}";
    if (!string.IsNullOrWhiteSpace(outerOrderBy))
        wrapped += " " + outerOrderBy.Trim();
    return wrapped;
}

// Helpers de tipos/valores
static object? Get(Dictionary<string, object?> dict, string key)
{
    dict.TryGetValue(key, out var v);
    return v;
}

static decimal ToDecimal(object? v)
{
    if (v is null || v is DBNull) return 0m;
    try
    {
        return v switch
        {
            decimal d => d,
            double  d => (decimal)d,
            float   f => (decimal)f,
            int     i => i,
            long    l => l,
            string  s => decimal.Parse(s, NumberStyles.Any, CultureInfo.InvariantCulture),
            IConvertible c => Convert.ToDecimal(c, CultureInfo.InvariantCulture),
            _ => 0m
        };
    }
    catch { return 0m; }
}

static bool EsCasaMatriz(string? tienda)
{
    if (string.IsNullOrWhiteSpace(tienda)) return false;
    var t = tienda.ToLowerInvariant();
    // Ajusta según tus nombres reales de matriz
    return t.Contains("matriz") || t.Contains("casa matriz") || t.Contains("principal") || t.Contains("central");
}

// Fila "cabecera" para totales (repite datos del producto)
static Dictionary<string, object?> CabeceraProducto(Dictionary<string, object?> src) =>
    new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
    {
        ["CodigoBarra"]     = Get(src, "CodigoBarra"),
        ["Nombre"]          = Get(src, "Nombre"),
        ["Referencia"]      = Get(src, "Referencia"),
        ["PrecioDetal"]     = Get(src, "PrecioDetal"),
        ["CostoDolar"]      = Get(src, "CostoDolar"),
        ["PrecioMayor"]     = Get(src, "PrecioMayor"),
        ["dolarMayor"]      = Get(src, "dolarMayor"),
        ["PrecioPromocion"] = Get(src, "PrecioPromocion"),
        ["Tienda"]          = null,
        ["Region"]          = null,
        ["Existencia"]      = 0m,
        ["Status"]          = null
    };

// ===== Config =====
public sealed class SqlConfig { public string ConnectionString { get; init; } = ""; }
public sealed class QueryConfig { public string SqlText { get; init; } = ""; }


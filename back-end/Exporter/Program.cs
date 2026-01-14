// Program.cs
using System;
using System.Collections.Generic;
using System.Data;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

using Microsoft.Data.SqlClient;
using Microsoft.AspNetCore.Builder;      // WebApplication
using Microsoft.AspNetCore.Http;         // Results, StatusCodes
using Microsoft.AspNetCore.RateLimiting; // Rate limiting (NET 7+)
using System.Threading.RateLimiting;     // FixedWindowRateLimiterOptions, etc.

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

// ===== Rate Limiting (para escaneos muy rápidos) =====
// Requiere .NET 7/8. Si estás en .NET 6, esto no compila y hay que usar un middleware alterno.
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

    // Respuesta JSON uniforme cuando se excede el límite
    options.OnRejected = async (context, token) =>
    {
        var http = context.HttpContext;

        if (!http.Response.HasStarted)
        {
            http.Response.StatusCode = StatusCodes.Status429TooManyRequests;
            await http.Response.WriteAsJsonAsync(
                new ApiError(
                    code: "scan_too_fast",
                    message: "Escaneo muy rápido. Espera un momento y vuelve a intentar.",
                    traceId: http.TraceIdentifier
                ),
                cancellationToken: token
            );
        }
    };

    // 1 request cada 700ms por cliente (IP). Ajusta Window si deseas.
    options.AddPolicy("scan", httpContext =>
    {
        var key = httpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        return RateLimitPartition.GetFixedWindowLimiter(
            partitionKey: key,
            factory: _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 1,
                Window = TimeSpan.FromMilliseconds(700),
                QueueLimit = 0,
                AutoReplenishment = true
            }
        );
    });
});

var app = builder.Build();

// ===== Auth por API-Key (solo /api/*) =====
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        var key = ctx.Request.Headers["x-api-key"].ToString();
        if (!string.Equals(key, apiKey, StringComparison.Ordinal))
        {
            await Fail(ctx, StatusCodes.Status401Unauthorized, "invalid_api_key", "API key inválida.")
                .ExecuteAsync(ctx);
            return;
        }
    }
    await next();
});

// ===== Activa Rate Limiter =====
app.UseRateLimiter();

// ===== Endpoints =====
app.MapGet("/api/ping", () => Results.Ok(new { ok = true }));

// Health público (sin API key)
app.MapGet("/healthz", () => Results.Ok(new { ok = true }));

// SELECT completo → JSON (o CSV con ?format=csv)
app.MapGet("/api/inventario", async (HttpContext ctx) =>
{
    try
    {
        string format = ctx.Request.Query["format"];

        if (string.Equals(format, "csv", StringComparison.OrdinalIgnoreCase))
        {
            var bytes = await ExportCsvAsync(connStr, sqlText);
            return Results.File(bytes, "text/csv; charset=utf-8", "inventario.csv");
        }
        else
        {
            var rows = await QueryAsDictsAsync(connStr, sqlText);
            AjustarPrecioDetal(rows); // 1.16 y redondeo
            return Results.Ok(rows);
        }
    }
    catch (SqlException ex) when (ex.Number == -2) // timeout SQL Server
    {
        return Fail(ctx, 504, "db_timeout", "La consulta tardó demasiado. Intenta nuevamente.");
    }
    catch (SqlException)
    {
        return Fail(ctx, 503, "db_error", "No se pudo consultar la base de datos. Intenta de nuevo.");
    }
    catch
    {
        return Fail(ctx, 500, "server_error", "Ocurrió un error interno.");
    }
});

// 1) Una sola fila (primera coincidencia por Código de barras)
app.MapGet("/api/productos/{codigo}", async (HttpContext ctx, string codigo) =>
{
    // Validación mínima (ajusta a tu formato real: EAN13, etc.)
    if (string.IsNullOrWhiteSpace(codigo) || codigo.Length < 6)
        return Fail(ctx, 400, "invalid_code", "Código inválido. Vuelve a escanear.");

    try
    {
        var sql  = WrapWithWhere(sqlText, "CodigoBarra", "= @codigo", outerOrderBy: "ORDER BY src.Tienda, src.Region");
        var rows = await QueryAsDictsAsync(connStr, sql, new SqlParameter("@codigo", codigo));
        AjustarPrecioDetal(rows); // 1.16 y redondeo

        if (rows.Count == 0)
            return Fail(ctx, 404, "not_found", "Producto no encontrado.");

        return Results.Ok(rows[0]);
    }
    catch (SqlException ex) when (ex.Number == -2)
    {
        return Fail(ctx, 504, "db_timeout", "La consulta tardó demasiado. Intenta nuevamente.");
    }
    catch (SqlException)
    {
        return Fail(ctx, 503, "db_error", "No se pudo consultar la base de datos. Intenta de nuevo.");
    }
    catch
    {
        return Fail(ctx, 500, "server_error", "Ocurrió un error interno.");
    }
})
.RequireRateLimiting("scan");

// 2) Todas las sucursales + 3 totales al final
app.MapGet("/api/productos/{codigo}/todas", async (HttpContext ctx, string codigo) =>
{
    if (string.IsNullOrWhiteSpace(codigo) || codigo.Length < 6)
        return Fail(ctx, 400, "invalid_code", "Código inválido. Vuelve a escanear.");

    try
    {
        var sql  = WrapWithWhere(sqlText, "CodigoBarra", "= @codigo", outerOrderBy: "ORDER BY src.Tienda, src.Region");
        var rows = await QueryAsDictsAsync(connStr, sql, new SqlParameter("@codigo", codigo));
        AjustarPrecioDetal(rows); // 1.16 y redondeo

        if (rows.Count == 0)
            return Fail(ctx, 404, "not_found", "Producto no encontrado.");

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

        // Si no hay existencia en ningún lado → devolver una sola fila "SIN EXISTENCIA"
        if (total == 0m)
        {
            var header = rows[0];
            var sin = CabeceraProducto(header);
            sin["Tienda"]     = "SIN EXISTENCIA";
            sin["Region"]     = "—";
            sin["Existencia"] = 0m;
            return Results.Ok(new[] { sin });
        }

        // Cabecera de producto para los totales
        var headerOk = rows[0];
        var totMatriz  = CabeceraProducto(headerOk);
        var totTiendas = CabeceraProducto(headerOk);
        var totGeneral = CabeceraProducto(headerOk);

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
    catch (SqlException ex) when (ex.Number == -2)
    {
        return Fail(ctx, 504, "db_timeout", "La consulta tardó demasiado. Intenta nuevamente.");
    }
    catch (SqlException)
    {
        return Fail(ctx, 503, "db_error", "No se pudo consultar la base de datos. Intenta de nuevo.");
    }
    catch
    {
        return Fail(ctx, 500, "server_error", "Ocurrió un error interno.");
    }
})
.RequireRateLimiting("scan");

// 3) Resumen — SOLO TOTALES (con flag si no hay stock)
app.MapGet("/api/productos/{codigo}/resumen", async (HttpContext ctx, string codigo) =>
{
    if (string.IsNullOrWhiteSpace(codigo) || codigo.Length < 6)
        return Fail(ctx, 400, "invalid_code", "Código inválido. Vuelve a escanear.");

    try
    {
        var sql  = WrapWithWhere(sqlText, "CodigoBarra", "= @codigo", outerOrderBy: "ORDER BY src.Tienda, src.Region");
        var rows = await QueryAsDictsAsync(connStr, sql, new SqlParameter("@codigo", codigo));
        if (rows.Count == 0)
            return Fail(ctx, 404, "not_found", "Producto no encontrado.");

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

        if (total == 0m)
        {
            return Results.Ok(new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase)
            {
                ["sinExistencia"] = true,
                ["mensaje"]       = "Producto sin ninguna existencia",
                ["totales"]       = totales
            });
        }

        return Results.Ok(totales);
    }
    catch (SqlException ex) when (ex.Number == -2)
    {
        return Fail(ctx, 504, "db_timeout", "La consulta tardó demasiado. Intenta nuevamente.");
    }
    catch (SqlException)
    {
        return Fail(ctx, 503, "db_error", "No se pudo consultar la base de datos. Intenta de nuevo.");
    }
    catch
    {
        return Fail(ctx, 500, "server_error", "Ocurrió un error interno.");
    }
})
.RequireRateLimiting("scan");

app.Run();

// ===== Helpers (todas las funciones juntas, sin tipos en medio) =====
static IResult Fail(HttpContext ctx, int statusCode, string code, string message) =>
    Results.Json(new ApiError(code, message, ctx.TraceIdentifier), statusCode: statusCode);

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

// Multiplica PrecioDetal por 1.16 y redondea a 2 decimales (AwayFromZero) para endpoints JSON
static void AjustarPrecioDetal(List<Dictionary<string, object?>> rows)
{
    foreach (var r in rows)
    {
        if (r.TryGetValue("PrecioDetal", out var v) && v is not null && v is not DBNull)
        {
            var valor = ToDecimal(v) * 1.16m;
            r["PrecioDetal"] = RedondearMoneda(valor);
        }
    }
}

// Redondeo de moneda a 2 decimales con AwayFromZero (típico de importes)
static decimal RedondearMoneda(decimal v) =>
    Math.Round(v, 2, MidpointRounding.AwayFromZero);

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

    // Detectar índice de la columna PrecioDetal (case-insensitive)
    int idxPrecioDetal = -1;
    for (int i = 0; i < rdr.FieldCount; i++)
    {
        if (string.Equals(rdr.GetName(i), "PrecioDetal", StringComparison.OrdinalIgnoreCase))
        {
            idxPrecioDetal = i;
            break;
        }
    }

    // Filas
    while (await rdr.ReadAsync())
    {
        for (int i = 0; i < rdr.FieldCount; i++)
        {
            if (i > 0) await sw.WriteAsync(',');

            object? raw = rdr.IsDBNull(i) ? null : rdr.GetValue(i);
            if (i == idxPrecioDetal && raw is not null)
            {
                var valor = ToDecimal(raw) * 1.16m;
                raw = RedondearMoneda(valor); // redondeo en CSV
            }

            var cell = FormatValue(raw);
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

// ===== Tipos (todos juntos al final) =====
public sealed record ApiError(string code, string message, string? traceId = null);

public sealed class SqlConfig { public string ConnectionString { get; init; } = ""; }
public sealed class QueryConfig { public string SqlText { get; init; } = ""; }

// Program.cs
using System;
using System.Collections.Generic;
using System.IO;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

// ===== Build =====
var builder = WebApplication.CreateBuilder(args);

// Configuración
builder.Configuration
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: false, reloadOnChange: false)
    .AddEnvironmentVariables();

var cfg = builder.Configuration;

var apiKey = cfg["ApiKey"]
    ?? throw new InvalidOperationException("Falta ApiKey en appsettings.json");

var sqlCfg = cfg.GetRequiredSection("Sql").Get<SqlConfig>()
    ?? throw new InvalidOperationException("Section 'Sql' not found in configuration.");

var qryCfg = cfg.GetRequiredSection("Query").Get<QueryConfig>()
    ?? throw new InvalidOperationException("Section 'Query' not found in configuration.");

var connStr = sqlCfg.ConnectionString;
var sqlText = qryCfg.SqlText;

// ===== CORS =====
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowBlumer", policy =>
    {
        policy
            // PON aquí los orígenes de tu app (Netlify / dominio propio)
            .WithOrigins(
                "https://blumer.netlify.app",
                "https://blumer.apipalacio.com"
            )
            .AllowAnyHeader()
            .AllowAnyMethod();
    });
});

var app = builder.Build();

// CORS primero
app.UseCors("AllowBlumer");

// ===== Middleware de API-Key (pero dejando pasar OPTIONS) =====
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api") &&
        !HttpMethods.IsOptions(ctx.Request.Method)) // <-- dejamos pasar preflight
    {
        if (!ctx.Request.Headers.TryGetValue("x-api-key", out var values) ||
            values.Count == 0 ||
            !string.Equals(values[0], apiKey, StringComparison.Ordinal))
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await ctx.Response.WriteAsync("Missing or invalid API key.");
            return;
        }
    }

    await next();
});

// ===== Endpoints básicos =====
app.MapGet("/", () =>
    Results.Ok(new
    {
        status = "ok",
        service = "tasa",
        timeUtc = DateTime.UtcNow
    }));

app.MapGet("/health", () => Results.Ok("OK"));

// ===== Endpoint principal: /api/tasa =====
app.MapGet("/api/tasa", async () =>
{
    var result = new List<TasaDto>();

    await using var conn = new SqlConnection(connStr);
    await conn.OpenAsync();

    await using var cmd = new SqlCommand(sqlText, conn);
    await using var reader = await cmd.ExecuteReaderAsync();

    while (await reader.ReadAsync())
    {
        var fecha = reader.GetString(0);     // CONVERT(CHAR(16), ...) -> string
        var valor = reader.GetDecimal(1);    // decimal

        result.Add(new TasaDto(fecha, valor));
    }

    return Results.Ok(result);
});

app.Run();

// ===== Clases de config / DTO =====
public sealed class SqlConfig
{
    public string ConnectionString { get; set; } = string.Empty;
}

public sealed class QueryConfig
{
    public string SqlText { get; set; } = string.Empty;
}

public sealed record TasaDto(string Fecha, decimal Valor);

using System.IO.Abstractions;
using Azure.DataApiBuilder.Core.AuthenticationHelpers;
using Azure.DataApiBuilder.Core.AuthenticationHelpers.UnauthenticatedAuthentication;
using Azure.DataApiBuilder.Auth;
using Azure.DataApiBuilder.Core.Authorization;
using Azure.DataApiBuilder.Core.Resolvers;
using Azure.DataApiBuilder.Core.Models;
using Azure.DataApiBuilder.Core.Services.Cache;
using Microsoft.AspNetCore.Authorization;
using ZiggyCreatures.Caching.Fusion;
using Azure.DataApiBuilder.Config;
using Azure.DataApiBuilder.Config.ObjectModel;
using Azure.DataApiBuilder.Core.Configurations;
using Azure.DataApiBuilder.Core.Services;
using Azure.DataApiBuilder.Core.Resolvers.Factories;
using Azure.DataApiBuilder.Core.Services.MetadataProviders;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Routing;

var secretTokens = new List<string>();
var envFile = Environment.GetEnvironmentVariable("DAB_ENV_FILE");
if (!string.IsNullOrEmpty(envFile))
{
    foreach (var entry in DotNetEnv.Env.Load(envFile))
    {
        try
        {
            var connection = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(entry.Value);
            if (!string.Equals(connection.InitialCatalog, "northwind", StringComparison.OrdinalIgnoreCase)) continue;
            secretTokens.AddRange(new[] { entry.Value, connection.DataSource, connection.UserID, connection.Password }.Where(value => !string.IsNullOrEmpty(value)));
            if (string.Equals(Environment.GetEnvironmentVariable("DAB_TRUST_SERVER_CERTIFICATE"), "true", StringComparison.OrdinalIgnoreCase))
            {
                connection.TrustServerCertificate = true;
                connection.Encrypt = true;
                Console.WriteLine("Spike connection override: Encrypt=True; TrustServerCertificate=True.");
            }
            secretTokens.Add(connection.ConnectionString);
            Environment.SetEnvironmentVariable("DAB_CONNECTION_STRING", connection.ConnectionString);
            Console.WriteLine("Configured database: northwind; connection details suppressed.");
            break;
        }
        catch (ArgumentException) { }
    }
}
var builder = WebApplication.CreateBuilder(args.Where(argument => argument != "--initialize" && argument != "--verify").ToArray());
builder.Logging.ClearProviders(); // DAB configuration contains secrets: never log it.
builder.Services.AddControllers();
builder.Services.AddHttpContextAccessor();
builder.Services.AddAuthorization();
builder.Services.AddAuthentication().AddUnauthenticatedAuthentication();
builder.Services.AddSingleton<IFileSystem, FileSystem>();
builder.Services.AddSingleton<HotReloadEventHandler<HotReloadEventArgs>>();
builder.Services.AddSingleton<RuntimeConfigLoader>(services => new FileSystemRuntimeConfigLoader(
    services.GetRequiredService<IFileSystem>(),
    services.GetRequiredService<HotReloadEventHandler<HotReloadEventArgs>>(),
    Path.Combine(builder.Environment.ContentRootPath, "dab-config.json"),
    Environment.GetEnvironmentVariable("DAB_CONNECTION_STRING"),
    false,
    services.GetRequiredService<ILogger<FileSystemRuntimeConfigLoader>>()));
builder.Services.AddSingleton<RuntimeConfigProvider>();
builder.Services.AddSingleton<RuntimeConfigValidator>();
builder.Services.AddSingleton<IQueryEngineFactory, QueryEngineFactory>();
builder.Services.AddSingleton<IMutationEngineFactory, MutationEngineFactory>();
builder.Services.AddSingleton<IAbstractQueryManagerFactory, QueryManagerFactory>();
builder.Services.AddSingleton<IMetadataProviderFactory, MetadataProviderFactory>();
builder.Services.AddSingleton<RequestValidator>();
builder.Services.AddSingleton<CosmosClientProvider>();
builder.Services.AddSingleton<GQLFilterParser>();
builder.Services.AddSingleton<IAuthorizationResolver, AuthorizationResolver>();
builder.Services.AddSingleton<IAuthorizationHandler, RestAuthorizationHandler>();
builder.Services.AddSingleton<IFusionCache>(_ => new FusionCache(new FusionCacheOptions()));
builder.Services.AddSingleton<DabCacheService>();
builder.Services.AddSingleton<RestService>();
var app = builder.Build();
app.Use(async (context, next) =>
{
    context.Response.Headers["X-Spike-Process-Id"] = Environment.ProcessId.ToString();
    try { await next(context); }
    catch (Exception failure)
    {
        var sanitized = failure.ToString();
        foreach (var token in secretTokens.OrderByDescending(value => value.Length)) sanitized = sanitized.Replace(token, "[REDACTED]", StringComparison.Ordinal);
        Console.WriteLine(sanitized);
        context.Response.StatusCode = 500;
        await context.Response.WriteAsJsonAsync(new { error = failure.GetType().Name });
    }
});
app.UseAuthentication();
app.UseClientRoleHeaderAuthenticationMiddleware();
app.UseAuthorization();
app.UseClientRoleHeaderAuthorizationMiddleware();
app.MapGet("/host", () => new { source = "host", processId = Environment.ProcessId, framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription });
// This adapter is independently authored against the actual Core public API.
app.MapGet("/api/Products", async (HttpContext context, RestService rest) =>
{
    var result = await rest.ExecuteAsync("Products", EntityActionOperation.Read, null);
    if (result is null) { context.Response.StatusCode = 204; return; }
    await result.ExecuteResultAsync(new ActionContext(context, context.GetRouteData(), new ActionDescriptor()));
});

if (args.Contains("--initialize") || args.Contains("--verify"))
{
    try
    {
        var provider = app.Services.GetRequiredService<RuntimeConfigProvider>();
        _ = provider.GetConfig();
        Console.WriteLine("Runtime configuration loaded.");
        var metadata = app.Services.GetRequiredService<IMetadataProviderFactory>();
        await metadata.InitializeAsync();
        var metadataFailures = metadata.GetAllMetadataExceptions();
        if (metadataFailures.Count > 0) throw new AggregateException(metadataFailures);
        Console.WriteLine("Database metadata initialized.");
        _ = app.Services.GetRequiredService<RestService>();
        Console.WriteLine("RestService activated.");
    }
    catch (Exception failure)
    {
        var sanitized = failure.ToString();
        foreach (var token in secretTokens.OrderByDescending(value => value.Length)) sanitized = sanitized.Replace(token, "[REDACTED]", StringComparison.Ordinal);
        Console.WriteLine(sanitized);
        for (Exception? current = failure; current is not null; current = current.InnerException)
        {
            Console.WriteLine($"Initialization failure: {current.GetType().FullName}");
            if (current is FileNotFoundException missing) Console.WriteLine($"Missing assembly: {missing.FileName}");
        }
        Environment.ExitCode = 1;
        return;
    }
}
if (args.Contains("--verify"))
{
    try
    {
        await app.StartAsync();
        using var client = new HttpClient { BaseAddress = new Uri(app.Urls.Single()) };
        foreach (var route in new[] { "/host", "/api/Products?$first=2" })
        {
            using var response = await client.GetAsync(route);
            var responseProcess = response.Headers.GetValues("X-Spike-Process-Id").Single();
            if (!response.IsSuccessStatusCode || responseProcess != Environment.ProcessId.ToString())
                throw new InvalidOperationException("HTTP proof failed status or same-process check.");
            Console.WriteLine($"HTTP {(int)response.StatusCode} {route}; processId={responseProcess}");
            var body = await response.Content.ReadAsStringAsync();
            Console.WriteLine(body);
            if (route.StartsWith("/api"))
            {
                using var document = System.Text.Json.JsonDocument.Parse(body);
                var rows = document.RootElement.GetProperty("value");
                if (rows.GetArrayLength() != 2 || rows[0].GetProperty("ProductID").GetInt32() != 1 || rows[1].GetProperty("ProductID").GetInt32() != 2)
                    throw new InvalidOperationException("DAB sample row verification failed.");
            }
        }
        using var connection = new Microsoft.Data.SqlClient.SqlConnection(Environment.GetEnvironmentVariable("DAB_CONNECTION_STRING"));
        await connection.OpenAsync();
        using var countCommand = new Microsoft.Data.SqlClient.SqlCommand("SELECT COUNT(*) FROM dbo.Products", connection);
        var count = Convert.ToInt32(await countCommand.ExecuteScalarAsync());
        Console.WriteLine($"SQL verification: database=northwind; table=dbo.Products; rowCount={count}");
        using var columnsCommand = new Microsoft.Data.SqlClient.SqlCommand("SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA='dbo' AND TABLE_NAME='Products' ORDER BY ORDINAL_POSITION", connection);
        using (var reader = await columnsCommand.ExecuteReaderAsync())
            while (await reader.ReadAsync()) Console.WriteLine($"COLUMN {reader.GetString(0)} {reader.GetString(1)} nullable={reader.GetString(2)}");
        using var keyCommand = new Microsoft.Data.SqlClient.SqlCommand("SELECT k.COLUMN_NAME FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS t JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE k ON t.CONSTRAINT_NAME=k.CONSTRAINT_NAME AND t.TABLE_SCHEMA=k.TABLE_SCHEMA WHERE t.TABLE_SCHEMA='dbo' AND t.TABLE_NAME='Products' AND t.CONSTRAINT_TYPE='PRIMARY KEY' ORDER BY k.ORDINAL_POSITION", connection);
        using (var reader = await keyCommand.ExecuteReaderAsync())
            while (await reader.ReadAsync()) Console.WriteLine($"PRIMARY KEY {reader.GetString(0)}");
        using var sampleCommand = new Microsoft.Data.SqlClient.SqlCommand("SELECT TOP (2) ProductID, ProductName FROM dbo.Products ORDER BY ProductID", connection);
        using (var reader = await sampleCommand.ExecuteReaderAsync())
            while (await reader.ReadAsync()) Console.WriteLine($"SQL SAMPLE {reader.GetInt32(0)} {reader.GetString(1)}");
        Console.WriteLine("Read-only same-process verification passed.");
    }
    catch (Exception failure)
    {
        var sanitized = failure.ToString();
        foreach (var token in secretTokens.OrderByDescending(value => value.Length)) sanitized = sanitized.Replace(token, "[REDACTED]", StringComparison.Ordinal);
        Console.WriteLine(sanitized);
        Environment.ExitCode = 1;
    }
    finally
    {
        await app.StopAsync();
        await app.DisposeAsync();
        Console.WriteLine("Host stopped and disposed.");
    }
    return;
}
app.Run();

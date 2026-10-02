using System.IO.Abstractions;
using Azure.DataApiBuilder.Auth;
using Azure.DataApiBuilder.Config;
using Azure.DataApiBuilder.Config.ObjectModel;
using Azure.DataApiBuilder.Core.AuthenticationHelpers;
using Azure.DataApiBuilder.Core.AuthenticationHelpers.UnauthenticatedAuthentication;
using Azure.DataApiBuilder.Core.Authorization;
using Azure.DataApiBuilder.Core.Configurations;
using Azure.DataApiBuilder.Core.Models;
using Azure.DataApiBuilder.Core.Resolvers;
using Azure.DataApiBuilder.Core.Resolvers.Factories;
using Azure.DataApiBuilder.Core.Services;
using Azure.DataApiBuilder.Core.Services.Cache;
using Azure.DataApiBuilder.Core.Services.MetadataProviders;
using Azure.DataApiBuilder.Core.Parsers;
using HotChocolate.AspNetCore;
using EmbeddedDab;
using Azure.DataApiBuilder.Service.Exceptions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Routing;
using Microsoft.Data.SqlClient;
using ZiggyCreatures.Caching.Fusion;

const string FixturePrefix = "dab_ticket9_";
string[] appArgs = Environment.GetCommandLineArgs().Skip(1).ToArray();
LoadNorthwindConnectionFromEnvFile();

if (appArgs.Length == 2 && appArgs[0] is "--prepare-fixture" or "--cleanup-fixture")
{
    await ManageFixtureDatabaseAsync(appArgs[0], appArgs[1]);
    return;
}

var builder = WebApplication.CreateBuilder(args.Where(argument => argument != "--initialize").ToArray());
builder.Logging.ClearProviders();
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
builder.Services.AddSingleton<GraphQLSchemaCreator>();
builder.Services.AddSingleton<IFusionCache>(_ => new FusionCache(new FusionCacheOptions()));
builder.Services.AddSingleton<DabCacheService>();
builder.Services.AddSingleton<RestService>();

builder.Services.AddGraphQLServer()
    .ModifyOptions(options => options.LazyInitialization = true)
    .AddHttpRequestInterceptor<HostRequestContextInterceptor>()
    .AddAuthorizationHandler<GraphQLAuthorizationHandler>()
    .ConfigureSchema((serviceProvider, schemaBuilder) =>
        serviceProvider.GetRootServiceProvider()
            .GetRequiredService<GraphQLSchemaCreator>()
            .InitializeSchemaAndResolvers(schemaBuilder));

var app = builder.Build();
app.Use(async (context, next) =>
{
    context.Response.Headers["X-Spike-Process-Id"] = Environment.ProcessId.ToString();
    await next(context);
});
app.UseAuthentication();
app.UseClientRoleHeaderAuthenticationMiddleware();
app.UseAuthorization();
app.UseClientRoleHeaderAuthorizationMiddleware();
app.MapGet("/host", () => new
{
    source = "application",
    processId = Environment.ProcessId,
    framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription
});

if (appArgs.Contains("--initialize"))
{
    var runtimeConfigProvider = app.Services.GetRequiredService<RuntimeConfigProvider>();
    _ = runtimeConfigProvider.GetConfig();
    var metadata = app.Services.GetRequiredService<IMetadataProviderFactory>();
    await metadata.InitializeAsync();
    var metadataFailures = metadata.GetAllMetadataExceptions();
    if (metadataFailures.Count > 0)
    {
        throw new AggregateException("DAB metadata initialization failed.", metadataFailures);
    }

    _ = app.Services.GetRequiredService<RestService>();
    _ = app.Services.GetRequiredService<GraphQLSchemaCreator>();
}

var loadedConfig = app.Services.GetRequiredService<RuntimeConfigProvider>().GetConfig();
if (loadedConfig.IsGraphQLEnabled)
{
    app.MapGraphQL(loadedConfig.GraphQLPath);
}

app.MapMethods("/{**dabRoute}", ["GET", "POST", "PUT", "PATCH", "DELETE"], async context =>
{
    var restService = context.RequestServices.GetRequiredService<RestService>();
    if (!restService.TryGetRestRouteFromConfig(out _))
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        return;
    }

    try
    {
        string route = string.Concat(context.Request.PathBase, context.Request.Path).TrimStart('/');
        string routeAfterPathBase = restService.GetRouteAfterPathBase(route);
        (string entityName, string primaryKeyRoute) = restService.GetEntityNameAndPrimaryKeyRouteFromRoute(routeAfterPathBase);
        EntityActionOperation operation = context.Request.Method.ToUpperInvariant() switch
        {
            "GET" => EntityActionOperation.Read,
            "POST" => EntityActionOperation.Insert,
            "PUT" => EntityActionOperation.Upsert,
            "PATCH" => EntityActionOperation.UpsertIncremental,
            "DELETE" => EntityActionOperation.Delete,
            _ => throw new InvalidOperationException("Unsupported HTTP method.")
        };

        IActionResult? result = await restService.ExecuteAsync(entityName, operation, primaryKeyRoute);
        if (result is null)
        {
            context.Response.StatusCode = StatusCodes.Status204NoContent;
            return;
        }

        await result.ExecuteResultAsync(new ActionContext(context, context.GetRouteData(), new ActionDescriptor()));
    }
    catch (DataApiBuilderException failure)
    {
        context.Response.StatusCode = (int)failure.StatusCode;
        await context.Response.WriteAsJsonAsync(new { error = "DAB request rejected." });
    }
    catch (Exception failure)
    {
        Console.WriteLine($"REST adapter failure: {failure.GetType().Name}");
        context.Response.StatusCode = StatusCodes.Status500InternalServerError;
        await context.Response.WriteAsJsonAsync(new { error = failure.GetType().Name });
    }
});

await app.RunAsync();

static void LoadNorthwindConnectionFromEnvFile()
{
    if (!string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("DAB_CONNECTION_STRING")))
    {
        return;
    }

    string? envFile = Environment.GetEnvironmentVariable("DAB_ENV_FILE");
    if (string.IsNullOrWhiteSpace(envFile))
    {
        throw new InvalidOperationException("Set DAB_CONNECTION_STRING or DAB_ENV_FILE.");
    }

    foreach (var entry in DotNetEnv.Env.Load(envFile))
    {
        try
        {
            var connection = new SqlConnectionStringBuilder(entry.Value);
            if (!string.Equals(connection.InitialCatalog, "northwind", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            string? fixtureDatabase = Environment.GetEnvironmentVariable("DAB_FIXTURE_DATABASE");
            if (!string.IsNullOrWhiteSpace(fixtureDatabase))
            {
                connection.InitialCatalog = fixtureDatabase;
            }

            Environment.SetEnvironmentVariable("DAB_CONNECTION_STRING", connection.ConnectionString);
            return;
        }
        catch (ArgumentException)
        {
            // The .env may hold unrelated key/value pairs.
        }
    }

    throw new InvalidOperationException("DAB_ENV_FILE has no SQL Server connection for the Northwind baseline.");
}

static async Task ManageFixtureDatabaseAsync(string operation, string databaseName)
{
    if (!databaseName.StartsWith(FixturePrefix, StringComparison.Ordinal)
        || databaseName.Length != FixturePrefix.Length + 12
        || databaseName[FixturePrefix.Length..].Any(character => !Uri.IsHexDigit(character)))
    {
        throw new ArgumentException("Fixture database name must use the generated dab_ticket9_<12 hex> form.");
    }

    var northwind = new SqlConnectionStringBuilder(Environment.GetEnvironmentVariable("DAB_CONNECTION_STRING"));
    northwind.InitialCatalog = "master";
    await using var connection = new SqlConnection(northwind.ConnectionString);
    await connection.OpenAsync();

    if (operation == "--prepare-fixture")
    {
        await using (var create = new SqlCommand($"CREATE DATABASE [{databaseName}]", connection))
        {
            await create.ExecuteNonQueryAsync();
        }

        try
        {
            northwind.InitialCatalog = databaseName;
            await using var fixture = new SqlConnection(northwind.ConnectionString);
            await fixture.OpenAsync();
            const string seed = """
                CREATE TABLE dbo.Widgets (id int IDENTITY(1,1) NOT NULL PRIMARY KEY, name nvarchar(80) NOT NULL, quantity int NOT NULL);
                CREATE TABLE dbo.RetiredWidgets (id int IDENTITY(1,1) NOT NULL PRIMARY KEY, name nvarchar(80) NOT NULL);
                CREATE TABLE dbo.Labels (id int IDENTITY(1,1) NOT NULL PRIMARY KEY, name nvarchar(80) NOT NULL);
                INSERT dbo.Widgets (name, quantity) VALUES (N'fixture-one', 3), (N'fixture-two', 7);
                INSERT dbo.RetiredWidgets (name) VALUES (N'removed-by-config');
                INSERT dbo.Labels (name) VALUES (N'added-by-config');
                """;
            await using var seedCommand = new SqlCommand(seed, fixture);
            await seedCommand.ExecuteNonQueryAsync();
        }
        catch
        {
            await using var removePartialFixture = new SqlCommand($"DROP DATABASE [{databaseName}]", connection);
            await removePartialFixture.ExecuteNonQueryAsync();
            throw;
        }

        Console.WriteLine($"Disposable fixture prepared: {databaseName}; 3 tables, seeded rows.");
        return;
    }

    await using (var drop = new SqlCommand($"ALTER DATABASE [{databaseName}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{databaseName}]", connection))
    {
        await drop.ExecuteNonQueryAsync();
    }

    Console.WriteLine($"Disposable fixture removed: {databaseName}.");
}

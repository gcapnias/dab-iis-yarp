using System.Reflection;
using Azure.DataApiBuilder.Core.Services;
using Azure.DataApiBuilder.Core.Configurations;
using Azure.DataApiBuilder.Config;
if (args.FirstOrDefault() == "--metadata") { MetadataInventory.Run(args.Skip(1)); return; }
var core = typeof(RestService).Assembly;
if (args.FirstOrDefault() == "--all")
{
    foreach (var assembly in new[] { core, typeof(RuntimeConfigLoader).Assembly })
        foreach (var type in assembly.GetExportedTypes()) Console.WriteLine(type.FullName);
    return;
}
var names = new[] {
 "Azure.DataApiBuilder.Core.Resolvers.CosmosClientProvider", "Azure.DataApiBuilder.Core.Models.GQLFilterParser", "Azure.DataApiBuilder.Core.Services.Cache.DabCacheService", "Azure.DataApiBuilder.Core.Authorization.RestAuthorizationHandler",
 "Azure.DataApiBuilder.Core.Resolvers.Factories.QueryManagerFactory", "Azure.DataApiBuilder.Core.Authorization.AuthorizationResolver", "Azure.DataApiBuilder.Core.Configurations.RuntimeConfigValidator", "Azure.DataApiBuilder.Core.Services.RestService", "Azure.DataApiBuilder.Core.Services.RequestValidator",
 "Azure.DataApiBuilder.Core.Resolvers.Factories.QueryEngineFactory", "Azure.DataApiBuilder.Core.Resolvers.Factories.MutationEngineFactory",
 "Azure.DataApiBuilder.Core.Services.MetadataProviders.MetadataProviderFactory", "Azure.DataApiBuilder.Core.Configurations.RuntimeConfigProvider"
};
var types = names.Select(n => core.GetType(n)).Concat(new[] { typeof(FileSystemRuntimeConfigLoader) });
foreach (var type in types)
{
    if (type is null) { Console.WriteLine("MISSING requested type"); continue; }
    Console.WriteLine($"TYPE {type.FullName}");
    foreach (var constructor in type.GetConstructors()) Console.WriteLine($"  CTOR {constructor}");
    if (type == typeof(RestService) || type == typeof(RuntimeConfigProvider) || type == typeof(FileSystemRuntimeConfigLoader))
        foreach (var method in type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly)) Console.WriteLine($"  METHOD {method}");
}

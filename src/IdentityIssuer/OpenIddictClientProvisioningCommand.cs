using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using OpenIddict.Abstractions;
using static OpenIddict.Abstractions.OpenIddictConstants;

namespace IdentityIssuer;

public static class OpenIddictClientProvisioningCommand
{
    private const string ProvisioningFlag = "--provision-oidc-client";

    public static bool IsRequested(IEnumerable<string> args) =>
        args.Contains(ProvisioningFlag, StringComparer.OrdinalIgnoreCase);

    public static async Task RunAsync(string[] args)
    {
        var hostArgs = args.Where(argument => !string.Equals(argument, ProvisioningFlag, StringComparison.OrdinalIgnoreCase)).ToArray();
        var builder = WebApplication.CreateBuilder(hostArgs);
        var connectionString = builder.Configuration.GetConnectionString("IssuerIdentity")
            ?? throw new InvalidOperationException("ConnectionStrings:IssuerIdentity is required.");
        var clientId = builder.Configuration["Oidc:ClientId"]
            ?? throw new InvalidOperationException("Oidc:ClientId is required.");
        var redirectUri = builder.Configuration["Oidc:RedirectUri"]
            ?? throw new InvalidOperationException("Oidc:RedirectUri is required.");
        if (!Uri.TryCreate(redirectUri, UriKind.Absolute, out var redirect) || redirect.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("Oidc:RedirectUri must be an absolute HTTPS URL.");

        builder.Services.AddIssuerIdentityDatabase(connectionString);
        builder.Services.AddOpenIddict().AddCore(options => options.UseEntityFrameworkCore().UseDbContext<ApplicationDbContext>());
        await using var serviceProvider = builder.Services.BuildServiceProvider();
        await using var scope = serviceProvider.CreateAsyncScope();
        var manager = scope.ServiceProvider.GetRequiredService<IOpenIddictApplicationManager>();
        await EnsureClientAsync(manager, clientId, redirect);

        Console.WriteLine("OIDC client registration is ready.");
    }

    public static async Task EnsureClientAsync(IOpenIddictApplicationManager manager, string clientId, Uri redirect)
    {
        var existing = await manager.FindByClientIdAsync(clientId);
        if (existing is not null)
        {
            var redirects = await manager.GetRedirectUrisAsync(existing);
            var permissions = await manager.GetPermissionsAsync(existing);
            var requirements = await manager.GetRequirementsAsync(existing);
            var expectedPermissions = GetPermissions();
            var valid = await manager.GetApplicationTypeAsync(existing) == ApplicationTypes.Native &&
                await manager.GetClientTypeAsync(existing) == ClientTypes.Public &&
                redirects.SequenceEqual([redirect.AbsoluteUri], StringComparer.Ordinal) &&
                expectedPermissions.SetEquals(permissions) &&
                requirements.Contains(Requirements.Features.ProofKeyForCodeExchange, StringComparer.Ordinal);
            if (!valid)
                throw new InvalidOperationException("The existing OIDC client does not match the configured public PKCE client contract.");
            return;
        }

        var descriptor = new OpenIddictApplicationDescriptor
        {
            ApplicationType = ApplicationTypes.Native,
            ClientId = clientId,
            ClientType = ClientTypes.Public,
            ConsentType = ConsentTypes.Implicit,
            DisplayName = "Local issuer test client",
            RedirectUris = { redirect },
            Requirements = { Requirements.Features.ProofKeyForCodeExchange }
        };
        foreach (var permission in GetPermissions())
            descriptor.Permissions.Add(permission);
        await manager.CreateAsync(descriptor);
    }

    private static HashSet<string> GetPermissions() =>
    [
        Permissions.Endpoints.Authorization,
        Permissions.Endpoints.Token,
        Permissions.GrantTypes.AuthorizationCode,
        Permissions.GrantTypes.RefreshToken,
        Permissions.ResponseTypes.Code,
        Permissions.Prefixes.Scope + Scopes.OpenId,
        Permissions.Prefixes.Scope + Scopes.Profile,
        Permissions.Prefixes.Scope + Scopes.Roles,
        Permissions.Prefixes.Scope + Scopes.OfflineAccess
    ];
}

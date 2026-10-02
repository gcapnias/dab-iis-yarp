using System.Security.Cryptography;
using System.Security.Claims;

using IdentityIssuer;

using Microsoft.AspNetCore;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Server.IISIntegration;
using Microsoft.IdentityModel.Tokens;
using OpenIddict.Abstractions;
using OpenIddict.Server;
using OpenIddict.Server.AspNetCore;
using static OpenIddict.Abstractions.OpenIddictConstants;

if (IdentityProvisioningCommand.IsRequested(args))
{
    await IdentityProvisioningCommand.RunAsync(args);
    return;
}
if (OpenIddictClientProvisioningCommand.IsRequested(args))
{
    await OpenIddictClientProvisioningCommand.RunAsync(args);
    return;
}

var builder = WebApplication.CreateBuilder(args);
var issuer = builder.Configuration["Issuer:Url"] ?? throw new InvalidOperationException("Issuer:Url is required.");
var audience = builder.Configuration["Issuer:Audience"] ?? throw new InvalidOperationException("Issuer:Audience is required.");
var keyId = builder.Configuration["Issuer:KeyId"] ?? throw new InvalidOperationException("Issuer:KeyId is required.");
var keyPath = builder.Configuration["Issuer:SigningKeyPath"] ?? throw new InvalidOperationException("Issuer:SigningKeyPath is required.");
var encryptionKeyPath = builder.Configuration["Issuer:EncryptionKeyPath"] ?? throw new InvalidOperationException("Issuer:EncryptionKeyPath is required.");
var connectionString = builder.Configuration.GetConnectionString("IssuerIdentity") ?? throw new InvalidOperationException("ConnectionStrings:IssuerIdentity is required.");
var lifetimeMinutes = builder.Configuration.GetValue("Issuer:LifetimeMinutes", 10);
var refreshLifetimeDays = builder.Configuration.GetValue("Issuer:RefreshLifetimeDays", 7);
var cookieName = builder.Configuration["Issuer:CookieName"] ?? "dab_access_token";
var refreshCookieName = builder.Configuration["Issuer:RefreshCookieName"] ?? "issuer_refresh_token";
var cookieDomain = builder.Configuration["Issuer:CookieDomain"];
var authenticationMode = builder.Configuration["WindowsAuthentication:Mode"] ?? "Negotiate";
var oidcClientId = builder.Configuration["Oidc:ClientId"] ?? throw new InvalidOperationException("Oidc:ClientId is required.");
var oidcRedirectUri = builder.Configuration["Oidc:RedirectUri"] ?? throw new InvalidOperationException("Oidc:RedirectUri is required.");

using var signingRsa = RSA.Create();
signingRsa.ImportFromPem(File.ReadAllText(Path.GetFullPath(keyPath, builder.Environment.ContentRootPath)));
using var encryptionRsa = RSA.Create();
encryptionRsa.ImportFromPem(File.ReadAllText(Path.GetFullPath(encryptionKeyPath, builder.Environment.ContentRootPath)));
if (signingRsa.KeySize < 2048 || encryptionRsa.KeySize < 2048)
{
    throw new InvalidOperationException("Issuer RSA keys must be at least 2048 bits.");
}
var signingSecurityKey = new RsaSecurityKey(signingRsa.ExportParameters(includePrivateParameters: true)) { KeyId = keyId };
var encryptionSecurityKey = new RsaSecurityKey(encryptionRsa.ExportParameters(includePrivateParameters: true)) { KeyId = $"{keyId}-encryption" };
var previousSigningKeys = builder.Configuration.GetSection("Issuer:PreviousSigningKeys")
    .Get<PreviousSigningKeyOptions[]>() ?? [];
var previousSecurityKeys = new List<RsaSecurityKey>(previousSigningKeys.Length);
foreach (var previousKey in previousSigningKeys)
{
    if (string.IsNullOrWhiteSpace(previousKey.KeyId) || string.IsNullOrWhiteSpace(previousKey.PrivateKeyPath) ||
        string.Equals(previousKey.KeyId, keyId, StringComparison.Ordinal) ||
        previousSecurityKeys.Any(key => string.Equals(key.KeyId, previousKey.KeyId, StringComparison.Ordinal)))
    {
        throw new InvalidOperationException("Issuer:PreviousSigningKeys requires unique, non-empty KeyId and PrivateKeyPath values distinct from the active key.");
    }

    using var previousRsa = RSA.Create();
    previousRsa.ImportFromPem(File.ReadAllText(Path.GetFullPath(previousKey.PrivateKeyPath, builder.Environment.ContentRootPath)));
    if (previousRsa.KeySize < 2048)
    {
        throw new InvalidOperationException($"The previous verification key '{previousKey.KeyId}' must be at least 2048 bits.");
    }
    previousSecurityKeys.Add(new RsaSecurityKey(previousRsa.ExportParameters(includePrivateParameters: true)) { KeyId = previousKey.KeyId });
}

if (string.IsNullOrWhiteSpace(audience) || string.IsNullOrWhiteSpace(keyId))
{
    throw new InvalidOperationException("Issuer:Audience and Issuer:KeyId must be non-empty.");
}

if (!Uri.TryCreate(issuer, UriKind.Absolute, out var issuerUri) ||
    !string.IsNullOrEmpty(issuerUri.Query) || !string.IsNullOrEmpty(issuerUri.Fragment) ||
    (issuerUri.Scheme != Uri.UriSchemeHttps && !(builder.Environment.IsDevelopment() && issuerUri.IsLoopback)))
{
    throw new InvalidOperationException("Issuer:Url must be an HTTPS issuer URL (localhost HTTP is allowed only in Development).");
}
issuer = issuerUri.AbsoluteUri;

if (lifetimeMinutes is < 1 or > 60)
{
    throw new InvalidOperationException("Issuer:LifetimeMinutes must be between 1 and 60.");
}

if (refreshLifetimeDays is < 1 or > 30)
{
    throw new InvalidOperationException("Issuer:RefreshLifetimeDays must be between 1 and 30.");
}

builder.Services.AddSingleton<RSA>(signingRsa);
var issuerSettings = new IssuerSettings(issuer, audience, keyId, TimeSpan.FromMinutes(lifetimeMinutes), cookieName, cookieDomain);
builder.Services.AddSingleton(issuerSettings);
builder.Services.AddSingleton(_ => new JwtIssuer(signingRsa, issuerSettings, previousSecurityKeys));
builder.Services.AddIssuerIdentityDatabase(connectionString);
builder.Services.AddIssuerIdentityStores();
builder.Services.AddScoped<IIdentityDirectory, AspNetIdentityDirectory>();
builder.Services.AddScoped<IdentityProfileResolver>();
builder.Services.AddScoped<IdentityProvisioner>();
builder.Services.AddScoped<OidcRefreshFamilyRevoker>();
builder.Services.AddScoped(_ => new RefreshTokenService(
    _.GetRequiredService<ApplicationDbContext>(), TimeSpan.FromDays(refreshLifetimeDays)));
builder.Services.AddHostedService<RefreshTokenCleanupService>();
builder.Services.AddOpenIddict()
    .AddCore(options => options.UseEntityFrameworkCore().UseDbContext<ApplicationDbContext>())
    .AddServer(options =>
    {
        var endpointPrefix = issuerUri.AbsolutePath.Trim('/');
        var endpointRoot = string.IsNullOrEmpty(endpointPrefix) ? string.Empty : endpointPrefix + "/";
        options.SetIssuer(issuerUri)
            .SetAuthorizationEndpointUris(endpointRoot + "connect/authorize")
            .SetTokenEndpointUris(endpointRoot + "connect/token")
            .AllowAuthorizationCodeFlow()
            .AllowRefreshTokenFlow()
            .RequireProofKeyForCodeExchange()
            .RegisterScopes(Scopes.Profile, Scopes.Roles, Scopes.OfflineAccess)
            .RegisterClaims(Claims.Role, "profile_id", "ClearanceLevel")
            .SetAccessTokenLifetime(TimeSpan.FromMinutes(lifetimeMinutes))
            .SetRefreshTokenLifetime(TimeSpan.FromDays(refreshLifetimeDays))
            .SetRefreshTokenReuseLeeway(TimeSpan.Zero)
            .UseReferenceRefreshTokens()
            .AddSigningKey(signingSecurityKey)
            .AddSigningKeys(previousSecurityKeys)
            .AddEncryptionKey(encryptionSecurityKey)
            .DisableAccessTokenEncryption();

        options.AddEventHandler<OpenIddictServerEvents.ProcessAuthenticationContext>(handler => handler
            .UseScopedHandler<ValidateOidcRefreshAccountState>()
            .SetOrder(int.MaxValue)
            .Build());
        options.AddEventHandler<OpenIddictServerEvents.ValidateTokenContext>(handler => handler
            .UseScopedHandler<DetectOidcRefreshReplay>()
            .SetOrder(OpenIddictServerHandlers.Protection.ValidateTokenEntry.Descriptor.Order - 1)
            .Build());
        options.UseAspNetCore().EnableAuthorizationEndpointPassthrough();
    });
builder.Services.AddAntiforgery(options =>
{
    options.HeaderName = "X-CSRF-TOKEN";
    options.Cookie.Name = "issuer_csrf";
    options.Cookie.HttpOnly = true;
    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    options.Cookie.SameSite = SameSiteMode.Strict;
});

if (string.Equals(authenticationMode, "IIS", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddAuthentication(IISDefaults.AuthenticationScheme);
}
else if (string.Equals(authenticationMode, "Negotiate", StringComparison.OrdinalIgnoreCase))
{
    builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme).AddNegotiate();
}
else
{
    throw new InvalidOperationException("WindowsAuthentication:Mode must be IIS or Negotiate.");
}

builder.Services.AddAuthorization(options =>
{
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});
var app = builder.Build();
app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();

var issuerPath = issuerUri.AbsolutePath.TrimEnd('/');
var authorizePath = $"{issuerPath}/connect/authorize";

if (app.Environment.IsDevelopment())
{
    app.MapGet($"{issuerPath}/diagnostics/windows-auth", (HttpContext context) =>
        Results.Json(AuthenticatedWindowsIdentity.Describe(context.User))).RequireAuthorization();
}

app.MapGet(authorizePath, async (HttpContext context, IdentityProfileResolver profiles) =>
{
    var request = context.GetOpenIddictServerRequest() ??
        throw new InvalidOperationException("The OpenID Connect authorization request could not be read.");

    var windowsAuthentication = await context.AuthenticateAsync();
    if (!windowsAuthentication.Succeeded || windowsAuthentication.Principal is null)
    {
        var query = context.Request.Query.ToArray().SelectMany(pair => pair.Value.Select(value => new KeyValuePair<string, string?>(pair.Key, value)));
        return Results.Challenge(
            new AuthenticationProperties { RedirectUri = context.Request.PathBase + context.Request.Path + QueryString.Create(query) },
            [authenticationMode == "IIS" ? IISDefaults.AuthenticationScheme : NegotiateDefaults.AuthenticationScheme]);
    }

    var lookup = await profiles.ResolveAsync(windowsAuthentication.Principal, context.RequestAborted);
    if (!lookup.Succeeded)
    {
        return Results.Forbid(
            new AuthenticationProperties(new Dictionary<string, string?>
            {
                [OpenIddictServerAspNetCoreConstants.Properties.Error] = Errors.AccessDenied,
                [OpenIddictServerAspNetCoreConstants.Properties.ErrorDescription] = "The authenticated Windows account is not enabled and provisioned for this issuer."
            }),
            [OpenIddictServerAspNetCoreDefaults.AuthenticationScheme]);
    }

    var profile = lookup.Profile!;
    var identity = new ClaimsIdentity(TokenValidationParameters.DefaultAuthenticationType, Claims.Name, Claims.Role);
    identity.SetScopes(request.GetScopes());
    OidcProfileClaims.Replace(identity, profile);
    identity.SetResources(audience);

    return Results.SignIn(new ClaimsPrincipal(identity), authenticationScheme: OpenIddictServerAspNetCoreDefaults.AuthenticationScheme);
}).AllowAnonymous();

app.MapGet($"{issuerPath}/csrf", (HttpContext context, IAntiforgery antiforgery) =>
{
    var tokens = antiforgery.GetAndStoreTokens(context);
    return Results.Json(new { requestToken = tokens.RequestToken });
}).RequireAuthorization();

app.MapPost($"{issuerPath}/session", async (HttpContext context, IAntiforgery antiforgery, IdentityProfileResolver profiles, JwtIssuer tokens, IssuerSettings settings) =>
{
    if (!await ValidateAntiforgeryAsync(context, antiforgery))
        return Results.BadRequest();

    var lookup = await profiles.ResolveAsync(context.User, context.RequestAborted);

    if (!lookup.Succeeded)
    {
        return Results.Forbid();
    }

    var issuedAt = DateTimeOffset.UtcNow;
    var jwt = tokens.CreateToken(lookup.Profile!, issuedAt);
    var refreshToken = await context.RequestServices.GetRequiredService<RefreshTokenService>()
        .CreateAsync(lookup.Profile!, issuedAt, context.RequestAborted);
    IssuerSessionCookies.Write(
        context.Response,
        settings,
        refreshCookieName,
        issuerPath,
        jwt,
        refreshToken,
        issuedAt,
        TimeSpan.FromDays(refreshLifetimeDays));
    return Results.NoContent();
}).RequireAuthorization();

app.MapPost($"{issuerPath}/session/refresh", async (HttpContext context, IAntiforgery antiforgery, IdentityProfileResolver profiles, JwtIssuer tokens, IssuerSettings settings) =>
{
    if (!await ValidateAntiforgeryAsync(context, antiforgery))
        return Results.BadRequest();

    if (!context.Request.Cookies.TryGetValue(refreshCookieName, out var presentedToken))
        return Results.Unauthorized();

    var lookup = await profiles.ResolveAsync(context.User, context.RequestAborted);
    if (!lookup.Succeeded)
        return Results.Forbid();

    var now = DateTimeOffset.UtcNow;
    var service = context.RequestServices.GetRequiredService<RefreshTokenService>();
    var rotation = await service.RotateAsync(presentedToken, lookup.Profile!, now, context.RequestAborted);
    if (rotation.Status != RefreshTokenRotationStatus.Rotated)
    {
        IssuerSessionCookies.ExpireRefresh(context.Response, settings, refreshCookieName, issuerPath);
        return Results.Unauthorized();
    }

    IssuerSessionCookies.Write(
        context.Response,
        settings,
        refreshCookieName,
        issuerPath,
        tokens.CreateToken(lookup.Profile!, now),
        rotation.ReplacementToken!,
        now,
        TimeSpan.FromDays(refreshLifetimeDays));
    return Results.NoContent();
}).RequireAuthorization();

app.MapPost($"{issuerPath}/session/logout", async (HttpContext context, IAntiforgery antiforgery, IssuerSettings settings) =>
{
    if (!await ValidateAntiforgeryAsync(context, antiforgery))
        return Results.BadRequest();

    if (context.Request.Cookies.TryGetValue(refreshCookieName, out var refreshToken))
        await context.RequestServices.GetRequiredService<RefreshTokenService>().RevokeAsync(refreshToken, DateTimeOffset.UtcNow, context.RequestAborted);
    IssuerSessionCookies.ExpireAll(context.Response, settings, refreshCookieName, issuerPath);
    return Results.NoContent();
}).RequireAuthorization();

app.Run();

static async Task<bool> ValidateAntiforgeryAsync(HttpContext context, IAntiforgery antiforgery)
{
    try
    {
        await antiforgery.ValidateRequestAsync(context);
        return true;
    }
    catch (AntiforgeryValidationException)
    {
        return false;
    }
}

public partial class Program;

using System.Security.Cryptography;

using IdentityIssuer;

using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication.Negotiate;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Server.IISIntegration;

if (IdentityProvisioningCommand.IsRequested(args))
{
    await IdentityProvisioningCommand.RunAsync(args);
    return;
}

var builder = WebApplication.CreateBuilder(args);
var issuer = builder.Configuration["Issuer:Url"] ?? throw new InvalidOperationException("Issuer:Url is required.");
var audience = builder.Configuration["Issuer:Audience"] ?? throw new InvalidOperationException("Issuer:Audience is required.");
var keyId = builder.Configuration["Issuer:KeyId"] ?? throw new InvalidOperationException("Issuer:KeyId is required.");
var keyPath = builder.Configuration["Issuer:SigningKeyPath"] ?? throw new InvalidOperationException("Issuer:SigningKeyPath is required.");
var connectionString = builder.Configuration.GetConnectionString("IssuerIdentity") ?? throw new InvalidOperationException("ConnectionStrings:IssuerIdentity is required.");
var lifetimeMinutes = builder.Configuration.GetValue("Issuer:LifetimeMinutes", 10);
var cookieName = builder.Configuration["Issuer:CookieName"] ?? "dab_access_token";
var cookieDomain = builder.Configuration["Issuer:CookieDomain"];
var authenticationMode = builder.Configuration["WindowsAuthentication:Mode"] ?? "Negotiate";

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

if (lifetimeMinutes is < 1 or > 60)
{
    throw new InvalidOperationException("Issuer:LifetimeMinutes must be between 1 and 60.");
}

builder.Services.AddSingleton<RSA>(_ =>
{
    var key = RSA.Create();
    key.ImportFromPem(File.ReadAllText(keyPath));
    if (key.KeySize < 2048)
    {
        key.Dispose();
        throw new InvalidOperationException("The RSA signing key must be at least 2048 bits.");
    }
    return key;
});
builder.Services.AddSingleton(new IssuerSettings(issuer, audience, keyId, TimeSpan.FromMinutes(lifetimeMinutes), cookieName, cookieDomain));
builder.Services.AddSingleton<JwtIssuer>();
builder.Services.AddIssuerIdentityDatabase(connectionString);
builder.Services.AddIssuerIdentityStores();
builder.Services.AddScoped<IIdentityDirectory, AspNetIdentityDirectory>();
builder.Services.AddScoped<IdentityProfileResolver>();
builder.Services.AddScoped<IdentityProvisioner>();
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
var discoveryPath = $"{issuerPath}/.well-known/openid-configuration";
var jwksPath = $"{issuerPath}/.well-known/jwks.json";

app.MapGet(discoveryPath, (IssuerSettings settings) => Results.Json(new
{
    issuer = settings.Issuer,
    jwks_uri = $"{settings.Issuer.TrimEnd('/')}/.well-known/jwks.json",
})).AllowAnonymous();

app.MapGet(jwksPath, (JwtIssuer tokens) => Results.Json(tokens.CreatePublicKeySet())).AllowAnonymous();

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
    var expires = issuedAt.Add(settings.Lifetime);
    var jwt = tokens.CreateToken(lookup.Profile!, issuedAt);
    context.Response.Cookies.Append(settings.CookieName, jwt, new CookieOptions
    {
        HttpOnly = true,
        Secure = true,
        SameSite = SameSiteMode.Lax,
        IsEssential = true,
        Expires = expires,
        Path = "/",
        Domain = settings.CookieDomain
    });
    return Results.NoContent();
}).RequireAuthorization();

app.MapPost($"{issuerPath}/session/logout", async (HttpContext context, IAntiforgery antiforgery, IssuerSettings settings) =>
{
    if (!await ValidateAntiforgeryAsync(context, antiforgery))
        return Results.BadRequest();

    context.Response.Cookies.Delete(settings.CookieName, new CookieOptions { Secure = true, HttpOnly = true, SameSite = SameSiteMode.Lax, Path = "/", Domain = settings.CookieDomain });
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
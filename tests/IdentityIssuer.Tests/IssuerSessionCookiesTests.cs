using IdentityIssuer;
using Microsoft.AspNetCore.Http;

namespace IdentityIssuer.Tests;

public sealed class IssuerSessionCookiesTests
{
    [Fact]
    public void Writes_secure_host_only_cookies_with_distinct_paths_and_same_site_modes()
    {
        var context = new DefaultHttpContext();
        var settings = new IssuerSettings("https://issuer.example.test", "dab-api", "key-1", TimeSpan.FromMinutes(10), "dab_access_token", null);

        IssuerSessionCookies.Write(
            context.Response,
            settings,
            "issuer_refresh_token",
            "/issuer",
            "test-access-token",
            "test-refresh-token",
            DateTimeOffset.UtcNow,
            TimeSpan.FromDays(7));

        var cookies = context.Response.Headers.SetCookie.ToArray();
        var access = Assert.Single(cookies, cookie => cookie is not null && cookie.StartsWith("dab_access_token=", StringComparison.Ordinal)) ?? throw new InvalidOperationException();
        var refresh = Assert.Single(cookies, cookie => cookie is not null && cookie.StartsWith("issuer_refresh_token=", StringComparison.Ordinal)) ?? throw new InvalidOperationException();
        Assert.Contains("httponly", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=lax", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("path=/;", access, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("domain=", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("httponly", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=strict", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("path=/issuer", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("domain=", refresh, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Expiration_uses_the_same_host_domain_paths_and_cookie_security_attributes()
    {
        var context = new DefaultHttpContext();
        var settings = new IssuerSettings("https://issuer.example.test", "dab-api", "key-1", TimeSpan.FromMinutes(10), "dab_access_token", ".example.test");

        IssuerSessionCookies.ExpireAll(context.Response, settings, "issuer_refresh_token", "/issuer");

        var cookies = context.Response.Headers.SetCookie.ToArray();
        var access = Assert.Single(cookies, cookie => cookie is not null && cookie.StartsWith("dab_access_token=", StringComparison.Ordinal)) ?? throw new InvalidOperationException();
        var refresh = Assert.Single(cookies, cookie => cookie is not null && cookie.StartsWith("issuer_refresh_token=", StringComparison.Ordinal)) ?? throw new InvalidOperationException();
        Assert.Contains("domain=.example.test", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("domain=.example.test", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("path=/;", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("path=/issuer", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=lax", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=strict", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("httponly", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("httponly", refresh, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("expires=Thu, 01 Jan 1970", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("expires=Thu, 01 Jan 1970", refresh, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Root_issuer_uses_stable_root_path_for_refresh_cookie_issue_and_expiration()
    {
        var context = new DefaultHttpContext();
        var settings = new IssuerSettings("https://issuer.example.test", "dab-api", "key-1", TimeSpan.FromMinutes(10), "dab_access_token", null);

        IssuerSessionCookies.Write(context.Response, settings, "issuer_refresh_token", "", "access", "refresh", DateTimeOffset.UtcNow, TimeSpan.FromDays(7));
        var refreshCookie = Assert.Single(context.Response.Headers.SetCookie, cookie => cookie is not null && cookie.StartsWith("issuer_refresh_token=", StringComparison.Ordinal)) ?? throw new InvalidOperationException();
        Assert.Contains("path=/;", refreshCookie, StringComparison.OrdinalIgnoreCase);

        context.Response.Headers.Clear();
        IssuerSessionCookies.ExpireRefresh(context.Response, settings, "issuer_refresh_token", "");
        var expiredCookie = Assert.Single(context.Response.Headers.SetCookie, cookie => cookie is not null && cookie.StartsWith("issuer_refresh_token=", StringComparison.Ordinal)) ?? throw new InvalidOperationException();
        Assert.Contains("path=/;", expiredCookie, StringComparison.OrdinalIgnoreCase);
    }
}

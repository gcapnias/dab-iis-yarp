extern alias IssuerProject;

using IdentityIssuer = IssuerProject::IdentityIssuer;
using Microsoft.AspNetCore.Http;

namespace EmbeddedDab.Tests;

public sealed class CookieBearerBridgeTests
{
    [Fact]
    public void IssuerAccessCookieContractIsHostScopedSecureAndExpiresWithItsJwt()
    {
        var context = new DefaultHttpContext();
        context.Request.Scheme = "https";
        var now = DateTimeOffset.Parse("2026-10-03T12:00:00Z");
        var settings = new IdentityIssuer.IssuerSettings("https://issuer.test/identity", "api://dab", "key-1", TimeSpan.FromMinutes(10), "dab_access_token", null);

        IdentityIssuer.IssuerSessionCookies.Write(context.Response, settings, "issuer_refresh_token", "/identity", "synthetic.jwt.value", "synthetic.refresh.value", now, TimeSpan.FromDays(7));

        var access = context.Response.Headers.SetCookie.Single(value => value!.StartsWith("dab_access_token=", StringComparison.Ordinal))!;
        Assert.Contains("path=/", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("secure", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("httponly", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("samesite=lax", access, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("expires=Sat, 03 Oct 2026 12:10:00 GMT", access, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("domain=", access, StringComparison.OrdinalIgnoreCase);

        IdentityIssuer.IssuerSessionCookies.ExpireAll(context.Response, settings, "issuer_refresh_token", "/identity");
        Assert.Contains(context.Response.Headers.SetCookie, value => value!.StartsWith("dab_access_token=", StringComparison.Ordinal) && value.Contains("expires=Thu, 01 Jan 1970", StringComparison.OrdinalIgnoreCase));
    }
}

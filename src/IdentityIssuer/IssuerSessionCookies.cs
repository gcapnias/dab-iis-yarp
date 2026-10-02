using Microsoft.AspNetCore.Http;

namespace IdentityIssuer;

public static class IssuerSessionCookies
{
    public static void Write(
        HttpResponse response,
        IssuerSettings settings,
        string refreshCookieName,
        string issuerPath,
        string accessToken,
        string refreshToken,
        DateTimeOffset now,
        TimeSpan refreshLifetime)
    {
        response.Cookies.Append(settings.CookieName, accessToken, new CookieOptions
        {
            HttpOnly = true,
            Secure = true,
            SameSite = SameSiteMode.Lax,
            IsEssential = true,
            Expires = now.Add(settings.Lifetime),
            Path = "/",
            Domain = settings.CookieDomain
        });
        response.Cookies.Append(refreshCookieName, refreshToken, new CookieOptions
        {
            HttpOnly = true,
            Secure = true,
            SameSite = SameSiteMode.Strict,
            IsEssential = true,
            Expires = now.Add(refreshLifetime),
            Path = RefreshPath(issuerPath),
            Domain = settings.CookieDomain
        });
    }

    public static void ExpireAccess(HttpResponse response, IssuerSettings settings) =>
        response.Cookies.Delete(settings.CookieName, AccessOptions(settings));

    public static void ExpireRefresh(HttpResponse response, IssuerSettings settings, string refreshCookieName, string issuerPath) =>
        response.Cookies.Delete(refreshCookieName, RefreshOptions(settings, issuerPath));

    public static void ExpireAll(HttpResponse response, IssuerSettings settings, string refreshCookieName, string issuerPath)
    {
        ExpireAccess(response, settings);
        ExpireRefresh(response, settings, refreshCookieName, issuerPath);
    }

    private static CookieOptions AccessOptions(IssuerSettings settings) => new()
    {
        HttpOnly = true,
        Secure = true,
        SameSite = SameSiteMode.Lax,
        Path = "/",
        Domain = settings.CookieDomain
    };

    private static CookieOptions RefreshOptions(IssuerSettings settings, string issuerPath) => new()
    {
        HttpOnly = true,
        Secure = true,
        SameSite = SameSiteMode.Strict,
        Path = RefreshPath(issuerPath),
        Domain = settings.CookieDomain
    };

    private static string RefreshPath(string issuerPath) => string.IsNullOrEmpty(issuerPath) ? "/" : issuerPath;
}

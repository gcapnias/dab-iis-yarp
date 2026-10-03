namespace EmbeddedDab;

/// <summary>
/// Adapts the issuer's same-origin, host-only access cookie to DAB's bearer-token contract.
/// </summary>
public sealed class IssuerCookieBearerBridgeMiddleware(RequestDelegate next)
{
    public const string AccessCookieName = "dab_access_token";
    public const string CookieCredentialItem = "EmbeddedDab.IssuerCookieCredential";

    public async Task InvokeAsync(HttpContext context)
    {
        if (!context.Request.Headers.ContainsKey("Authorization")
            && context.Request.Cookies.TryGetValue(AccessCookieName, out string? token)
            && !string.IsNullOrWhiteSpace(token))
        {
            context.Request.Headers.Authorization = $"Bearer {token}";
            context.Items[CookieCredentialItem] = true;
        }

        await next(context);
    }
}

/// <summary>
/// Checks cookie mutations after DAB's authentication middleware has populated the caller.
/// </summary>
public sealed class IssuerCookieAntiforgeryMiddleware(RequestDelegate next, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery)
{
    public async Task InvokeAsync(HttpContext context)
    {
        if (context.Items.ContainsKey(IssuerCookieBearerBridgeMiddleware.CookieCredentialItem)
            && IsUnsafeMethod(context.Request.Method))
        {
            if (!HasSameOrigin(context.Request))
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }

            try
            {
                await antiforgery.ValidateRequestAsync(context);
            }
            catch (Microsoft.AspNetCore.Antiforgery.AntiforgeryValidationException)
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }
        }

        await next(context);
    }

    private static bool IsUnsafeMethod(string method) =>
        !HttpMethods.IsGet(method)
        && !HttpMethods.IsHead(method)
        && !HttpMethods.IsOptions(method)
        && !HttpMethods.IsTrace(method);

    private static bool HasSameOrigin(HttpRequest request)
    {
        if (!Uri.TryCreate(request.Headers["Origin"].ToString(), UriKind.Absolute, out Uri? origin)
            || !string.IsNullOrEmpty(origin.UserInfo)
            || origin.AbsolutePath != "/"
            || !string.IsNullOrEmpty(origin.Query)
            || !string.IsNullOrEmpty(origin.Fragment))
        {
            return false;
        }

        return string.Equals(origin.Scheme, request.Scheme, StringComparison.OrdinalIgnoreCase)
            && string.Equals(origin.Host, request.Host.Host, StringComparison.OrdinalIgnoreCase)
            && origin.Port == (request.Host.Port ?? (string.Equals(request.Scheme, "https", StringComparison.OrdinalIgnoreCase) ? 443 : 80));
    }
}

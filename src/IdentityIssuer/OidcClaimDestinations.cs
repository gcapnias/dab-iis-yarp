using System.Security.Claims;
using OpenIddict.Abstractions;
using static OpenIddict.Abstractions.OpenIddictConstants;

namespace IdentityIssuer;

public static class OidcClaimDestinations
{
    private const string ProfileId = "profile_id";
    public const string ClearanceLevel = "ClearanceLevel";

    public static IEnumerable<string> For(Claim claim)
    {
        if (claim.Type == Claims.Subject)
            return [Destinations.AccessToken, Destinations.IdentityToken];

        if (claim.Type is Claims.Name or ProfileId or ClearanceLevel)
            return claim.Subject?.GetScopes().Contains(Scopes.Profile) == true
                ? [Destinations.AccessToken, Destinations.IdentityToken]
                : [];

        if (claim.Type == Claims.Role)
            return claim.Subject?.GetScopes().Contains(Scopes.Roles) == true
                ? [Destinations.AccessToken, Destinations.IdentityToken]
                : [];

        return [];
    }
}

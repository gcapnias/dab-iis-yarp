using System.Security.Claims;
using OpenIddict.Abstractions;
using static OpenIddict.Abstractions.OpenIddictConstants;

namespace IdentityIssuer;

public static class OidcProfileClaims
{
    public const string WindowsSid = "issuer_windows_sid";
    public const string SecurityStamp = "issuer_security_stamp";
    public const string ProfileId = "profile_id";

    public static void Replace(ClaimsIdentity identity, IdentityProfile profile)
    {
        foreach (var claim in identity.Claims.Where(claim =>
                     claim.Type is Claims.Subject or Claims.Name or Claims.Role or ProfileId or WindowsSid or SecurityStamp or OidcClaimDestinations.ClearanceLevel).ToArray())
        {
            identity.RemoveClaim(claim);
        }

        identity.AddClaim(new Claim(Claims.Subject, profile.Subject));
        identity.AddClaim(new Claim(WindowsSid, profile.WindowsSid));
        identity.AddClaim(new Claim(ProfileId, profile.ProfileId));
        if (!string.IsNullOrWhiteSpace(profile.DisplayName))
            identity.AddClaim(new Claim(Claims.Name, profile.DisplayName));
        if (!string.IsNullOrWhiteSpace(profile.SecurityStamp))
            identity.AddClaim(new Claim(SecurityStamp, profile.SecurityStamp));
        foreach (var role in profile.Roles)
            identity.AddClaim(new Claim(Claims.Role, role));
        foreach (var claim in profile.Claims)
            identity.AddClaim(new Claim(claim.Key, claim.Value));

        identity.SetDestinations(OidcClaimDestinations.For);
    }
}

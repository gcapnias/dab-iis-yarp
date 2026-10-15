using System.Security.Claims;
using IdentityIssuer;
using OpenIddict.Abstractions;
using static OpenIddict.Abstractions.OpenIddictConstants;

namespace IdentityIssuer.Tests;

public sealed class OidcProfileClaimsTests
{
    [Fact]
    public void Replacing_profile_reloads_user_role_and_authorization_claims_without_duplicates()
    {
        var identity = new ClaimsIdentity();
        identity.SetScopes(Scopes.OpenId, Scopes.Profile, Scopes.Roles);
        OidcProfileClaims.Replace(identity, new IdentityProfile(
            "S-1-5-21-10-20-30-1001", "subject-2", "profile-2", "Current Display", ["catalog.reader", "auditor"])
        {
            Claims = new Dictionary<string, string> { [OidcClaimDestinations.ClearanceLevel] = "Level3" },
            SecurityStamp = "stamp-current"
        });

        Assert.Equal("subject-2", Assert.Single(identity.FindAll(Claims.Subject)).Value);
        Assert.Equal("profile-2", Assert.Single(identity.FindAll(OidcProfileClaims.ProfileId)).Value);
        Assert.Equal("Current Display", Assert.Single(identity.FindAll(Claims.Name)).Value);
        Assert.Equal("S-1-5-21-10-20-30-1001", Assert.Single(identity.FindAll(OidcProfileClaims.WindowsSid)).Value);
        Assert.Equal("stamp-current", Assert.Single(identity.FindAll(OidcProfileClaims.SecurityStamp)).Value);
        Assert.Equal(new[] { "auditor", "catalog.reader" }, identity.FindAll(Claims.Role).Select(claim => claim.Value).Order().ToArray());
        Assert.Equal("Level3", Assert.Single(identity.FindAll(OidcClaimDestinations.ClearanceLevel)).Value);
        Assert.All(identity.FindAll(Claims.Role), claim => Assert.Contains(Destinations.AccessToken, claim.GetDestinations()));
    }

    [Fact]
    public void Replacing_profile_removes_claims_that_are_no_longer_persisted()
    {
        var identity = new ClaimsIdentity();
        identity.SetScopes(Scopes.OpenId, Scopes.Profile, Scopes.Roles);
        OidcProfileClaims.Replace(identity, new IdentityProfile(
            "sid", "old-subject", "old-profile", "Old Name", ["old-role"])
        {
            Claims = new Dictionary<string, string> { [OidcClaimDestinations.ClearanceLevel] = "Level3" },
            SecurityStamp = "old-stamp"
        });

        OidcProfileClaims.Replace(identity, new IdentityProfile("sid", "new-subject", "new-profile", null, []));

        Assert.Equal("new-subject", Assert.Single(identity.FindAll(Claims.Subject)).Value);
        Assert.Empty(identity.FindAll(Claims.Name));
        Assert.Empty(identity.FindAll(Claims.Role));
        Assert.Empty(identity.FindAll(OidcClaimDestinations.ClearanceLevel));
        Assert.Empty(identity.FindAll(OidcProfileClaims.SecurityStamp));
    }
}

using System.Security.Claims;
using Microsoft.AspNetCore.Identity;
using OpenIddict.Abstractions;
using OpenIddict.Server;
using Microsoft.EntityFrameworkCore;
using static OpenIddict.Abstractions.OpenIddictConstants;

namespace IdentityIssuer;

public sealed class OidcRefreshFamilyRevoker(ApplicationDbContext database, IOpenIddictTokenManager tokens)
{
    public async Task RevokeAsync(string authorizationId, CancellationToken cancellationToken)
    {
        var family = await database.OidcRefreshTokenUses
            .Where(item => item.AuthorizationId == authorizationId && item.FamilyRevokedAt == null)
            .ToListAsync(cancellationToken);
        var revokedAt = DateTimeOffset.UtcNow;
        foreach (var item in family)
            item.FamilyRevokedAt = revokedAt;
        if (family.Count > 0)
            await database.SaveChangesAsync(cancellationToken);
        if (database.Database.IsRelational())
            await tokens.RevokeByAuthorizationIdAsync(authorizationId, cancellationToken);
    }
}

public sealed class DetectOidcRefreshReplay(ApplicationDbContext database, OidcRefreshFamilyRevoker revoker)
    : IOpenIddictServerHandler<OpenIddictServerEvents.ValidateTokenContext>
{
    public async ValueTask HandleAsync(OpenIddictServerEvents.ValidateTokenContext context)
    {
        if (!string.Equals(context.Request?.GrantType, GrantTypes.RefreshToken, StringComparison.Ordinal) ||
            string.IsNullOrWhiteSpace(context.AuthorizationId) || string.IsNullOrWhiteSpace(context.TokenId))
            return;

        var replay = await database.OidcRefreshTokenUses.AnyAsync(item =>
            item.AuthorizationId == context.AuthorizationId && item.TokenId == context.TokenId,
            context.Transaction.CancellationToken);
        if (!replay)
            return;

        await revoker.RevokeAsync(context.AuthorizationId, context.Transaction.CancellationToken);
        context.Reject(Errors.InvalidToken, "The issuer refresh token was already used; the token family was revoked.");
    }
}

public sealed class ValidateOidcRefreshAccountState(
    IdentityProfileResolver profiles,
    UserManager<ApplicationUser> users,
    ApplicationDbContext database,
    OidcRefreshFamilyRevoker revoker)
    : IOpenIddictServerHandler<OpenIddictServerEvents.ProcessAuthenticationContext>
{
    private const string WindowsSidClaim = OidcProfileClaims.WindowsSid;
    private const string SecurityStampClaim = OidcProfileClaims.SecurityStamp;

    public async ValueTask HandleAsync(OpenIddictServerEvents.ProcessAuthenticationContext context)
    {
        if (!string.Equals(context.Request?.GrantType, GrantTypes.RefreshToken, StringComparison.Ordinal))
            return;

        var principal = context.RefreshTokenPrincipal;
        var identity = principal?.Identity as ClaimsIdentity;
        var subject = principal?.FindFirst(Claims.Subject)?.Value;
        var sid = principal?.FindFirst(WindowsSidClaim)?.Value;
        var tokenStamp = principal?.FindFirst(SecurityStampClaim)?.Value;
        if (identity is null || string.IsNullOrWhiteSpace(subject) || string.IsNullOrWhiteSpace(sid))
        {
            context.Reject(Errors.InvalidGrant, "The issuer account is unavailable.");
            return;
        }

        var user = await users.FindByIdAsync(subject);
        if (user is null || !user.IsEnabled || await users.IsLockedOutAsync(user))
        {
            context.Reject(Errors.InvalidGrant, "The issuer account is unavailable.");
            return;
        }
        var currentStamp = await users.GetSecurityStampAsync(user);
        if (!string.Equals(tokenStamp, currentStamp, StringComparison.Ordinal))
        {
            context.Reject(Errors.InvalidGrant, "The issuer account security state has changed.");
            return;
        }

        var windowsPrincipal = new ClaimsPrincipal(new ClaimsIdentity(
            [new Claim(ClaimTypes.PrimarySid, sid)], "issuer-refresh", Claims.Name, Claims.Role));
        var lookup = await profiles.ResolveAsync(windowsPrincipal, context.Transaction.CancellationToken);
        if (!lookup.Succeeded || !string.Equals(lookup.Profile!.Subject, subject, StringComparison.Ordinal))
        {
            context.Reject(Errors.InvalidGrant, "The issuer account is unavailable or no longer provisioned.");
            return;
        }

        var profile = lookup.Profile!;
        if (!string.Equals(tokenStamp, profile.SecurityStamp, StringComparison.Ordinal))
        {
            context.Reject(Errors.InvalidGrant, "The issuer account security state has changed.");
            return;
        }

        OidcProfileClaims.Replace(identity, profile);

        var authorizationId = principal!.GetAuthorizationId();
        var tokenId = principal!.GetTokenId();
        var expiresAt = principal!.GetExpirationDate();
        if (string.IsNullOrWhiteSpace(authorizationId) || string.IsNullOrWhiteSpace(tokenId) || expiresAt is null)
        {
            context.Reject(Errors.InvalidGrant, "The issuer refresh-token family is unavailable.");
            return;
        }

        var familyRevoked = await database.OidcRefreshTokenUses.AnyAsync(item =>
            item.AuthorizationId == authorizationId && item.FamilyRevokedAt != null,
            context.Transaction.CancellationToken);
        if (familyRevoked)
        {
            await revoker.RevokeAsync(authorizationId, context.Transaction.CancellationToken);
            context.Reject(Errors.InvalidGrant, "The issuer refresh-token family was revoked after replay.");
            return;
        }

        var use = new OidcRefreshTokenUse
        {
            AuthorizationId = authorizationId,
            TokenId = tokenId,
            ConsumedAt = DateTimeOffset.UtcNow,
            ExpiresAt = expiresAt.Value
        };
        database.OidcRefreshTokenUses.Add(use);
        try
        {
            await database.SaveChangesAsync(context.Transaction.CancellationToken);
        }
        catch (DbUpdateException)
        {
            database.ChangeTracker.Clear();
            if (await database.OidcRefreshTokenUses.AnyAsync(item =>
                    item.AuthorizationId == authorizationId && item.TokenId == tokenId,
                    context.Transaction.CancellationToken))
            {
                await revoker.RevokeAsync(authorizationId, context.Transaction.CancellationToken);
                context.Reject(Errors.InvalidGrant, "The issuer refresh token was already used; the token family was revoked.");
            }
            else
            {
                throw;
            }
        }
    }
}

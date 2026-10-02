using System.Security.Claims;
using Microsoft.AspNetCore.Identity;
using OpenIddict.Abstractions;
using OpenIddict.Server;
using Microsoft.EntityFrameworkCore;
using static OpenIddict.Abstractions.OpenIddictConstants;

namespace IdentityIssuer;

public sealed class DetectOidcRefreshReplay(ApplicationDbContext database, IOpenIddictTokenManager tokens)
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

        var family = await database.OidcRefreshTokenUses
            .Where(item => item.AuthorizationId == context.AuthorizationId && item.FamilyRevokedAt == null)
            .ToListAsync(context.Transaction.CancellationToken);
        foreach (var item in family)
            item.FamilyRevokedAt = DateTimeOffset.UtcNow;
        await database.SaveChangesAsync(context.Transaction.CancellationToken);
        if (database.Database.IsRelational())
            await tokens.RevokeByAuthorizationIdAsync(context.AuthorizationId, context.Transaction.CancellationToken);
        context.Reject(Errors.InvalidToken, "The issuer refresh token was already used; the token family was revoked.");
    }
}

public sealed class ValidateOidcRefreshAccountState(
    IdentityProfileResolver profiles,
    UserManager<ApplicationUser> users,
    ApplicationDbContext database,
    IOpenIddictTokenManager tokens)
    : IOpenIddictServerHandler<OpenIddictServerEvents.ProcessAuthenticationContext>
{
    private const string WindowsSidClaim = "issuer_windows_sid";
    private const string SecurityStampClaim = "issuer_security_stamp";

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

        foreach (var claim in identity.Claims.Where(claim =>
                     claim.Type is Claims.Subject or Claims.Name or "profile_id" or Claims.Role or "ClearanceLevel" or SecurityStampClaim or WindowsSidClaim).ToArray())
            identity.RemoveClaim(claim);

        identity.AddClaim(new Claim(Claims.Subject, profile.Subject));
        identity.AddClaim(new Claim(WindowsSidClaim, profile.WindowsSid));
        if (!string.IsNullOrWhiteSpace(profile.SecurityStamp))
            identity.AddClaim(new Claim(SecurityStampClaim, profile.SecurityStamp));
        identity.AddClaim(new Claim("profile_id", profile.ProfileId));
        if (!string.IsNullOrWhiteSpace(profile.DisplayName))
            identity.AddClaim(new Claim(Claims.Name, profile.DisplayName));
        foreach (var role in profile.Roles)
            identity.AddClaim(new Claim(Claims.Role, role));
        foreach (var claim in profile.Claims)
            identity.AddClaim(new Claim(claim.Key, claim.Value));

        principal!.SetDestinations(OidcClaimDestinations.For);

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
            if (database.Database.IsRelational())
                await tokens.RevokeByAuthorizationIdAsync(authorizationId, context.Transaction.CancellationToken);
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
                var family = await database.OidcRefreshTokenUses
                    .Where(item => item.AuthorizationId == authorizationId && item.FamilyRevokedAt == null)
                    .ToListAsync(context.Transaction.CancellationToken);
                foreach (var item in family)
                    item.FamilyRevokedAt = DateTimeOffset.UtcNow;
                await database.SaveChangesAsync(context.Transaction.CancellationToken);
                if (database.Database.IsRelational())
                    await tokens.RevokeByAuthorizationIdAsync(authorizationId, context.Transaction.CancellationToken);
                context.Reject(Errors.InvalidGrant, "The issuer refresh token was already used; the token family was revoked.");
            }
            else
            {
                throw;
            }
        }
    }
}

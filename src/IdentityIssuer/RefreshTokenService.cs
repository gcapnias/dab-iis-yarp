using System.Security.Cryptography;
using System.Text;

using Microsoft.EntityFrameworkCore;
using OpenIddict.Abstractions;

namespace IdentityIssuer;

public sealed class RefreshTokenRecord
{
    public long Id { get; set; }
    public required string UserId { get; set; }
    public required string WindowsSid { get; set; }
    public Guid FamilyId { get; set; }
    public required string TokenHash { get; set; }
    public string? SecurityStamp { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? ConsumedAt { get; set; }
    public DateTimeOffset? RevokedAt { get; set; }
    public int Version { get; set; }
}

public sealed class OidcRefreshTokenUse
{
    public required string AuthorizationId { get; set; }
    public required string TokenId { get; set; }
    public DateTimeOffset ConsumedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset? FamilyRevokedAt { get; set; }
}

public enum RefreshTokenRotationStatus
{
    Rotated,
    Invalid,
    ReplayDetected
}

public sealed record RefreshTokenRotationResult(RefreshTokenRotationStatus Status, string? ReplacementToken = null);

public sealed class RefreshTokenService(ApplicationDbContext database, TimeSpan lifetime)
{
    public async Task<string> CreateAsync(IdentityProfile profile, DateTimeOffset now, CancellationToken cancellationToken)
    {
        var token = NewToken();
        database.RefreshTokens.Add(CreateRecord(token, profile, Guid.NewGuid(), now));
        await database.SaveChangesAsync(cancellationToken);
        return token;
    }

    public async Task<RefreshTokenRotationResult> RotateAsync(
        string presentedToken,
        IdentityProfile profile,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        var hash = Hash(presentedToken);
        await using var transaction = database.Database.IsRelational()
            ? await database.Database.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, cancellationToken)
            : null;

        var record = await database.RefreshTokens.SingleOrDefaultAsync(item => item.TokenHash == hash, cancellationToken);
        if (record is null)
        {
            return new(RefreshTokenRotationStatus.Invalid);
        }

        if (record.ConsumedAt is not null)
        {
            await RevokeFamilyAsync(record.FamilyId, now, cancellationToken);
            if (transaction is not null)
                await transaction.CommitAsync(cancellationToken);
            return new(RefreshTokenRotationStatus.ReplayDetected);
        }

        if (record.RevokedAt is not null || record.ExpiresAt <= now)
        {
            return new(RefreshTokenRotationStatus.Invalid);
        }

        if (!string.Equals(record.UserId, profile.Subject, StringComparison.Ordinal) ||
            !string.Equals(record.WindowsSid, profile.WindowsSid, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(record.SecurityStamp, profile.SecurityStamp, StringComparison.Ordinal))
        {
            await RevokeFamilyAsync(record.FamilyId, now, cancellationToken);
            if (transaction is not null)
                await transaction.CommitAsync(cancellationToken);
            return new(RefreshTokenRotationStatus.Invalid);
        }

        var replacement = NewToken();
        record.ConsumedAt = now;
        record.Version++;
        database.RefreshTokens.Add(CreateRecord(replacement, profile, record.FamilyId, now));
        try
        {
            await database.SaveChangesAsync(cancellationToken);
            if (transaction is not null)
                await transaction.CommitAsync(cancellationToken);
            return new(RefreshTokenRotationStatus.Rotated, replacement);
        }
        catch (DbUpdateConcurrencyException)
        {
            if (transaction is not null)
                await transaction.RollbackAsync(cancellationToken);

            database.ChangeTracker.Clear();
            var latest = await database.RefreshTokens.AsNoTracking().SingleOrDefaultAsync(item => item.TokenHash == hash, cancellationToken);
            if (latest?.ConsumedAt is not null)
                await RevokeFamilyAsync(latest.FamilyId, now, cancellationToken);
            return new(RefreshTokenRotationStatus.ReplayDetected);
        }
    }

    public async Task RevokeAsync(string presentedToken, DateTimeOffset now, CancellationToken cancellationToken)
    {
        var hash = Hash(presentedToken);
        var record = await database.RefreshTokens.SingleOrDefaultAsync(item => item.TokenHash == hash, cancellationToken);
        if (record is not null)
        {
            await RevokeFamilyAsync(record.FamilyId, now, cancellationToken);
        }
    }

    public async Task<int> RemoveExpiredAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var expiredFamilies = await database.RefreshTokens
            .Where(item => item.ExpiresAt <= now)
            .Select(item => item.FamilyId)
            .Distinct()
            .ToArrayAsync(cancellationToken);
        if (expiredFamilies.Length == 0)
            return 0;

        var familiesWithLiveTokens = await database.RefreshTokens
            .Where(item => expiredFamilies.Contains(item.FamilyId) && item.ExpiresAt > now && item.RevokedAt == null)
            .Select(item => item.FamilyId)
            .Distinct()
            .ToArrayAsync(cancellationToken);
        var removableFamilies = expiredFamilies.Except(familiesWithLiveTokens).ToArray();
        if (removableFamilies.Length == 0)
            return 0;

        if (database.Database.IsRelational())
            return await database.RefreshTokens.Where(item => removableFamilies.Contains(item.FamilyId)).ExecuteDeleteAsync(cancellationToken);

        var removable = await database.RefreshTokens.Where(item => removableFamilies.Contains(item.FamilyId)).ToListAsync(cancellationToken);
        database.RefreshTokens.RemoveRange(removable);
        await database.SaveChangesAsync(cancellationToken);
        return removable.Count;
    }

    private async Task RevokeFamilyAsync(Guid familyId, DateTimeOffset now, CancellationToken cancellationToken)
    {
        var family = await database.RefreshTokens.Where(item => item.FamilyId == familyId && item.RevokedAt == null)
            .ToListAsync(cancellationToken);
        foreach (var token in family)
        {
            token.RevokedAt = now;
            token.Version++;
        }
        await database.SaveChangesAsync(cancellationToken);
    }

    private RefreshTokenRecord CreateRecord(string token, IdentityProfile profile, Guid familyId, DateTimeOffset now) => new()
    {
        UserId = profile.Subject,
        WindowsSid = profile.WindowsSid,
        FamilyId = familyId,
        TokenHash = Hash(token),
        SecurityStamp = profile.SecurityStamp,
        CreatedAt = now,
        ExpiresAt = now.Add(lifetime)
    };

    private static string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(64))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static string Hash(string token) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
}

public static class OidcRefreshReplayMarkerCleanup
{
    public static async Task<int> RemoveExpiredAsync(
        ApplicationDbContext database,
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        if (database.Database.IsRelational())
            return await database.OidcRefreshTokenUses.Where(item => item.ExpiresAt <= now).ExecuteDeleteAsync(cancellationToken);

        var expired = await database.OidcRefreshTokenUses.Where(item => item.ExpiresAt <= now).ToListAsync(cancellationToken);
        database.OidcRefreshTokenUses.RemoveRange(expired);
        await database.SaveChangesAsync(cancellationToken);
        return expired.Count;
    }
}

public sealed class RefreshTokenCleanupService(IServiceScopeFactory scopeFactory, ILogger<RefreshTokenCleanupService> logger)
    : BackgroundService
{
    private static readonly TimeSpan Period = TimeSpan.FromHours(24);
    private static readonly TimeSpan Retention = TimeSpan.FromDays(30);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(Period);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                await using var scope = scopeFactory.CreateAsyncScope();
                var service = scope.ServiceProvider.GetRequiredService<RefreshTokenService>();
                var now = DateTimeOffset.UtcNow;
                var removed = await service.RemoveExpiredAsync(now, stoppingToken);
                var tokenManager = scope.ServiceProvider.GetRequiredService<IOpenIddictTokenManager>();
                var authorizationManager = scope.ServiceProvider.GetRequiredService<IOpenIddictAuthorizationManager>();
                var database = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();
                var threshold = now.Subtract(Retention);
                var oidcTokens = await tokenManager.PruneAsync(threshold, stoppingToken);
                var authorizations = await authorizationManager.PruneAsync(threshold, stoppingToken);
                var replayMarkers = await OidcRefreshReplayMarkerCleanup.RemoveExpiredAsync(database, now, stoppingToken);
                logger.LogInformation(
                    "Removed {RefreshTokens} expired issuer refresh-token records, {OidcTokens} old OIDC tokens, {Authorizations} old OIDC authorizations and {ReplayMarkers} expired OIDC refresh replay markers.",
                    removed,
                    oidcTokens,
                    authorizations,
                    replayMarkers);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                logger.LogError(exception, "Issuer refresh-token cleanup failed.");
            }
        }
    }
}

using IdentityIssuer;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer.Tests;

public sealed class RefreshTokenServiceTests
{
    [Fact]
    public async Task RotateAsync_rotates_once_and_replay_revokes_the_entire_token_family()
    {
        await using var context = CreateContext();
        await context.Database.EnsureCreatedAsync();
        var tokens = new RefreshTokenService(context, TimeSpan.FromDays(7));
        var profile = new IdentityProfile("sid", "subject-1", "profile-1", null, ["reader"]) { SecurityStamp = "stamp-1" };
        var original = await tokens.CreateAsync(profile, DateTimeOffset.UtcNow, CancellationToken.None);

        var rotated = await tokens.RotateAsync(original, profile, DateTimeOffset.UtcNow, CancellationToken.None);
        var replay = await tokens.RotateAsync(original, profile, DateTimeOffset.UtcNow, CancellationToken.None);

        Assert.Equal(RefreshTokenRotationStatus.Rotated, rotated.Status);
        Assert.NotNull(rotated.ReplacementToken);
        Assert.Equal(RefreshTokenRotationStatus.ReplayDetected, replay.Status);
        Assert.All(await context.RefreshTokens.ToListAsync(), token => Assert.NotNull(token.RevokedAt));
    }

    [Fact]
    public async Task RotateAsync_rejects_a_security_stamp_change_and_revokes_family()
    {
        await using var context = CreateContext();
        await context.Database.EnsureCreatedAsync();
        var tokens = new RefreshTokenService(context, TimeSpan.FromDays(7));
        var originalProfile = new IdentityProfile("sid", "subject-1", "profile-1", null, ["reader"]) { SecurityStamp = "stamp-1" };
        var token = await tokens.CreateAsync(originalProfile, DateTimeOffset.UtcNow, CancellationToken.None);
        var changedProfile = originalProfile with { SecurityStamp = "stamp-2" };

        var result = await tokens.RotateAsync(token, changedProfile, DateTimeOffset.UtcNow, CancellationToken.None);

        Assert.Equal(RefreshTokenRotationStatus.Invalid, result.Status);
        Assert.All(await context.RefreshTokens.ToListAsync(), item => Assert.NotNull(item.RevokedAt));
    }

    [Fact]
    public async Task Cleanup_retains_replayed_ancestor_until_the_entire_family_expires()
    {
        await using var context = CreateContext();
        await context.Database.EnsureCreatedAsync();
        var lifetime = TimeSpan.FromDays(7);
        var tokens = new RefreshTokenService(context, lifetime);
        var profile = new IdentityProfile("sid", "subject-1", "profile-1", null, ["reader"]) { SecurityStamp = "stamp-1" };
        var createdAt = DateTimeOffset.UtcNow;
        var original = await tokens.CreateAsync(profile, createdAt, CancellationToken.None);
        var rotated = await tokens.RotateAsync(original, profile, createdAt.AddDays(6), CancellationToken.None);
        Assert.NotNull(rotated.ReplacementToken);

        var cleanupCount = await tokens.RemoveExpiredAsync(createdAt.AddDays(7).AddSeconds(1), CancellationToken.None);
        var replay = await tokens.RotateAsync(original, profile, createdAt.AddDays(7).AddSeconds(2), CancellationToken.None);

        Assert.Equal(0, cleanupCount);
        Assert.Equal(RefreshTokenRotationStatus.ReplayDetected, replay.Status);
        Assert.All(await context.RefreshTokens.ToListAsync(), item => Assert.NotNull(item.RevokedAt));

        var familyCleanup = await tokens.RemoveExpiredAsync(createdAt.AddDays(14), CancellationToken.None);
        Assert.Equal(2, familyCleanup);
        Assert.Empty(await context.RefreshTokens.ToListAsync());
    }

    private static ApplicationDbContext CreateContext()
    {
        var options = new DbContextOptionsBuilder<ApplicationDbContext>().UseInMemoryDatabase(Guid.NewGuid().ToString("N")).Options;
        return new ApplicationDbContext(options);
    }
}

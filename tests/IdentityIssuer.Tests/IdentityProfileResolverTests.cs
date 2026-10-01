using System.Security.Claims;
using IdentityIssuer;

namespace IdentityIssuer.Tests;

public sealed class IdentityProfileResolverTests
{
    private const string Sid = "S-1-5-21-10-20-30-1001";

    [Fact]
    public async Task ResolveAsync_ignores_an_unauthenticated_principal()
    {
        var directory = new FakeDirectory(new IdentityProfile(Sid, "user-7", "profile-7", "Example User", ["reader"]));
        var resolver = new IdentityProfileResolver(directory);

        var result = await resolver.ResolveAsync(new ClaimsPrincipal(new ClaimsIdentity()), CancellationToken.None);

        Assert.Equal(IdentityLookupFailure.Unauthenticated, result.Failure);
        Assert.Null(directory.RequestedSid);
    }

    [Fact]
    public async Task ResolveAsync_rejects_an_authenticated_principal_without_a_windows_sid()
    {
        var directory = new FakeDirectory(null);
        var resolver = new IdentityProfileResolver(directory);

        var result = await resolver.ResolveAsync(new ClaimsPrincipal(new ClaimsIdentity([new Claim("name", "caller")], "test")), CancellationToken.None);

        Assert.Equal(IdentityLookupFailure.MissingWindowsSid, result.Failure);
        Assert.Null(directory.RequestedSid);
    }

    [Fact]
    public async Task ResolveAsync_looks_up_only_the_authenticated_windows_sid()
    {
        var expected = new IdentityProfile(Sid, "user-7", "profile-7", "Example User", ["reader"]);
        var directory = new FakeDirectory(expected);
        var resolver = new IdentityProfileResolver(directory);

        var result = await resolver.ResolveAsync(Principal(Sid), CancellationToken.None);

        Assert.True(result.Succeeded);
        Assert.Equal(Sid, directory.RequestedSid);
        Assert.Equal(expected, result.Profile);
    }

    [Fact]
    public async Task ResolveAsync_rejects_a_missing_database_mapping()
    {
        var result = await new IdentityProfileResolver(new FakeDirectory(null))
            .ResolveAsync(Principal(Sid), CancellationToken.None);

        Assert.Equal(IdentityLookupFailure.NoProfileMapping, result.Failure);
    }

    [Fact]
    public async Task ResolveAsync_rejects_a_database_row_for_a_different_sid()
    {
        var directory = new FakeDirectory(new IdentityProfile("S-1-5-21-10-20-30-9999", "user-7", "profile-7", "Example User", ["reader"]));

        var result = await new IdentityProfileResolver(directory).ResolveAsync(Principal(Sid), CancellationToken.None);

        Assert.Equal(IdentityLookupFailure.WindowsSidMismatch, result.Failure);
    }

    [Fact]
    public async Task ResolveAsync_rejects_a_mapped_profile_without_named_roles()
    {
        var directory = new FakeDirectory(new IdentityProfile(Sid, "user-7", "profile-7", "Example User", []));

        var result = await new IdentityProfileResolver(directory).ResolveAsync(Principal(Sid), CancellationToken.None);

        Assert.Equal(IdentityLookupFailure.NoRoles, result.Failure);
    }

    private static ClaimsPrincipal Principal(string sid) =>
        new(new ClaimsIdentity([new Claim(ClaimTypes.PrimarySid, sid)], "test"));

    private sealed class FakeDirectory(IdentityProfile? profile) : IIdentityDirectory
    {
        public string? RequestedSid { get; private set; }

        public Task<IdentityProfile?> FindByWindowsSidAsync(string sid, CancellationToken cancellationToken)
        {
            RequestedSid = sid;
            return Task.FromResult(profile);
        }
    }
}

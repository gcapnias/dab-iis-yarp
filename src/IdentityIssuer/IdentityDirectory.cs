using System.Runtime.Versioning;
using System.Security.Claims;
using System.Security.Principal;

using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer;

public sealed record IdentityProfile(string WindowsSid, string Subject, string ProfileId, string? DisplayName, IReadOnlyList<string> Roles)
{
    public bool IsEnabled { get; init; } = true;
    public bool IsLockedOut { get; init; }
    public string? SecurityStamp { get; init; }
    public IReadOnlyDictionary<string, string> Claims { get; init; } = new Dictionary<string, string>(StringComparer.Ordinal);
}

public interface IIdentityDirectory
{
    Task<IdentityProfile?> FindByWindowsSidAsync(string sid, CancellationToken cancellationToken);
}

public sealed class AspNetIdentityDirectory(
    UserManager<ApplicationUser> users,
    RoleManager<IdentityRole> roles) : IIdentityDirectory
{
    public async Task<IdentityProfile?> FindByWindowsSidAsync(string sid, CancellationToken cancellationToken)
    {
        var user = await users.Users.SingleOrDefaultAsync(user => user.WindowsSid == sid, cancellationToken);
        if (user is null)
        {
            return null;
        }

        var isLockedOut = await users.IsLockedOutAsync(user);
        var userClaims = await users.GetClaimsAsync(user);
        var assignedRoles = await users.GetRolesAsync(user);
        var roleNames = new List<string>(assignedRoles.Count);
        var mappedClaims = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        AddMappedClaims(mappedClaims, userClaims);
        foreach (var assignedRole in assignedRoles)
        {
            var role = await roles.FindByNameAsync(assignedRole);
            if (role?.Name is null)
            {
                return new IdentityProfile(user.WindowsSid, user.Id, user.ProfileId, user.DisplayName, [])
                {
                    IsEnabled = user.IsEnabled,
                    IsLockedOut = isLockedOut,
                    SecurityStamp = await users.GetSecurityStampAsync(user)
                };
            }

            roleNames.Add(role.Name);
            AddMappedClaims(mappedClaims, await roles.GetClaimsAsync(role));
        }

        if (mappedClaims.Values.Any(values => values.Count != 1))
        {
            return new IdentityProfile(user.WindowsSid, user.Id, user.ProfileId, user.DisplayName, [])
            {
                IsEnabled = user.IsEnabled,
                IsLockedOut = isLockedOut,
                SecurityStamp = await users.GetSecurityStampAsync(user)
            };
        }

        return new IdentityProfile(user.WindowsSid, user.Id, user.ProfileId, user.DisplayName, roleNames)
        {
            IsEnabled = user.IsEnabled,
            IsLockedOut = isLockedOut,
            SecurityStamp = await users.GetSecurityStampAsync(user),
            Claims = mappedClaims.ToDictionary(pair => pair.Key, pair => pair.Value.Single(), StringComparer.Ordinal)
        };
    }

    private static void AddMappedClaims(IDictionary<string, HashSet<string>> target, IEnumerable<Claim> claims)
    {
        foreach (var claim in claims)
        {
            // This is the only persisted authorization claim currently part of the issuer contract.
            // Identity's other profile/security claims (email, security stamp, etc.) are not copied to tokens.
            if (!string.Equals(claim.Type, "ClearanceLevel", StringComparison.Ordinal) ||
                string.IsNullOrWhiteSpace(claim.Value) || claim.Value.Length > 32 || claim.Value.Any(char.IsControl))
            {
                continue;
            }

            if (!target.TryGetValue(claim.Type, out var values))
            {
                values = new HashSet<string>(StringComparer.Ordinal);
                target.Add(claim.Type, values);
            }

            values.Add(claim.Value);
        }
    }
}

public static class AuthenticatedWindowsIdentity
{
    public static WindowsAuthenticationDiagnostic Describe(ClaimsPrincipal principal)
    {
        if (!OperatingSystem.IsWindows())
        {
            return new WindowsAuthenticationDiagnostic(
                principal.Identity?.GetType().Name,
                principal.Claims.Any(claim =>
                    (claim.Type == ClaimTypes.PrimarySid || claim.Type == ClaimTypes.Sid) &&
                    !string.IsNullOrWhiteSpace(claim.Value)),
                false,
                false);
        }

        return DescribeWindowsPrincipal(principal);
    }

    [SupportedOSPlatform("windows")]
    private static WindowsAuthenticationDiagnostic DescribeWindowsPrincipal(ClaimsPrincipal principal)
    {
        var windowsIdentities = principal.Identities.OfType<WindowsIdentity>().ToArray();
        return new WindowsAuthenticationDiagnostic(
            principal.Identity?.GetType().Name,
            principal.Claims.Any(claim =>
                (claim.Type == ClaimTypes.PrimarySid || claim.Type == ClaimTypes.Sid) &&
                !string.IsNullOrWhiteSpace(claim.Value)),
            windowsIdentities.Length > 0,
            windowsIdentities.Any(identity => identity.User is not null));
    }

    public static string? GetSid(ClaimsPrincipal principal)
    {
        if (principal.Identity?.IsAuthenticated != true)
        {
            return null;
        }

        // The caller's request principal is authoritative. WindowsIdentity.GetCurrent() can
        // identify the worker process rather than the authenticated request user.
        var claim = principal.Claims.FirstOrDefault(claim =>
            claim.Type == ClaimTypes.PrimarySid || claim.Type == ClaimTypes.Sid)?.Value;
        if (!string.IsNullOrWhiteSpace(claim))
        {
            return claim;
        }

        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        return GetWindowsIdentitySid(principal);
    }

    [SupportedOSPlatform("windows")]
    private static string? GetWindowsIdentitySid(ClaimsPrincipal principal) => principal.Identities.OfType<WindowsIdentity>()
            .Select(identity => identity.User?.Value)
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));
}

public sealed record WindowsAuthenticationDiagnostic(
    string? IdentityType,
    bool HasSidClaim,
    bool HasRequestWindowsIdentity,
    bool HasRequestWindowsIdentityUser);

public enum IdentityLookupFailure
{
    Unauthenticated,
    MissingWindowsSid,
    NoProfileMapping,
    WindowsSidMismatch,
    NoRoles,
    AccountDisabled,
    AccountLocked,
    ConflictingClaims
}

public sealed record IdentityLookupResult(IdentityProfile? Profile, IdentityLookupFailure? Failure)
{
    public bool Succeeded => Profile is not null && Failure is null;
}

public sealed class IdentityProfileResolver(IIdentityDirectory directory)
{
    public async Task<IdentityLookupResult> ResolveAsync(ClaimsPrincipal principal, CancellationToken cancellationToken)
    {
        if (principal.Identity?.IsAuthenticated != true)
        {
            return new(null, IdentityLookupFailure.Unauthenticated);
        }

        var sid = AuthenticatedWindowsIdentity.GetSid(principal);
        if (string.IsNullOrWhiteSpace(sid))
        {
            return new(null, IdentityLookupFailure.MissingWindowsSid);
        }

        var profile = await directory.FindByWindowsSidAsync(sid, cancellationToken);
        if (profile is null)
        {
            return new(null, IdentityLookupFailure.NoProfileMapping);
        }

        if (!string.Equals(profile.WindowsSid, sid, StringComparison.OrdinalIgnoreCase))
        {
            return new(null, IdentityLookupFailure.WindowsSidMismatch);
        }

        if (!profile.IsEnabled)
        {
            return new(null, IdentityLookupFailure.AccountDisabled);
        }

        if (profile.IsLockedOut)
        {
            return new(null, IdentityLookupFailure.AccountLocked);
        }

        if (profile.Claims.Any(pair => pair.Key != "ClearanceLevel" || string.IsNullOrWhiteSpace(pair.Value)))
        {
            return new(null, IdentityLookupFailure.ConflictingClaims);
        }

        if (profile.Roles.Count == 0 || profile.Roles.Any(string.IsNullOrWhiteSpace))
        {
            return new(null, IdentityLookupFailure.NoRoles);
        }

        return new(profile, null);
    }
}

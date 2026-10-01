using System.Runtime.Versioning;
using System.Security.Claims;
using System.Security.Principal;

using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer;

public sealed record IdentityProfile(string WindowsSid, string Subject, string ProfileId, string? DisplayName, IReadOnlyList<string> Roles);

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

        var assignedRoles = await users.GetRolesAsync(user);
        var roleNames = new List<string>(assignedRoles.Count);
        foreach (var assignedRole in assignedRoles)
        {
            var role = await roles.FindByNameAsync(assignedRole);
            if (role?.Name is null)
            {
                return new IdentityProfile(user.WindowsSid, user.Id, user.ProfileId, user.DisplayName, []);
            }

            roleNames.Add(role.Name);
        }

        return new IdentityProfile(user.WindowsSid, user.Id, user.ProfileId, user.DisplayName, roleNames);
    }
}

public static class AuthenticatedWindowsIdentity
{
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

public enum IdentityLookupFailure
{
    Unauthenticated,
    MissingWindowsSid,
    NoProfileMapping,
    WindowsSidMismatch,
    NoRoles
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

        if (profile.Roles.Count == 0 || profile.Roles.Any(string.IsNullOrWhiteSpace))
        {
            return new(null, IdentityLookupFailure.NoRoles);
        }

        return new(profile, null);
    }
}
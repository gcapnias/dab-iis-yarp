using System.Security.Principal;

using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer;

public sealed class IdentityProvisioner(
    ApplicationDbContext database,
    UserManager<ApplicationUser> users,
    RoleManager<IdentityRole> roles)
{
    public async Task ProvisionAsync(
        string windowsSid,
        string profileId,
        string? displayName,
        IReadOnlyCollection<string> roleNames,
        CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Identity provisioning requires a Windows development host.");
        }

        _ = new SecurityIdentifier(windowsSid);
        if (string.IsNullOrWhiteSpace(profileId) || profileId.Length > 64)
        {
            throw new ArgumentException("ProfileId must contain between 1 and 64 characters.", nameof(profileId));
        }

        var normalizedRoles = roleNames.Select(role => role.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (normalizedRoles.Length == 0 || normalizedRoles.Any(string.IsNullOrWhiteSpace))
        {
            throw new ArgumentException("At least one non-empty role is required.", nameof(roleNames));
        }

        if (await users.Users.AnyAsync(user => user.WindowsSid == windowsSid, cancellationToken))
        {
            throw new InvalidOperationException("A user is already mapped to this Windows SID.");
        }

        if (await users.Users.AnyAsync(user => user.ProfileId == profileId, cancellationToken))
        {
            throw new InvalidOperationException("The ProfileId is already in use.");
        }

        await using var transaction = await database.Database.BeginTransactionAsync(cancellationToken);
        var user = new ApplicationUser
        {
            UserName = windowsSid,
            WindowsSid = windowsSid,
            ProfileId = profileId,
            DisplayName = string.IsNullOrWhiteSpace(displayName) ? null : displayName.Trim()
        };
        EnsureSuccess(await users.CreateAsync(user));

        foreach (var roleName in normalizedRoles)
        {
            var role = await roles.FindByNameAsync(roleName);
            if (role is null)
            {
                role = new IdentityRole(roleName);
                EnsureSuccess(await roles.CreateAsync(role));
            }

            EnsureSuccess(await users.AddToRoleAsync(user, role.Name!));
        }

        await transaction.CommitAsync(cancellationToken);
    }

    private static void EnsureSuccess(IdentityResult result)
    {
        if (!result.Succeeded)
        {
            throw new InvalidOperationException("ASP.NET Core Identity rejected the provisioning operation: " +
                string.Join(", ", result.Errors.Select(error => error.Code)));
        }
    }
}
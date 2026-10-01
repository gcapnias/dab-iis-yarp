using IdentityIssuer;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace IdentityIssuer.Tests;

public sealed class AspNetIdentityDirectoryTests
{
    private const string Sid = "S-1-5-21-10-20-30-1001";

    [Fact]
    public async Task FindByWindowsSidAsync_returns_only_persisted_profile_and_assigned_identity_roles()
    {
        var services = CreateServices();
        await using var provider = services.BuildServiceProvider();
        await using var scope = provider.CreateAsyncScope();
        var userManager = scope.ServiceProvider.GetRequiredService<UserManager<ApplicationUser>>();
        var roleManager = scope.ServiceProvider.GetRequiredService<RoleManager<IdentityRole>>();
        var role = new IdentityRole("catalog.reader");
        Assert.True((await roleManager.CreateAsync(role)).Succeeded);
        var user = new ApplicationUser
        {
            UserName = Sid,
            WindowsSid = Sid,
            ProfileId = "catalog-profile-1",
            DisplayName = "Fixture User"
        };
        Assert.True((await userManager.CreateAsync(user)).Succeeded);
        Assert.True((await userManager.AddToRoleAsync(user, role.Name!)).Succeeded);

        var directory = new AspNetIdentityDirectory(userManager, roleManager);
        var profile = await directory.FindByWindowsSidAsync(Sid, CancellationToken.None);

        Assert.NotNull(profile);
        Assert.Equal(Sid, profile.WindowsSid);
        Assert.Equal(user.Id, profile.Subject);
        Assert.Equal("catalog-profile-1", profile.ProfileId);
        Assert.Equal("Fixture User", profile.DisplayName);
        Assert.Equal(["catalog.reader"], profile.Roles);
    }

    [Fact]
    public async Task FindByWindowsSidAsync_returns_null_for_an_unmapped_sid()
    {
        var services = CreateServices();
        await using var provider = services.BuildServiceProvider();
        await using var scope = provider.CreateAsyncScope();
        var userManager = scope.ServiceProvider.GetRequiredService<UserManager<ApplicationUser>>();
        var roleManager = scope.ServiceProvider.GetRequiredService<RoleManager<IdentityRole>>();
        await scope.ServiceProvider.GetRequiredService<ApplicationDbContext>().Database.EnsureCreatedAsync();

        var profile = await new AspNetIdentityDirectory(userManager, roleManager)
            .FindByWindowsSidAsync(Sid, CancellationToken.None);

        Assert.Null(profile);
    }

    private static ServiceCollection CreateServices()
    {
        var services = new ServiceCollection();
        services.AddLogging(logging => logging.SetMinimumLevel(LogLevel.Warning));
        services.AddDbContext<ApplicationDbContext>(options => options.UseInMemoryDatabase(Guid.NewGuid().ToString("N")));
        services.AddIdentityCore<ApplicationUser>().AddRoles<IdentityRole>().AddEntityFrameworkStores<ApplicationDbContext>();
        return services;
    }
}

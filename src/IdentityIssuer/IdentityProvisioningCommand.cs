using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace IdentityIssuer;

public static class IdentityProvisioningCommand
{
    private const string ProvisioningFlag = "--provision-identity";

    public static bool IsRequested(IEnumerable<string> args) =>
        args.Contains(ProvisioningFlag, StringComparer.OrdinalIgnoreCase);

    public static async Task RunAsync(string[] args)
    {
        var hostArgs = args.Where(argument => !string.Equals(argument, ProvisioningFlag, StringComparison.OrdinalIgnoreCase)).ToArray();
        var builder = Host.CreateApplicationBuilder(hostArgs);
        var connectionString = builder.Configuration.GetConnectionString("IssuerIdentity")
            ?? throw new InvalidOperationException("ConnectionStrings:IssuerIdentity is required.");
        builder.Services.AddIssuerIdentityDatabase(connectionString);
        builder.Services.AddIssuerIdentityStores();
        builder.Services.AddScoped<IdentityProvisioner>();

        using var host = builder.Build();
        await using var scope = host.Services.CreateAsyncScope();
        var provisioner = scope.ServiceProvider.GetRequiredService<IdentityProvisioner>();
        await RunPromptAsync(provisioner);
    }

    private static async Task RunPromptAsync(IdentityProvisioner provisioner)
    {
        Console.WriteLine("Create an Identity profile mapped to a Windows SID. This local command grants only the roles entered by the operator.");
        Console.Write("Windows SID: ");
        var sid = Console.ReadLine() ?? string.Empty;
        Console.Write("Profile ID: ");
        var profileId = Console.ReadLine() ?? string.Empty;
        Console.Write("Display name (optional): ");
        var displayName = Console.ReadLine();
        Console.Write("Roles (comma separated): ");
        var roles = (Console.ReadLine() ?? string.Empty).Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);

        await provisioner.ProvisionAsync(sid, profileId, displayName, roles);
        Console.WriteLine("Identity profile provisioned.");
    }
}
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace IdentityIssuer;

public static class IssuerIdentityDatabase
{
    public static void ValidateNorthwindConnectionString(string connectionString)
    {
        var parsed = new SqlConnectionStringBuilder(connectionString);
        if (!string.Equals(parsed.InitialCatalog, "northwind", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("ConnectionStrings:IssuerIdentity must target the Northwind database.");
        }
    }

    public static IServiceCollection AddIssuerIdentityDatabase(this IServiceCollection services, string connectionString)
    {
        ValidateNorthwindConnectionString(connectionString);
        services.AddDbContext<ApplicationDbContext>(options => options.UseSqlServer(connectionString,
            sql => sql.MigrationsHistoryTable("__EFMigrationsHistory", ApplicationDbContext.IdentitySchema)));
        return services;
    }

    public static IServiceCollection AddIssuerIdentityStores(this IServiceCollection services)
    {
        services.AddIdentityCore<ApplicationUser>()
            .AddRoles<IdentityRole>()
            .AddEntityFrameworkStores<ApplicationDbContext>();
        return services;
    }
}
using Microsoft.AspNetCore.Identity;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace IdentityIssuer;

public static class IssuerIdentityDatabase
{
    public static void ValidateIssuerConnectionString(string connectionString)
    {
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            throw new InvalidOperationException("ConnectionStrings:IssuerIdentity must contain a SQL Server connection string.");
        }

        var parsed = new SqlConnectionStringBuilder(connectionString);
        if (string.IsNullOrWhiteSpace(parsed.InitialCatalog))
        {
            throw new InvalidOperationException("ConnectionStrings:IssuerIdentity must specify a database catalog.");
        }
    }

    public static IServiceCollection AddIssuerIdentityDatabase(this IServiceCollection services, string connectionString)
    {
        ValidateIssuerConnectionString(connectionString);
        services.AddDbContext<ApplicationDbContext>(options => options.UseSqlServer(connectionString,
            sql => sql.MigrationsHistoryTable("__EFMigrationsHistory", ApplicationDbContext.IdentitySchema)).UseOpenIddict());
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

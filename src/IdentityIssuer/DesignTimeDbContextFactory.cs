using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace IdentityIssuer;

public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<ApplicationDbContext>
{
    public ApplicationDbContext CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__IssuerIdentity")
            ?? throw new InvalidOperationException("Set ConnectionStrings__IssuerIdentity to a Northwind development connection string before using EF tooling.");
        var parsed = new SqlConnectionStringBuilder(connectionString);
        if (!string.Equals(parsed.InitialCatalog, "northwind", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("ConnectionStrings__IssuerIdentity must target the Northwind database.");
        }

        var options = new DbContextOptionsBuilder<ApplicationDbContext>()
            .UseSqlServer(connectionString, sql =>
                sql.MigrationsHistoryTable("__EFMigrationsHistory", ApplicationDbContext.IdentitySchema))
            .Options;
        return new ApplicationDbContext(options);
    }
}
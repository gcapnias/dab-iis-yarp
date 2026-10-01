using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace IdentityIssuer;

public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<ApplicationDbContext>
{
    public ApplicationDbContext CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__IssuerIdentity")
            ?? throw new InvalidOperationException("Set ConnectionStrings__IssuerIdentity to a Northwind development connection string before using EF tooling.");
        IssuerIdentityDatabase.ValidateNorthwindConnectionString(connectionString);

        var options = new DbContextOptionsBuilder<ApplicationDbContext>()
            .UseSqlServer(connectionString, sql =>
                sql.MigrationsHistoryTable("__EFMigrationsHistory", ApplicationDbContext.IdentitySchema))
            .Options;
        return new ApplicationDbContext(options);
    }
}
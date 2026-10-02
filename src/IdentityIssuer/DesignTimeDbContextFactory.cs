using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace IdentityIssuer;

public sealed class DesignTimeDbContextFactory : IDesignTimeDbContextFactory<ApplicationDbContext>
{
    public ApplicationDbContext CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("ConnectionStrings__IssuerIdentity")
            ?? throw new InvalidOperationException("Set ConnectionStrings__IssuerIdentity to the intended SQL Server database before using EF tooling.");
        IssuerIdentityDatabase.ValidateIssuerConnectionString(connectionString);

        var options = new DbContextOptionsBuilder<ApplicationDbContext>()
            .UseSqlServer(connectionString, sql =>
                sql.MigrationsHistoryTable("__EFMigrationsHistory", ApplicationDbContext.IdentitySchema))
            .Options;
        return new ApplicationDbContext(options);
    }
}

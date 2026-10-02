using IdentityIssuer;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer.Tests;

public sealed class ApplicationDbContextTests
{
    [Fact]
    public void Connection_validator_accepts_any_explicit_catalog_without_connecting()
    {
        IssuerIdentityDatabase.ValidateIssuerConnectionString(
            "Server=(local);Database=issuer-test;Integrated Security=true;TrustServerCertificate=true");
    }

    [Fact]
    public void Connection_validator_requires_an_explicit_catalog()
    {
        var exception = Assert.Throws<InvalidOperationException>(() =>
            IssuerIdentityDatabase.ValidateIssuerConnectionString("Server=(local);Integrated Security=true"));

        Assert.Contains("catalog", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Identity_tables_use_a_dedicated_schema_and_unique_external_mapping_keys()
    {
        var options = new DbContextOptionsBuilder<ApplicationDbContext>()
            .UseSqlServer("Server=(local);Database=northwind;Integrated Security=true;TrustServerCertificate=true")
            .Options;
        using var context = new ApplicationDbContext(options);

        var user = context.Model.FindEntityType(typeof(ApplicationUser))!;
        var role = context.Model.FindEntityType(typeof(IdentityRole))!;

        Assert.Equal(ApplicationDbContext.IdentitySchema, user.GetSchema());
        Assert.Equal(ApplicationDbContext.IdentitySchema, role.GetSchema());
        Assert.Contains(user.GetIndexes(), index =>
            index.IsUnique && index.Properties.Select(property => property.Name).SequenceEqual([nameof(ApplicationUser.WindowsSid)]));
        Assert.Contains(user.GetIndexes(), index =>
            index.IsUnique && index.Properties.Select(property => property.Name).SequenceEqual([nameof(ApplicationUser.ProfileId)]));
    }
}

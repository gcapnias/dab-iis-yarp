using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer;

public sealed class ApplicationDbContext(DbContextOptions<ApplicationDbContext> options)
    : IdentityDbContext<ApplicationUser, IdentityRole, string>(options)
{
    public const string IdentitySchema = "IdentityIssuer";

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        modelBuilder.HasDefaultSchema(IdentitySchema);
        modelBuilder.Entity<ApplicationUser>(user =>
        {
            user.Property(item => item.WindowsSid).HasMaxLength(184).IsRequired();
            user.Property(item => item.ProfileId).HasMaxLength(64).IsRequired();
            user.Property(item => item.DisplayName).HasMaxLength(128);
            user.HasIndex(item => item.WindowsSid).IsUnique();
            user.HasIndex(item => item.ProfileId).IsUnique();
        });
    }
}
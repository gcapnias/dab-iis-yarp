using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

namespace IdentityIssuer;

public sealed class ApplicationDbContext(DbContextOptions<ApplicationDbContext> options)
    : IdentityDbContext<ApplicationUser, IdentityRole, string>(options)
{
    public const string IdentitySchema = "IdentityIssuer";
    public DbSet<RefreshTokenRecord> RefreshTokens => Set<RefreshTokenRecord>();
    public DbSet<OidcRefreshTokenUse> OidcRefreshTokenUses => Set<OidcRefreshTokenUse>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        modelBuilder.UseOpenIddict();
        modelBuilder.HasDefaultSchema(IdentitySchema);
        modelBuilder.Entity<ApplicationUser>(user =>
        {
            user.Property(item => item.WindowsSid).HasMaxLength(184).IsRequired();
            user.Property(item => item.ProfileId).HasMaxLength(64).IsRequired();
            user.Property(item => item.DisplayName).HasMaxLength(128);
            user.Property(item => item.IsEnabled).HasDefaultValue(true).IsRequired();
            user.HasIndex(item => item.WindowsSid).IsUnique();
            user.HasIndex(item => item.ProfileId).IsUnique();
        });
        modelBuilder.Entity<RefreshTokenRecord>(token =>
        {
            token.ToTable("RefreshTokens", IdentitySchema);
            token.HasKey(item => item.Id);
            token.Property(item => item.UserId).HasMaxLength(450).IsRequired();
            token.Property(item => item.WindowsSid).HasMaxLength(184).IsRequired();
            token.Property(item => item.TokenHash).HasMaxLength(64).IsRequired();
            token.Property(item => item.SecurityStamp).HasMaxLength(256);
            token.Property(item => item.Version).IsConcurrencyToken();
            token.HasIndex(item => item.TokenHash).IsUnique();
            token.HasIndex(item => new { item.UserId, item.FamilyId });
            token.HasIndex(item => item.ExpiresAt);
            token.HasOne<ApplicationUser>().WithMany().HasForeignKey(item => item.UserId).OnDelete(DeleteBehavior.Cascade);
        });
        modelBuilder.Entity<OidcRefreshTokenUse>(token =>
        {
            token.ToTable("OidcRefreshTokenUses", IdentitySchema);
            token.HasKey(item => new { item.AuthorizationId, item.TokenId });
            token.Property(item => item.AuthorizationId).HasMaxLength(450);
            token.Property(item => item.TokenId).HasMaxLength(450);
            token.Property(item => item.ExpiresAt).IsRequired();
        });
    }
}

using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace IdentityIssuer.Migrations
{
    /// <inheritdoc />
    public partial class BoundOidcRefreshMarkerOrphans : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.Sql("""
                UPDATE [uses]
                SET [ExpiresAt] = DATEADD(day, 30, [uses].[ConsumedAt])
                FROM [IdentityIssuer].[OidcRefreshTokenUses] AS [uses]
                LEFT JOIN [IdentityIssuer].[OpenIddictTokens] AS [tokens] ON [tokens].[Id] = [uses].[TokenId]
                WHERE [tokens].[Id] IS NULL OR [tokens].[ExpirationDate] IS NULL;
                """);

        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            // The original expiry is unavailable for markers whose token entry was already pruned.
        }
    }
}

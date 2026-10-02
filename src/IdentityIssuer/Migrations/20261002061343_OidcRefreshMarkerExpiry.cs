using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace IdentityIssuer.Migrations
{
    /// <inheritdoc />
    public partial class OidcRefreshMarkerExpiry : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "ExpiresAt",
                schema: "IdentityIssuer",
                table: "OidcRefreshTokenUses",
                type: "datetimeoffset",
                nullable: false,
                defaultValue: new DateTimeOffset(new DateTime(1, 1, 1, 0, 0, 0, 0, DateTimeKind.Unspecified), new TimeSpan(0, 0, 0, 0, 0)));

            migrationBuilder.Sql("""
                UPDATE [uses]
                SET [ExpiresAt] = COALESCE(CONVERT(datetimeoffset, [tokens].[ExpirationDate]), CONVERT(datetimeoffset, '9999-12-31T23:59:59+00:00'))
                FROM [IdentityIssuer].[OidcRefreshTokenUses] AS [uses]
                LEFT JOIN [IdentityIssuer].[OpenIddictTokens] AS [tokens] ON [tokens].[Id] = [uses].[TokenId];
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "ExpiresAt",
                schema: "IdentityIssuer",
                table: "OidcRefreshTokenUses");
        }
    }
}

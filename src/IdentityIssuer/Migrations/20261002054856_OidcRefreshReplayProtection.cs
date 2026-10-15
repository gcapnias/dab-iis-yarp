using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace IdentityIssuer.Migrations
{
    /// <inheritdoc />
    public partial class OidcRefreshReplayProtection : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "OidcRefreshTokenUses",
                schema: "IdentityIssuer",
                columns: table => new
                {
                    AuthorizationId = table.Column<string>(type: "nvarchar(450)", maxLength: 450, nullable: false),
                    TokenId = table.Column<string>(type: "nvarchar(450)", maxLength: 450, nullable: false),
                    ConsumedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    FamilyRevokedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_OidcRefreshTokenUses", x => new { x.AuthorizationId, x.TokenId });
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "OidcRefreshTokenUses",
                schema: "IdentityIssuer");
        }
    }
}

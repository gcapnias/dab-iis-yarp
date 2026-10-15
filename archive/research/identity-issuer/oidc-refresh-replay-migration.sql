BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002054856_OidcRefreshReplayProtection'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[OidcRefreshTokenUses] (
        [AuthorizationId] nvarchar(450) NOT NULL,
        [TokenId] nvarchar(450) NOT NULL,
        [ConsumedAt] datetimeoffset NOT NULL,
        [FamilyRevokedAt] datetimeoffset NULL,
        CONSTRAINT [PK_OidcRefreshTokenUses] PRIMARY KEY ([AuthorizationId], [TokenId])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002054856_OidcRefreshReplayProtection'
)
BEGIN
    INSERT INTO [IdentityIssuer].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261002054856_OidcRefreshReplayProtection', N'10.0.12');
END;

COMMIT;
GO

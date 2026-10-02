BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002061343_OidcRefreshMarkerExpiry'
)
BEGIN
    ALTER TABLE [IdentityIssuer].[OidcRefreshTokenUses] ADD [ExpiresAt] datetimeoffset NOT NULL DEFAULT '0001-01-01T00:00:00.0000000+00:00';
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002061343_OidcRefreshMarkerExpiry'
)
BEGIN
    UPDATE [uses]
    SET [ExpiresAt] = COALESCE(CONVERT(datetimeoffset, [tokens].[ExpirationDate]), CONVERT(datetimeoffset, '9999-12-31T23:59:59+00:00'))
    FROM [IdentityIssuer].[OidcRefreshTokenUses] AS [uses]
    LEFT JOIN [IdentityIssuer].[OpenIddictTokens] AS [tokens] ON [tokens].[Id] = [uses].[TokenId];
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002061343_OidcRefreshMarkerExpiry'
)
BEGIN
    INSERT INTO [IdentityIssuer].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261002061343_OidcRefreshMarkerExpiry', N'10.0.12');
END;

COMMIT;
GO

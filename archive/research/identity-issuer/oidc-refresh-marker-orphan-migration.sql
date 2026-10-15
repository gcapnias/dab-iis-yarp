BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002062249_BoundOidcRefreshMarkerOrphans'
)
BEGIN
    UPDATE [uses]
    SET [ExpiresAt] = DATEADD(day, 30, [uses].[ConsumedAt])
    FROM [IdentityIssuer].[OidcRefreshTokenUses] AS [uses]
    LEFT JOIN [IdentityIssuer].[OpenIddictTokens] AS [tokens] ON [tokens].[Id] = [uses].[TokenId]
    WHERE [tokens].[Id] IS NULL OR [tokens].[ExpirationDate] IS NULL;
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002062249_BoundOidcRefreshMarkerOrphans'
)
BEGIN
    INSERT INTO [IdentityIssuer].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261002062249_BoundOidcRefreshMarkerOrphans', N'10.0.12');
END;

COMMIT;
GO

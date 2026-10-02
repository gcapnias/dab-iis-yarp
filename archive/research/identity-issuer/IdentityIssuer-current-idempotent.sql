IF OBJECT_ID(N'[IdentityIssuer].[__EFMigrationsHistory]') IS NULL
BEGIN
    IF SCHEMA_ID(N'IdentityIssuer') IS NULL EXEC(N'CREATE SCHEMA [IdentityIssuer];');
    CREATE TABLE [IdentityIssuer].[__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    IF SCHEMA_ID(N'IdentityIssuer') IS NULL EXEC(N'CREATE SCHEMA [IdentityIssuer];');
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetRoles] (
        [Id] nvarchar(450) NOT NULL,
        [Name] nvarchar(256) NULL,
        [NormalizedName] nvarchar(256) NULL,
        [ConcurrencyStamp] nvarchar(max) NULL,
        CONSTRAINT [PK_AspNetRoles] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetUsers] (
        [Id] nvarchar(450) NOT NULL,
        [WindowsSid] nvarchar(184) NOT NULL,
        [ProfileId] nvarchar(64) NOT NULL,
        [DisplayName] nvarchar(128) NULL,
        [UserName] nvarchar(256) NULL,
        [NormalizedUserName] nvarchar(256) NULL,
        [Email] nvarchar(256) NULL,
        [NormalizedEmail] nvarchar(256) NULL,
        [EmailConfirmed] bit NOT NULL,
        [PasswordHash] nvarchar(max) NULL,
        [SecurityStamp] nvarchar(max) NULL,
        [ConcurrencyStamp] nvarchar(max) NULL,
        [PhoneNumber] nvarchar(max) NULL,
        [PhoneNumberConfirmed] bit NOT NULL,
        [TwoFactorEnabled] bit NOT NULL,
        [LockoutEnd] datetimeoffset NULL,
        [LockoutEnabled] bit NOT NULL,
        [AccessFailedCount] int NOT NULL,
        CONSTRAINT [PK_AspNetUsers] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetRoleClaims] (
        [Id] int NOT NULL IDENTITY,
        [RoleId] nvarchar(450) NOT NULL,
        [ClaimType] nvarchar(max) NULL,
        [ClaimValue] nvarchar(max) NULL,
        CONSTRAINT [PK_AspNetRoleClaims] PRIMARY KEY ([Id]),
        CONSTRAINT [FK_AspNetRoleClaims_AspNetRoles_RoleId] FOREIGN KEY ([RoleId]) REFERENCES [IdentityIssuer].[AspNetRoles] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetUserClaims] (
        [Id] int NOT NULL IDENTITY,
        [UserId] nvarchar(450) NOT NULL,
        [ClaimType] nvarchar(max) NULL,
        [ClaimValue] nvarchar(max) NULL,
        CONSTRAINT [PK_AspNetUserClaims] PRIMARY KEY ([Id]),
        CONSTRAINT [FK_AspNetUserClaims_AspNetUsers_UserId] FOREIGN KEY ([UserId]) REFERENCES [IdentityIssuer].[AspNetUsers] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetUserLogins] (
        [LoginProvider] nvarchar(450) NOT NULL,
        [ProviderKey] nvarchar(450) NOT NULL,
        [ProviderDisplayName] nvarchar(max) NULL,
        [UserId] nvarchar(450) NOT NULL,
        CONSTRAINT [PK_AspNetUserLogins] PRIMARY KEY ([LoginProvider], [ProviderKey]),
        CONSTRAINT [FK_AspNetUserLogins_AspNetUsers_UserId] FOREIGN KEY ([UserId]) REFERENCES [IdentityIssuer].[AspNetUsers] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetUserRoles] (
        [UserId] nvarchar(450) NOT NULL,
        [RoleId] nvarchar(450) NOT NULL,
        CONSTRAINT [PK_AspNetUserRoles] PRIMARY KEY ([UserId], [RoleId]),
        CONSTRAINT [FK_AspNetUserRoles_AspNetRoles_RoleId] FOREIGN KEY ([RoleId]) REFERENCES [IdentityIssuer].[AspNetRoles] ([Id]) ON DELETE CASCADE,
        CONSTRAINT [FK_AspNetUserRoles_AspNetUsers_UserId] FOREIGN KEY ([UserId]) REFERENCES [IdentityIssuer].[AspNetUsers] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[AspNetUserTokens] (
        [UserId] nvarchar(450) NOT NULL,
        [LoginProvider] nvarchar(450) NOT NULL,
        [Name] nvarchar(450) NOT NULL,
        [Value] nvarchar(max) NULL,
        CONSTRAINT [PK_AspNetUserTokens] PRIMARY KEY ([UserId], [LoginProvider], [Name]),
        CONSTRAINT [FK_AspNetUserTokens_AspNetUsers_UserId] FOREIGN KEY ([UserId]) REFERENCES [IdentityIssuer].[AspNetUsers] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE INDEX [IX_AspNetRoleClaims_RoleId] ON [IdentityIssuer].[AspNetRoleClaims] ([RoleId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    EXEC(N'CREATE UNIQUE INDEX [RoleNameIndex] ON [IdentityIssuer].[AspNetRoles] ([NormalizedName]) WHERE [NormalizedName] IS NOT NULL');
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE INDEX [IX_AspNetUserClaims_UserId] ON [IdentityIssuer].[AspNetUserClaims] ([UserId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE INDEX [IX_AspNetUserLogins_UserId] ON [IdentityIssuer].[AspNetUserLogins] ([UserId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE INDEX [IX_AspNetUserRoles_RoleId] ON [IdentityIssuer].[AspNetUserRoles] ([RoleId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE INDEX [EmailIndex] ON [IdentityIssuer].[AspNetUsers] ([NormalizedEmail]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE UNIQUE INDEX [IX_AspNetUsers_ProfileId] ON [IdentityIssuer].[AspNetUsers] ([ProfileId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    CREATE UNIQUE INDEX [IX_AspNetUsers_WindowsSid] ON [IdentityIssuer].[AspNetUsers] ([WindowsSid]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    EXEC(N'CREATE UNIQUE INDEX [UserNameIndex] ON [IdentityIssuer].[AspNetUsers] ([NormalizedUserName]) WHERE [NormalizedUserName] IS NOT NULL');
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261001152500_IdentityIssuerInitialCreate'
)
BEGIN
    INSERT INTO [IdentityIssuer].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261001152500_IdentityIssuerInitialCreate', N'10.0.12');
END;

COMMIT;
GO

BEGIN TRANSACTION;
IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    ALTER TABLE [IdentityIssuer].[AspNetUsers] ADD [IsEnabled] bit NOT NULL DEFAULT CAST(1 AS bit);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[OpenIddictApplications] (
        [Id] nvarchar(450) NOT NULL,
        [ApplicationType] nvarchar(50) NULL,
        [ClientId] nvarchar(100) NULL,
        [ClientSecret] nvarchar(max) NULL,
        [ClientType] nvarchar(50) NULL,
        [ConcurrencyToken] nvarchar(50) NULL,
        [ConsentType] nvarchar(50) NULL,
        [DisplayName] nvarchar(max) NULL,
        [DisplayNames] nvarchar(max) NULL,
        [JsonWebKeySet] nvarchar(max) NULL,
        [Permissions] nvarchar(max) NULL,
        [PostLogoutRedirectUris] nvarchar(max) NULL,
        [Properties] nvarchar(max) NULL,
        [RedirectUris] nvarchar(max) NULL,
        [Requirements] nvarchar(max) NULL,
        [Settings] nvarchar(max) NULL,
        CONSTRAINT [PK_OpenIddictApplications] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[OpenIddictScopes] (
        [Id] nvarchar(450) NOT NULL,
        [ConcurrencyToken] nvarchar(50) NULL,
        [Description] nvarchar(max) NULL,
        [Descriptions] nvarchar(max) NULL,
        [DisplayName] nvarchar(max) NULL,
        [DisplayNames] nvarchar(max) NULL,
        [Name] nvarchar(200) NULL,
        [Properties] nvarchar(max) NULL,
        [Resources] nvarchar(max) NULL,
        CONSTRAINT [PK_OpenIddictScopes] PRIMARY KEY ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[RefreshTokens] (
        [Id] bigint NOT NULL IDENTITY,
        [UserId] nvarchar(450) NOT NULL,
        [WindowsSid] nvarchar(184) NOT NULL,
        [FamilyId] uniqueidentifier NOT NULL,
        [TokenHash] nvarchar(64) NOT NULL,
        [SecurityStamp] nvarchar(256) NULL,
        [CreatedAt] datetimeoffset NOT NULL,
        [ExpiresAt] datetimeoffset NOT NULL,
        [ConsumedAt] datetimeoffset NULL,
        [RevokedAt] datetimeoffset NULL,
        [Version] int NOT NULL,
        CONSTRAINT [PK_RefreshTokens] PRIMARY KEY ([Id]),
        CONSTRAINT [FK_RefreshTokens_AspNetUsers_UserId] FOREIGN KEY ([UserId]) REFERENCES [IdentityIssuer].[AspNetUsers] ([Id]) ON DELETE CASCADE
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[OpenIddictAuthorizations] (
        [Id] nvarchar(450) NOT NULL,
        [ApplicationId] nvarchar(450) NULL,
        [ConcurrencyToken] nvarchar(50) NULL,
        [CreationDate] datetime2 NULL,
        [Properties] nvarchar(max) NULL,
        [Scopes] nvarchar(max) NULL,
        [Status] nvarchar(50) NULL,
        [Subject] nvarchar(400) NULL,
        [Type] nvarchar(50) NULL,
        CONSTRAINT [PK_OpenIddictAuthorizations] PRIMARY KEY ([Id]),
        CONSTRAINT [FK_OpenIddictAuthorizations_OpenIddictApplications_ApplicationId] FOREIGN KEY ([ApplicationId]) REFERENCES [IdentityIssuer].[OpenIddictApplications] ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE TABLE [IdentityIssuer].[OpenIddictTokens] (
        [Id] nvarchar(450) NOT NULL,
        [ApplicationId] nvarchar(450) NULL,
        [AuthorizationId] nvarchar(450) NULL,
        [ConcurrencyToken] nvarchar(50) NULL,
        [CreationDate] datetime2 NULL,
        [ExpirationDate] datetime2 NULL,
        [Payload] nvarchar(max) NULL,
        [Properties] nvarchar(max) NULL,
        [RedemptionDate] datetime2 NULL,
        [ReferenceId] nvarchar(100) NULL,
        [Status] nvarchar(50) NULL,
        [Subject] nvarchar(400) NULL,
        [Type] nvarchar(150) NULL,
        CONSTRAINT [PK_OpenIddictTokens] PRIMARY KEY ([Id]),
        CONSTRAINT [FK_OpenIddictTokens_OpenIddictApplications_ApplicationId] FOREIGN KEY ([ApplicationId]) REFERENCES [IdentityIssuer].[OpenIddictApplications] ([Id]),
        CONSTRAINT [FK_OpenIddictTokens_OpenIddictAuthorizations_AuthorizationId] FOREIGN KEY ([AuthorizationId]) REFERENCES [IdentityIssuer].[OpenIddictAuthorizations] ([Id])
    );
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    EXEC(N'CREATE UNIQUE INDEX [IX_OpenIddictApplications_ClientId] ON [IdentityIssuer].[OpenIddictApplications] ([ClientId]) WHERE [ClientId] IS NOT NULL');
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE INDEX [IX_OpenIddictAuthorizations_ApplicationId_Status_Subject_Type] ON [IdentityIssuer].[OpenIddictAuthorizations] ([ApplicationId], [Status], [Subject], [Type]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    EXEC(N'CREATE UNIQUE INDEX [IX_OpenIddictScopes_Name] ON [IdentityIssuer].[OpenIddictScopes] ([Name]) WHERE [Name] IS NOT NULL');
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE INDEX [IX_OpenIddictTokens_ApplicationId_Status_Subject_Type] ON [IdentityIssuer].[OpenIddictTokens] ([ApplicationId], [Status], [Subject], [Type]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE INDEX [IX_OpenIddictTokens_AuthorizationId] ON [IdentityIssuer].[OpenIddictTokens] ([AuthorizationId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    EXEC(N'CREATE UNIQUE INDEX [IX_OpenIddictTokens_ReferenceId] ON [IdentityIssuer].[OpenIddictTokens] ([ReferenceId]) WHERE [ReferenceId] IS NOT NULL');
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE INDEX [IX_RefreshTokens_ExpiresAt] ON [IdentityIssuer].[RefreshTokens] ([ExpiresAt]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE UNIQUE INDEX [IX_RefreshTokens_TokenHash] ON [IdentityIssuer].[RefreshTokens] ([TokenHash]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    CREATE INDEX [IX_RefreshTokens_UserId_FamilyId] ON [IdentityIssuer].[RefreshTokens] ([UserId], [FamilyId]);
END;

IF NOT EXISTS (
    SELECT * FROM [IdentityIssuer].[__EFMigrationsHistory]
    WHERE [MigrationId] = N'20261002042057_AddOpenIddictAndRefreshTokens'
)
BEGIN
    INSERT INTO [IdentityIssuer].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261002042057_AddOpenIddictAndRefreshTokens', N'10.0.12');
END;

COMMIT;
GO

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

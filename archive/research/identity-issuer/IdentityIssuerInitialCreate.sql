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

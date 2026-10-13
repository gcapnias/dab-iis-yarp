# Upgrade Wiki.js v2.5.311 to current stable v2

Research date: 2026-10-13\
Target: existing Wiki.js v2.5.311 installation; Windows Server 2025 Standard/IIS is the deployment target from the surrounding research.\
Status: source and release review only. No package was downloaded, no server was changed, and no upgrade or restore was run.

## Version and artifact to target

The current stable v2 release is **v2.5.316**, published October 2, 2026 in the `requarks/wiki-v2` repository. The existing v2.5.311 release was published from the original `requarks/wiki` repository in January 2026. Pin the v2.5.316 Windows release artifact:

`https://github.com/requarks/wiki-v2/releases/download/v2.5.316/wiki-js-windows.tar.gz`

There is a consequential stale URL in the official Windows upgrade instructions: it downloads from `Requarks/wiki/releases/latest/download/wiki-js-windows.tar.gz`. On the research date the original repository's current release listings are for 3.0 beta, while stable v2.5.316 and its Windows asset are in `requarks/wiki-v2`. The legacy `/releases/latest` route does not select v2.5.316. Do not follow that moving legacy URL for a v2 maintenance upgrade; choose the explicit v2.5.316 asset. The main `requarks/wiki` branch is also identified as the 3.0 beta line, not the production stable v2 line. [v2 releases](https://github.com/requarks/wiki-v2/releases) [v2.5.316 Windows asset](https://github.com/requarks/wiki-v2/releases/download/v2.5.316/wiki-js-windows.tar.gz) [legacy repository releases](https://github.com/requarks/wiki/releases) [legacy latest route](https://github.com/Requarks/wiki/releases/latest) [v2.5.311 release](https://github.com/requarks/wiki/releases/tag/v2.5.311)

The v2 requirements page currently supports Node.js **22.0+ and 24.0+**, with support beginning in v2.5.302. Check the installed Node version before upgrading; if it is outside the published supported list, make the Node runtime change a separately planned step so any behavior change can be isolated. [v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md)

## What changed between v2.5.311 and v2.5.316

The official tag comparison contains 27 commits. Notable application changes include login-redirect cookie validation to prevent an open redirect, authentication of GraphQL subscription WebSocket connections, fixes to elevated-user assignment/permission checks, and OIDC/OAuth2 avatar-claim mapping. This is a reason to validate login, authorization, and WebSockets after the update, not only that the home page loads. [v2.5.311-to-v2.5.316 source comparison](https://github.com/requarks/wiki-v2/compare/v2.5.311...v2.5.316)

No changed files with migration-related names appear in that tag comparison. This is a source-diff observation, not proof that startup will never update the database schema. Wiki.js's upgrade instructions explicitly warn that once the database schema has been upgraded, an older Wiki.js version cannot simply be started against it. Treat the first v2.5.316 startup as potentially schema-changing and retain a complete pre-upgrade recovery point. [Upgrade instructions](https://github.com/requarks/wiki-docs-v2/blob/master/install/upgrade.md)

## Safe Windows upgrade sequence

The official Windows instructions describe an in-place procedure: stop Wiki.js, back up `config.yml`, replace the application files, restore `config.yml`, then start with `node server`. For a recoverable server operation, stage and verify the pinned archive before stopping the current launcher; retain the prior application directory until post-upgrade checks pass. Do not blindly clear the install directory until you have inventoried files that are configuration or persistent data rather than shipped application files. [Windows upgrade instructions](https://github.com/requarks/wiki-docs-v2/blob/master/install/upgrade.md) [Windows installation instructions](https://github.com/requarks/wiki-docs-v2/blob/master/install/windows.md)

Before the change, identify and back up this complete state as one recovery point:

- **Database:** take a consistent native backup using the procedure for the actual engine and server. The engine is not specified here, so no dump command is prescribed. PostgreSQL is Wiki.js's recommendation, but stable v2 also supports MySQL, MariaDB, SQL Server, and SQLite. If the installation uses SQLite, find the exact file from `config.yml` and use a consistent copy procedure while Wiki.js is stopped. The database contains Wiki.js content and application records; restoring only application files is not a full rollback. [v2 database requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md) [database configuration](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md)
- **`config.yml` and launch configuration:** securely preserve the active config, service-wrapper/launcher settings, environment variables, and any referenced TLS certificates or key files. Protect the backup because it may contain database credentials. Restore the original config to the new application directory as the official procedure requires.
- **Local persistence, if configured:** Wiki.js stores content in its database. Separately inspect Administration → Storage for a Local File System module or other filesystem-backed target, and preserve its configured directory and any content that has not been synchronized elsewhere. Also record configured `dataPath` and any sideloaded files. The installation's actual configured paths are authoritative; `./data/content` in documentation is an example, not a universal path. [Storage documentation](https://docs.requarks.io/storage) [configuration and data paths](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md) [sideloading](https://github.com/requarks/wiki-docs-v2/blob/master/install/sideload.md)
- **Custom extensions:** inventory locally added modules or other files in the application tree before replacing shipped files. Keep/reinstall only known custom content in a way compatible with v2.5.316; do not overlay the old application tree over the new package.

This installation is currently launched by Task Scheduler through a `.bat` file. Before scheduling maintenance, inspect the task action, working directory, batch contents, and resulting process tree. Disable the scheduled startup to prevent a concurrent launch, then verify and stop the actual Wiki.js Node process; ending a batch or task does not guarantee a detached child Node process has stopped. After placing the staged files and restoring configuration/persistence, re-enable or update the existing task and verify it launches the new `node server` from the intended directory. Do not change IIS/proxy topology during this upgrade; keep that as a separate maintenance step as requested. Watch startup logs for database checks/migrations and errors. Before declaring success, exercise normal pages, edit/save, media or local-storage access, Google/OIDC sign-in, authorization boundaries, and WebSocket-backed features.

## Rollback boundary and details still needed

If v2.5.316 startup has upgraded the database, **do not roll back by restoring only the v2.5.311 binaries**. Stop Wiki.js, restore the full pre-upgrade database backup together with the corresponding local-storage files, `config.yml`, and other referenced secrets/configuration, then restore the prior v2.5.311 application files. The version and data must match. This follows Wiki.js's explicit warning that a previous app version cannot be used after a database schema upgrade. A database dump/restore command should be chosen only after confirming the engine, version, host, and current backup tooling.

To turn this research into machine-specific commands, confirm the active install path and config location, actual database engine/version and whether it is local or remote, Wiki.js launcher/service wrapper, configured Storage module and filesystem paths, plus any external certs or secrets referenced by config/service settings. These facts cannot be inferred from the Wiki.js version or IIS choice.

## Sources

- [Wiki.js v2 releases](https://github.com/requarks/wiki-v2/releases)
- [Wiki.js v2.5.316 Windows release artifact](https://github.com/requarks/wiki-v2/releases/download/v2.5.316/wiki-js-windows.tar.gz)
- [Wiki.js original repository releases](https://github.com/requarks/wiki/releases)
- [Wiki.js v2.5.311 release](https://github.com/requarks/wiki/releases/tag/v2.5.311)
- [Wiki.js v2.5.311-to-v2.5.316 tag comparison](https://github.com/requarks/wiki-v2/compare/v2.5.311...v2.5.316)
- [Wiki.js v2 upgrade instructions](https://github.com/requarks/wiki-docs-v2/blob/master/install/upgrade.md)
- [Wiki.js v2 Windows installation instructions](https://github.com/requarks/wiki-docs-v2/blob/master/install/windows.md)
- [Wiki.js v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md)
- [Wiki.js v2 configuration reference](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md)
- [Wiki.js storage documentation](https://docs.requarks.io/storage)
- [Wiki.js v2 sideloading documentation](https://github.com/requarks/wiki-docs-v2/blob/master/install/sideload.md)

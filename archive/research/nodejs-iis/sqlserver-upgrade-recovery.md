# SQL Server backup and rollback preparation for Wiki.js upgrade

Research date: 2026-10-13\
Known target: Wiki.js v2.5.311 at `C:\wiki`, currently launched by a Windows Task Scheduler startup task that runs a batch file and listens natively on port 80. IIS is not installed yet. The later HPH target folder is `C:\inetpub\www-wikijs`. Wiki.js connects to SQL Server at `seesqldev3.dotsee.local`, TCP port `1519`. Database name, authentication method, SQL Server version/edition, and SQL-side backup directory are not yet known.\
Status: documentation and command-template research only. No credentials, configuration files, SQL instance, or server were accessed or changed.

## Connect to the SQL Server instance

In SSMS, select **Database Engine** and use this server name:

```text
tcp:seesqldev3.dotsee.local,1519
```

Microsoft's connection syntax is `[<protocol>:]<instance>[,<port>]`; a custom TCP port follows a comma. Select the approved authentication method and obtain the actual Wiki.js database name before running backup SQL. Do not infer the database name from the application name. [Connect to the SQL Server Database Engine](https://learn.microsoft.com/en-us/sql/sql-server/connect-to-database-engine?view=sql-server-ver17)

## Quiesce the foreground Wiki.js process

The confirmed batch sequence is:

```bat
cd \
cd wiki
node server
```

Because `node server` is the foreground command, the batch remains running with the Wiki.js Node process. Before maintenance, inspect the scheduled task's action, **Start in** directory, task settings, and process tree. Disable the startup task to prevent an additional instance during maintenance, then verify that the actual `node.exe` serving `C:\wiki` has stopped before taking the coordinated Wiki.js/filesystem recovery point. Do not assume that ending the scheduled task or `cmd.exe` stopped Node; check the child process and listener. Re-enable the task only after the upgrade/recovery operation is ready to launch.

`cd \` moves to the root of the current drive; it does not switch drives. `cd wiki` therefore reaches `C:\wiki` only if the task starts on drive C. Check the task's configured working directory and reproduce its exact action during the review. For a future explicit batch path, `cd /d C:\wiki` changes both drive and directory. Microsoft documents `/d` as changing the current drive as well as directory. Task Scheduler also has an `ExecutionTimeLimit` setting; verify it is appropriate for a long-running foreground Node process. [Microsoft `cd` command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cd) [Task Scheduler settings](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings)

The Wiki.js upgrade and the IIS/HTTP Platform Handler hosting change are separate maintenance steps by decision. First upgrade and verify Wiki.js in `C:\wiki` under the current Task Scheduler launch, still using its native port-80 listener; IIS is not part of this step. Later, stop that scheduled process before installing/cutting over to HPH in `C:\inetpub\www-wikijs`. Retaining the upgraded `C:\wiki` installation provides a hosting-cutover fallback only if it remains at the same Wiki.js version as the database; never run both copies concurrently against the same database. This folder fallback is distinct from a pre-upgrade database restore, which is required to return to v2.5.311 after schema changes.

## Create a one-off full database backup

After the database name and SQL-side backup folder are confirmed, a SQL Server administrator can run this template in SSMS. Replace both placeholders; the destination is a path on the **SQL Server host**, writable by the SQL Server service account, not a path on the Wiki.js server merely because SSMS runs there.

```sql
BACKUP DATABASE [<WikiDatabaseName>]
TO DISK = N'<SQLServerBackupDirectory>\Wiki_pre_v2.5.316_YYYYMMDD_HHMMSS.bak'
WITH COPY_ONLY, CHECKSUM, STATS = 5;
GO
```

`COPY_ONLY` makes this a full copy-only backup that does not change the normal differential base. `CHECKSUM` asks SQL Server to include backup checksums and validate page checksums when available. `COMPRESSION` is deliberately omitted until the SQL Server version/edition and configured policy are known. `BACKUP DATABASE` requires the appropriate database backup permission (commonly membership in `db_backupoperator`/`db_owner` or `sysadmin`), and the SQL Server service account must be able to write the destination. Do not grant broad privileges solely to run this operation; have the DBA perform it if needed. [Copy-only backups](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/copy-only-backups-sql-server?view=sql-server-ver17) [BACKUP (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql?view=sql-server-ver17) [backup checksum permissions](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/enable-or-disable-backup-checksums-during-backup-or-restore-sql-server?view=sql-server-ver17)

If the backup must be copied to the Wiki.js host or another repository, do that as a separate file transfer after SQL Server completes the backup. A UNC target is possible only when the SQL Server service identity has share and NTFS write access. Keep the backup restricted because it contains the Wiki.js database, including users, groups, settings, and any authentication-provider configuration stored there. If SQL Server encryption (for the database or backup) is enabled, arrange the required certificate/key backup as part of recovery readiness.

## Validate and prove the recovery point

First validate the backup set and checksum:

```sql
RESTORE VERIFYONLY
FROM DISK = N'<SQLServerBackupDirectory>\Wiki_pre_v2.5.316_YYYYMMDD_HHMMSS.bak'
WITH CHECKSUM;
GO
```

`RESTORE VERIFYONLY` checks that the backup set is readable and complete and checks the backup checksum, but **does not restore the database or verify the structure of the restored data**. It is a useful media check, not proof that Wiki.js can be recovered. `RESTORE VERIFYONLY` and file-list inspection can require `CREATE DATABASE` permission in modern SQL Server versions. [RESTORE VERIFYONLY](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver17) [RESTORE permissions and statements](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-for-restoring-recovering-and-managing-backups-transact-sql?view=sql-server-ver17)

For an actual restore test, use an approved isolated SQL Server target (or a new, clearly named test database on the same instance with DBA approval and sufficient free space). First inspect logical file names:

```sql
RESTORE FILELISTONLY
FROM DISK = N'<SQLServerBackupDirectory>\Wiki_pre_v2.5.316_YYYYMMDD_HHMMSS.bak';
GO
```

Then restore to a **new test database** and new, unique SQL data/log file paths, adding one `MOVE` for every logical data/log file returned above. Do not overwrite the production database or reuse its MDF/LDF paths.

```sql
RESTORE DATABASE [<WikiRestoreTestDatabase>]
FROM DISK = N'<SQLServerBackupDirectory>\Wiki_pre_v2.5.316_YYYYMMDD_HHMMSS.bak'
WITH MOVE N'<LogicalDataFileName>' TO N'<NewSQLDataPath>\WikiRestoreTest.mdf',
     MOVE N'<LogicalLogFileName>'  TO N'<NewSQLLogPath>\WikiRestoreTest_log.ldf',
     RECOVERY, CHECKSUM, STATS = 5;
GO

DBCC CHECKDB (N'<WikiRestoreTestDatabase>') WITH NO_INFOMSGS;
GO
```

Adjust file names/extensions for every row from `FILELISTONLY`; a database can contain more than one data file. `RESTORE` requires permission to create/restore the test database, and the SQL Server service account must be able to read the backup and write the destination database files. An actual isolated restore is the stronger proof that the database backup can be consumed. For application-level proof, use a separately copied Wiki.js install/config and local-storage content pointed only at the restored test database, and verify the old release can start against that pre-upgrade copy. Do not point a test instance at the live Wiki.js database.

Microsoft's `RESTORE` examples use `FILELISTONLY` to identify logical names and `MOVE` to relocate physical files during restore. [RESTORE (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-transact-sql?view=sql-server-ver17) [RESTORE arguments and `MOVE`](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-arguments-transact-sql?view=sql-server-ver17)

## Wiki.js rollback coupling

For the v2.5.311 → v2.5.316 upgrade, keep this SQL backup together with `C:\wiki\config.yml`, the scheduled task/batch configuration, and any configured local filesystem storage paths or external certificates/secrets. Wiki.js warns that once an upgrade changes the database schema, an older application binary cannot simply be started against that newer schema. A database rollback must restore the pre-upgrade SQL backup **and** the matching v2.5.311 application/config/files; restoring only the old application directory is insufficient. Conversely, a hosting-cutover fallback to retained `C:\wiki` can use the current database only when both copies are v2.5.316 and the copies are never run concurrently.

Still needed before making commands executable: Wiki.js database name; SQL Server version/edition and recovery/encryption settings; authentication method and account with backup/restore rights; approved SQL-host backup folder; and the Task Scheduler task's exact action, working directory, and execution-time limit. Do not put passwords in these notes or in command-line text.

## Sources

- [Connect to SQL Server Database Engine](https://learn.microsoft.com/en-us/sql/sql-server/connect-to-database-engine?view=sql-server-ver17)
- [BACKUP (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql?view=sql-server-ver17)
- [Copy-only backups](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/copy-only-backups-sql-server?view=sql-server-ver17)
- [Enable or disable backup checksums](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/enable-or-disable-backup-checksums-during-backup-or-restore-sql-server?view=sql-server-ver17)
- [RESTORE VERIFYONLY](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql?view=sql-server-ver17)
- [RESTORE (Transact-SQL)](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-transact-sql?view=sql-server-ver17)
- [RESTORE arguments and MOVE](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-arguments-transact-sql?view=sql-server-ver17)
- [RESTORE statement permissions](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-for-restoring-recovering-and-managing-backups-transact-sql?view=sql-server-ver17)
- [Windows `cd` command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cd)
- [Task Scheduler settings](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings)
- [Wiki.js v2 upgrade instructions](https://github.com/requarks/wiki-docs-v2/blob/master/install/upgrade.md)
- [Wiki.js v2 configuration reference](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md)

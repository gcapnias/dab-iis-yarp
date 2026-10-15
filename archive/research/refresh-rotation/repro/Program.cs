using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using IdentityIssuer;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;

return await Reproduction.RunAsync(args);

static class Reproduction
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private const string Prefix = "dab_ticket25_";
    private const string MarkerName = "Ticket25ReproductionOwner";
    private static readonly IdentityProfile Profile = new("synthetic-sid", "synthetic-subject", "synthetic-profile", null, ["reader"]) { SecurityStamp = "synthetic-stamp" };

    public static async Task<int> RunAsync(string[] args)
    {
        var report = new Dictionary<string, object?> { ["databaseExecutionPerformed"] = false };
        try
        {
            if (args.Length != 5 || args[0] is not ("--plan" or "--validate-plan" or "--execute") || args[1] != "--dotenv" || args[3] != "--plan-file")
                throw new InvalidOperationException("invalid_arguments");
            var source = LoadConnection(args[2]);
            var revision = ReadRevision();
            if (args[0] == "--plan")
            {
                if (File.Exists(args[4])) throw new InvalidOperationException("plan_already_exists");
                var plan = new FixturePlan(source.DataSource, source.InitialCatalog, Prefix + Guid.NewGuid().ToString("N")[..12], Guid.NewGuid().ToString("N"), revision,
                    AuthenticationMode(source),
                    source.Encrypt.ToString(), source.TrustServerCertificate, 3);
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(args[4]))!);
                await File.WriteAllTextAsync(args[4], JsonSerializer.Serialize(plan, JsonOptions));
                Print(new { mode = "plan_only", databaseConnectionsOpened = 0, plan });
                return 0;
            }
            var approved = JsonSerializer.Deserialize<FixturePlan>(await File.ReadAllTextAsync(args[4])) ?? throw new InvalidOperationException("invalid_plan");
            ValidatePlan(approved, source, revision);
            if (args[0] == "--validate-plan")
            {
                Print(new { mode = "validated_plan_only", databaseConnectionsOpened = 0, plan = approved });
                return 0;
            }
            report["databaseExecutionPerformed"] = true;
            return await ExecuteAsync(approved, source, report);
        }
        catch (Exception error)
        {
            report["failure"] = "plan_or_execution_failed";
            report["exception"] = Describe(error);
            Print(report);
            return 2;
        }
    }

    private static SqlConnectionStringBuilder LoadConnection(string file)
    {
        // Match the existing issuer launcher's exact ConnectionString entry; never echo its value.
        var entries = File.ReadLines(file).Where(line => Regex.IsMatch(line, @"^\s*ConnectionString\s*=")).ToArray();
        if (entries.Length != 1) throw new InvalidOperationException("expected_one_connection_entry");
        var value = entries[0][(entries[0].IndexOf('=') + 1)..].Trim();
        if (value.Length >= 2 && value[0] == value[^1] && value[0] is '\'' or '"') value = value[1..^1];
        var parsed = new SqlConnectionStringBuilder(value);
        if (string.IsNullOrWhiteSpace(parsed.DataSource) || string.IsNullOrWhiteSpace(parsed.InitialCatalog)) throw new InvalidOperationException("missing_server_or_catalog");
        if (parsed.AttachDBFilename.Length > 0 || parsed.UserInstance || parsed.FailoverPartner.Length > 0) throw new InvalidOperationException("unsupported_connection_topology");
        return parsed;
    }

    private static string ReadRevision()
    {
        var start = new ProcessStartInfo("git") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("rev-parse"); start.ArgumentList.Add("HEAD");
        using var process = Process.Start(start) ?? throw new InvalidOperationException("revision_unavailable");
        var value = process.StandardOutput.ReadToEnd().Trim();
        process.WaitForExit();
        if (process.ExitCode != 0 || !Regex.IsMatch(value, "^[0-9a-f]{40}$")) throw new InvalidOperationException("revision_unavailable");
        return value;
    }

    private static void ValidatePlan(FixturePlan plan, SqlConnectionStringBuilder source, string revision)
    {
        if (!Regex.IsMatch(plan.Database, "^dab_ticket25_[0-9a-f]{12}$") || !Regex.IsMatch(plan.OwnerMarker, "^[0-9a-f]{32}$") || plan.Iterations != 3)
            throw new InvalidOperationException("invalid_fixture_identity");
        if (!string.Equals(plan.Server, source.DataSource, StringComparison.Ordinal) || !string.Equals(plan.SourceCatalog, source.InitialCatalog, StringComparison.Ordinal) ||
            !string.Equals(plan.SourceRevision, revision, StringComparison.Ordinal) || plan.Encrypt != source.Encrypt.ToString() || plan.TrustServerCertificate != source.TrustServerCertificate || plan.Authentication != AuthenticationMode(source))
            throw new InvalidOperationException("plan_target_or_revision_changed");
        if (string.Equals(plan.Database, source.InitialCatalog, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("source_catalog_forbidden");
    }

    private static string AuthenticationMode(SqlConnectionStringBuilder source) => source.IntegratedSecurity ? "Windows integrated" : source.Authentication == SqlAuthenticationMethod.NotSpecified ? "SQL login" : source.Authentication.ToString();

    private static string Connection(SqlConnectionStringBuilder source, string catalog) => new SqlConnectionStringBuilder(source.ConnectionString)
    {
        InitialCatalog = catalog, Pooling = false, ConnectTimeout = 15, ApplicationName = "Ticket25SyntheticReproduction", Enlist = false
    }.ConnectionString;

    private static async Task<int> ExecuteAsync(FixturePlan plan, SqlConnectionStringBuilder source, Dictionary<string, object?> report)
    {
        var created = false;
        var creationAttempted = false;
        int? databaseId = null;
        DateTime? createDate = null;
        var markerApplied = false;
        var exitCode = 2;
        await using var master = new SqlConnection(Connection(source, "master"));
        report["server"] = plan.Server;
        report["fixtureDatabase"] = plan.Database;
        report["sourceRevision"] = plan.SourceRevision;
        try
        {
            await master.OpenAsync();
            await using (var create = new SqlCommand($"IF DB_ID(@name) IS NOT NULL THROW 51000, 'fixture_name_collision', 1; CREATE DATABASE [{plan.Database}];", master) { CommandTimeout = 60 })
            {
                create.Parameters.AddWithValue("@name", plan.Database);
                creationAttempted = true;
                await create.ExecuteNonQueryAsync();
                created = true;
            }
            await using (var identity = new SqlCommand("SELECT database_id, create_date FROM sys.databases WHERE name=@name", master))
            {
                identity.Parameters.AddWithValue("@name", plan.Database);
                await using var reader = await identity.ExecuteReaderAsync();
                if (!await reader.ReadAsync()) throw new InvalidOperationException("new_fixture_identity_unavailable");
                databaseId = reader.GetInt32(0); createDate = reader.GetDateTime(1);
            }
            var fixtureConnection = Connection(source, plan.Database);
            await using (var fixture = new SqlConnection(fixtureConnection))
            {
                await fixture.OpenAsync();
                await using var marker = new SqlCommand("EXEC sys.sp_addextendedproperty @name=@markerName, @value=@markerValue", fixture);
                marker.Parameters.AddWithValue("@markerName", MarkerName); marker.Parameters.AddWithValue("@markerValue", plan.OwnerMarker);
                await marker.ExecuteNonQueryAsync(); markerApplied = true;
                await using var metadata = new SqlCommand("SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)), compatibility_level, is_read_committed_snapshot_on, snapshot_isolation_state_desc FROM sys.databases WHERE database_id=DB_ID()", fixture);
                await using var reader = await metadata.ExecuteReaderAsync();
                await reader.ReadAsync();
                report["sqlConfiguration"] = new { productVersion = reader.GetString(0), compatibilityLevel = reader.GetByte(1), readCommittedSnapshot = reader.GetBoolean(2), snapshotIsolation = reader.GetString(3), serviceIsolation = "Serializable", retriesEnabled = false };
            }
            await using (var seed = Context(fixtureConnection))
            {
                // Only the newly created empty fixture receives the current real EF schema.
                await seed.Database.EnsureCreatedAsync();
                seed.Users.Add(new ApplicationUser { Id = Profile.Subject, WindowsSid = Profile.WindowsSid, ProfileId = Profile.ProfileId, SecurityStamp = Profile.SecurityStamp, UserName = "synthetic-ticket25", NormalizedUserName = "SYNTHETIC-TICKET25" });
                await seed.SaveChangesAsync();
            }
            report["sequentialControl"] = await SequentialAsync(fixtureConnection);
            var races = new List<RaceObservation>();
            for (var index = 0; index < plan.Iterations; index++) races.Add(await RaceAsync(fixtureConnection, index + 1));
            report["races"] = races;
            var allReached = races.All(race => race.BarrierArrivals == 2 && !race.Inconclusive);
            var violated = races.Any(race => !race.ContractSatisfied);
            report["verdict"] = !allReached ? "inconclusive_synchronization_or_execution" : violated ? "service_rotation_contract_violated" : "service_rotation_contract_satisfied_in_tested_races";
            report["httpResponseObserved"] = false;
            exitCode = !allReached ? 2 : violated ? 1 : 0;
        }
        catch (Exception error)
        {
            report["failure"] = "fixture_or_reproduction_failed";
            report["exception"] = Describe(error);
        }
        finally
        {
            if (created)
            {
                try
                {
                    if (databaseId is null || createDate is null || !markerApplied) throw new InvalidOperationException("cleanup_identity_not_proven");
                    if (master.State != System.Data.ConnectionState.Open) await master.OpenAsync();
                    await using (var verify = new SqlCommand($"SELECT COUNT(*) FROM sys.databases WHERE name=@name AND database_id=@id AND create_date=@created AND EXISTS (SELECT 1 FROM [{plan.Database}].sys.extended_properties WHERE class=0 AND name=@markerName AND CONVERT(nvarchar(32),value)=@markerValue)", master))
                    {
                        verify.Parameters.AddWithValue("@name", plan.Database); verify.Parameters.AddWithValue("@id", databaseId.Value);
                        verify.Parameters.AddWithValue("@created", createDate.Value); verify.Parameters.AddWithValue("@markerName", MarkerName); verify.Parameters.AddWithValue("@markerValue", plan.OwnerMarker);
                        if (Convert.ToInt32(await verify.ExecuteScalarAsync()) != 1) throw new InvalidOperationException("cleanup_identity_mismatch");
                    }
                    await using var drop = new SqlCommand($"ALTER DATABASE [{plan.Database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{plan.Database}];", master) { CommandTimeout = 30 };
                    await drop.ExecuteNonQueryAsync();
                    report["fixtureCleanup"] = "dropped_verified_new_fixture";
                }
                catch (Exception cleanupError)
                {
                    report["fixtureCleanup"] = "failed_or_unsafe_fixture_retained";
                    report["cleanupException"] = Describe(cleanupError);
                    exitCode = 2;
                }
            }
            else report["fixtureCleanup"] = creationAttempted ? "creation_not_confirmed_no_cleanup_attempted" : "no_creation_attempted";
        }
        Print(report);
        return exitCode;
    }

    private static ApplicationDbContext Context(string connection, SaveChangesInterceptor? interceptor = null)
    {
        var options = new DbContextOptionsBuilder<ApplicationDbContext>().UseSqlServer(connection, sql => sql.CommandTimeout(30));
        if (interceptor is not null) options.AddInterceptors(interceptor);
        return new ApplicationDbContext(options.Options);
    }

    private static async Task<(string Token, Guid Family)> SeedFamilyAsync(string connection)
    {
        await using var context = Context(connection);
        var token = await new RefreshTokenService(context, TimeSpan.FromDays(7)).CreateAsync(Profile, DateTimeOffset.UtcNow, CancellationToken.None);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
        var family = await context.RefreshTokens.Where(row => row.TokenHash == hash).Select(row => row.FamilyId).SingleAsync();
        return (token, family);
    }

    private static async Task<object> SequentialAsync(string connection)
    {
        var seed = await SeedFamilyAsync(connection);
        await using var first = Context(connection);
        await using var second = Context(connection);
        var rotation = await new RefreshTokenService(first, TimeSpan.FromDays(7)).RotateAsync(seed.Token, Profile, DateTimeOffset.UtcNow, CancellationToken.None);
        var replay = await new RefreshTokenService(second, TimeSpan.FromDays(7)).RotateAsync(seed.Token, Profile, DateTimeOffset.UtcNow, CancellationToken.None);
        var state = await FamilyStateAsync(connection, seed.Family);
        if (rotation.Status != RefreshTokenRotationStatus.Rotated || replay.Status != RefreshTokenRotationStatus.ReplayDetected || state.Unrevoked != 0 || state.Total != 2)
            throw new InvalidOperationException("sequential_control_failed");
        return new { rotation = rotation.Status.ToString(), replay = replay.Status.ToString(), state };
    }

    private static async Task<RaceObservation> RaceAsync(string connection, int iteration)
    {
        var seed = await SeedFamilyAsync(connection);
        var barrier = new RotationBarrier();
        await using var first = Context(connection, barrier);
        await using var second = Context(connection, barrier);
        // Explicitly opened, independent connections also allow recording distinct SQL session IDs.
        await first.Database.OpenConnectionAsync(); await second.Database.OpenConnectionAsync();
        var firstSession = await SessionAsync(first); var secondSession = await SessionAsync(second);
        if (firstSession == secondSession) throw new InvalidOperationException("sessions_not_independent");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(50));
        var outcomes = await Task.WhenAll(ActorAsync(first, seed.Token, deadline.Token), ActorAsync(second, seed.Token, deadline.Token));
        // Dispose both transactions/connections before observer reads or fixture teardown.
        await first.DisposeAsync(); await second.DisposeAsync();
        var state = await FamilyStateAsync(connection, seed.Family);
        var inconclusive = barrier.Arrivals != 2 || outcomes.Any(actor => actor.CanceledOrTimedOut);
        var satisfied = outcomes.Count(actor => actor.Status == "Rotated") == 1 && outcomes.Count(actor => actor.Status == "ReplayDetected") == 1 && outcomes.All(actor => actor.Exception is null) && state.Total == 2 && state.Unrevoked == 0;
        return new(iteration, firstSession, secondSession, barrier.Arrivals, outcomes, state, inconclusive, satisfied);
    }

    private static async Task<int> SessionAsync(ApplicationDbContext context)
    {
        await using var command = context.Database.GetDbConnection().CreateCommand(); command.CommandText = "SELECT @@SPID";
        return Convert.ToInt32(await command.ExecuteScalarAsync());
    }

    private static async Task<ActorObservation> ActorAsync(ApplicationDbContext context, string token, CancellationToken cancellation)
    {
        try
        {
            var result = await new RefreshTokenService(context, TimeSpan.FromDays(7)).RotateAsync(token, Profile, DateTimeOffset.UtcNow, cancellation);
            return new(result.Status.ToString(), null, false);
        }
        catch (Exception error)
        {
            return new(null, Describe(error), error is OperationCanceledException or TimeoutException || FindSqlNumbers(error).Contains(-2));
        }
    }

    private static async Task<FamilyState> FamilyStateAsync(string connection, Guid family)
    {
        await using var context = Context(connection);
        var rows = await context.RefreshTokens.AsNoTracking().Where(row => row.FamilyId == family).ToListAsync();
        return new(rows.Count, rows.Count(row => row.ConsumedAt is not null), rows.Count(row => row.RevokedAt is not null), rows.Count(row => row.RevokedAt is null), rows.Count(row => row.ConsumedAt is null && row.RevokedAt is null));
    }

    private static object Describe(Exception error)
    {
        var types = new List<string>();
        for (Exception? current = error; current is not null; current = current.InnerException) types.Add(current.GetType().Name);
        return new { types, sqlErrorNumbers = FindSqlNumbers(error).Distinct().ToArray() };
    }

    private static IEnumerable<int> FindSqlNumbers(Exception error)
    {
        for (Exception? current = error; current is not null; current = current.InnerException)
            if (current is SqlException sql) foreach (SqlError entry in sql.Errors) yield return entry.Number;
    }

    private static void Print(object value) => Console.WriteLine(JsonSerializer.Serialize(value, JsonOptions));
}

sealed class RotationBarrier : SaveChangesInterceptor
{
    private readonly TaskCompletionSource release = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly HashSet<Guid> contexts = [];
    public int Arrivals { get { lock (contexts) return contexts.Count; } }

    public override async ValueTask<InterceptionResult<int>> SavingChangesAsync(DbContextEventData eventData, InterceptionResult<int> result, CancellationToken cancellationToken = default)
    {
        var context = eventData.Context ?? throw new InvalidOperationException("barrier_context_missing");
        lock (contexts)
        {
            // Recovery/revocation saves by this service call must keep their real behavior.
            if (contexts.Contains(context.ContextId.InstanceId)) return result;
        }
        if (!context.ChangeTracker.Entries<RefreshTokenRecord>().Any(entry => entry.State == EntityState.Modified && entry.Entity.ConsumedAt is not null) ||
            !context.ChangeTracker.Entries<RefreshTokenRecord>().Any(entry => entry.State == EntityState.Added)) return result;
        lock (contexts)
        {
            contexts.Add(context.ContextId.InstanceId);
            if (contexts.Count == 2) release.TrySetResult();
        }
        await release.Task.WaitAsync(TimeSpan.FromSeconds(20), cancellationToken);
        return result;
    }
}

sealed record FixturePlan(string Server, string SourceCatalog, string Database, string OwnerMarker, string SourceRevision, string Authentication, string Encrypt, bool TrustServerCertificate, int Iterations);
sealed record ActorObservation(string? Status, object? Exception, bool CanceledOrTimedOut);
sealed record FamilyState(int Total, int Consumed, int Revoked, int Unrevoked, int UnrevokedReplacements);
sealed record RaceObservation(int Iteration, int FirstSqlSession, int SecondSqlSession, int BarrierArrivals, ActorObservation[] Actors, FamilyState FinalFamilyState, bool Inconclusive, bool ContractSatisfied);

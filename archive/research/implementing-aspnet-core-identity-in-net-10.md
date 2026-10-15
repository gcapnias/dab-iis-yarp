# Implementing ASP.NET Core Identity in .NET 10

> How to implement identity framework in .NET 10?

To implement ASP.NET Core Identity in .NET 10, you can configure it easily using the built-in [Identity API Endpoints](https://learn.microsoft.com/aspnet/core/security/authentication/identity?view=aspnetcore-10.0). This method eliminates the need for bulky Razor Pages scaffolding and exposes direct, ready-made JSON endpoints for authentication. [1, 2, 3]
Additionally, .NET 10 introduces built-in support for passkeys (WebAuthn) directly into the Identity infrastructure. [4]

## Step 1: Install the Required Packages

Open your project terminal and install the essential Entity Framework Core and Identity packages: [3, 5]

```PowerShell
dotnet add package Microsoft.AspNetCore.Identity.EntityFrameworkCore
dotnet add package Microsoft.EntityFrameworkCore.SqlServer
dotnet add package Microsoft.EntityFrameworkCore.Tools
```

Note: Swap SqlServer for alternative providers like Npgsql.EntityFrameworkCore.PostgreSQL or Sqlite based on your database choice). [6, 7]

## Step 2: Set Up Models and Database Context

* Custom User Model: Extend `IdentityUser` to include custom application properties.
* Database Context: Create a context class that inherits from `IdentityDbContext<TUser>` rather than the standard `DbContext`. [5, 6, 8]

## Step 3: Configure Services and Endpoints in Program.cs

In your Program.cs, configure your database connection, register authorization services, call `.AddIdentityApiEndpoints<ApplicationUser>()` with Entity Framework stores, optionally set up .NET 10 passkey options, map the identity REST endpoints via `app.MapIdentityApi<ApplicationUser>()`, and secure your routes. [2, 4]

## Step 4: Run Database Migrations

Execute the Entity Framework CLI commands to generate and apply migrations for the underlying identity tables (AspNetUsers, AspNetRoles, etc.): [3, 6]

```PowerShell
dotnet ef migrations add InitialIdentitySetup
dotnet ef database update
```

## Summary of What You Get

Using `app.MapIdentityApi<TUser>()` automatically provisions built-in JSON endpoints including /register, /login, /refresh, and user management routes. [3]

[1] [https://learn.microsoft.com](https://learn.microsoft.com/aspnet/core/security/authentication/identity?view=aspnetcore-10.0)
[2] [https://codewithmukesh.com](https://codewithmukesh.com/blog/identity-endpoints-aspnet-core/)
[3] [https://medium.com](https://medium.com/@remigiuszzalewski/authentication-using-asp-net-core-identity-net-10-167fd5c5159f)
[4] [https://auth0.com](https://auth0.com/blog/authentication-authorization-enhancements-dotnet-10/)
[5] [https://medium.com](https://medium.com/codetodeploy/authentication-made-easy-with-asp-net-core-identity-in-net-10-e14163b9669e)
[6] [https://www.youtube.com](https://www.youtube.com/watch?v=5WCUZ8NX8Do&t=955)
[7] [https://www.youtube.com](https://www.youtube.com/watch?v=g9YSB4bXhes&vl=en)
[8] [https://medium.com](https://medium.com/startup-insider-edge/authentication-made-easy-with-asp-net-core-identity-in-net-10-d934fb9b344f)

---

> I need to implement both. Can I have guidance on both?

To implement JWT Bearer authentication and role/policy-based authorization alongside the built-in ASP.NET Core Identity infrastructure in .NET 10, it is vital to know that `app.MapIdentityApi<TUser>()` generates proprietary, opaque tokens intended solely for the issuing application—not standard JWTs. [1, 2]
To issue standard JSON Web Tokens (JWT) containing custom roles and claims, the recommended industry strategy is an "escape hatch" approach: preserve the native Identity Framework store for core user management (such as user models, password hashing, and role persistence), while overriding the default login mechanism with a dedicated custom JWT service. [1, 2, 3]

## Part 1: Setting up JWT & Roles in Program.cs

First, install the authentication library via your project terminal: [3, 4]

```PowerShell
dotnet add package Microsoft.AspNetCore.Authentication.JwtBearer
```

Update your Program.cs to set up JWT validation, register the default Core Identity core store services, incorporate role support (.AddRoles()), and establish your customized security policy infrastructure: [5, 6]

```csharp
using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

// 1. Establish Database Context
builder.Services.AddDbContext<ApplicationDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("DefaultConnection")));

// 2. Setup Core Identity with Role Infrastructure
builder.Services.AddIdentityCore(options => {
    options.Password.RequiredLength = 8;
})
.AddRoles() // Activates internal role storage
.AddEntityFrameworkStores<ApplicationDbContext>()
.AddDefaultTokenProviders();

// 3. Register JWT Bearer Authentication Middleware
var jwtSettings = builder.Configuration.GetSection("JwtSettings");
var secretKey = Encoding.UTF8.GetBytes(jwtSettings["Key"]!);

builder.Services.AddAuthentication(options => {
    options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options => {
    // Keeps claim keys precisely formatted instead of mapping to XML schemas
    options.MapInboundClaims = false; 
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidateAudience = true,
        ValidateLifetime = true,
        ValidateIssuerSigningKey = true,
        ValidIssuer = jwtSettings["Issuer"],
        ValidAudience = jwtSettings["Audience"],
        IssuerSigningKey = new SymmetricSecurityKey(secretKey)
    };
});

// 4. Configure Policy-Based Authorization
builder.Services.AddAuthorization(options =>
 {
     // Simple Role Checking
     options.AddPolicy("RequireAdminRole", policy => policy.RequireRole("Admin"));
     
     // Complex Claim/Policy Combinations
     options.AddPolicy("ElevatedManagerOnly", policy => 
         policy.RequireRole("Manager")
               .RequireClaim("ClearanceLevel", "Level3"));
 });

var app = builder.Build();

app.UseAuthentication(); // Evaluates incoming tokens
app.UseAuthorization();  // Verifies evaluated claims against defined policies
```

Add your credentials profile to appsettings.json: [7]

```json
{
  "JwtSettings": {
    "Key": "YourSuperSecretLongSecurityKeyHere123!",
    "Issuer": "https://yourdomain.com",
    "Audience": "https://yourdomain.com"
  }
}
```

## Part 2: Creating a Custom JWT Engine

Leverage the faster, highly memory-efficient JsonWebTokenHandler introduced to modern ASP.NET Core pipelines: [4, 8]

```csharp
using System.Security.Claims;
using System.Text;
using Microsoft.AspNetCore.Identity;
using Microsoft.IdentityModel.JsonWebTokens; // Preferred handler for .NET 10
using Microsoft.IdentityModel.Tokens;

public class TokenService
{
    private readonly IConfiguration _config;
    private readonly UserManager _userManager;

    public TokenService(IConfiguration config, UserManager userManager)
    {
        _config = config;
        _userManager = userManager;
    }

    public async Task<string> GenerateJwtTokenAsync(IdentityUser user)
    {
        var jwtSettings = _config.GetSection("JwtSettings");
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtSettings["Key"]!));
        var creds = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        // Standard user identity payload tokens
        var claims = new List<Claim>
        {
            new Claim(JwtRegisteredClaimNames.Sub, user.Id),
            new Claim(JwtRegisteredClaimNames.Email, user.Email!),
            new Claim(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString())
        };

        // Pull stored assigned internal system roles out to insert as JWT claim arrays
        var roles = await _userManager.GetRolesAsync(user);
        foreach (var role in roles)
        {
            claims.Add(new Claim(ClaimTypes.Role, role));
        }

        var tokenDescriptor = new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity(claims),
            Expires = DateTime.UtcNow.AddHours(2),
            Issuer = jwtSettings["Issuer"],
            Audience = jwtSettings["Audience"],
            SigningCredentials = creds
        };

        var handler = new JsonWebTokenHandler(); // High performance token parsing
        return handler.CreateToken(tokenDescriptor);
    }
}
```

## Part 3: Exposing the Custom Login API Endpoint

Implement an alternative lightweight endpoint capturing standard JSON credentials to handle token responses:

```csharp
app.MapPost("/api/auth/login", async (
    LoginModel model, 
    UserManager userManager, 
    TokenService tokenService) =>
{
    var user = await userManager.FindByEmailAsync(model.Email);
    if (user == null || !await userManager.CheckPasswordAsync(user, model.Password))
    {
        return Results.Unauthorized();
    }

    var token = await tokenService.GenerateJwtTokenAsync(user);
    return Results.Ok(new { AccessToken = token });
});
public record LoginModel(string Email, string Password);
```

## Part 4: Securing Enforced Endpoints via Policies

Protect routes by referencing policies or explicit role requirements: [4, 5]

```csharp
// Simple Role Guarding
app.MapGet("/api/admin/dashboard", () => Results.Ok("Welcome Admin!"))
   .RequireAuthorization(new AuthorizeAttribute { Roles = "Admin" });

// Flexible Policy Guarding (Recommended)
app.MapGet("/api/manager/reports", () => Results.Ok("Sensitive Management Data Access"))
   .RequireAuthorization("ElevatedManagerOnly"); // References custom policy
```

[1] [https://codewithmukesh.com](https://codewithmukesh.com/blog/identity-endpoints-aspnet-core/)
[2] [https://daily.dev](https://daily.dev/posts/identity-api-endpoints-in-asp-net-core-when-to-use-them-net-10--ipinr7bfu)
[3] [https://www.youtube.com](https://www.youtube.com/watch?v=W9wwZFxtBdM&t=36)
[4] [https://codewithmukesh.com](https://codewithmukesh.com/blog/jwt-authentication-in-aspnet-core/)
[5] [https://www.pluralsight.com](https://www.pluralsight.com/labs/codeLabs/guided-implementing-jwt-authorization-in-aspnet-core-10)
[6] [https://medium.com](https://medium.com/startup-insider-edge/authentication-made-easy-with-asp-net-core-identity-in-net-10-4f1504857c99)
[7] [https://www.youtube.com](https://www.youtube.com/watch?v=UVuE7KZ0fLs&t=478)
[8] [https://medium.com](https://medium.com/startup-insider-edge/token-authentication-in-asp-net-core-9-10-with-jwt-clean-architecture-f0956cff924d)

---

Would you like to build an automated data seeder script that creates standard default roles (Admin, User) and provisions an initial Admin account upon startup, or do you need assistance implementing refresh token workflows?

> I need both

Here is the implementation guide for both an automated database seeder (to create default roles and an initial Admin account) and a robust refresh token workflow integrated with your .NET 10 JWT architecture.

## Part 1: Automated Role and Admin Seeder

To ensure your application always has its foundational security roles upon startup, create an asynchronous initialization method. This approach safely handles concurrent setups during containerization or cloud deployments.
Create a static helper class to encapsulate the initialization logic:

```csharp
using Microsoft.AspNetCore.Identity;
public static class IdentityDataSeeder
{
    public static async Task SeedRolesAndAdminAsync(IServiceProvider serviceProvider)
    {
        using var scope = serviceProvider.CreateScope();
        var roleManager = scope.ServiceProvider.GetRequiredService();
        var userManager = scope.ServiceProvider.GetRequiredService();

        // 1. Define and Provision Core Roles
        string[] roles = ["Admin", "Manager", "User"];
        foreach (var role in roles)
        {
            if (!await roleManager.RoleExistsAsync(role))
            {
                await roleManager.CreateAsync(new IdentityRole(role));
            }
        }

        // 2. Provision Default Administrator Account
        const string adminEmail = "admin@yourdomain.com";
        var adminUser = await userManager.FindByEmailAsync(adminEmail);

        if (adminUser == null)
        {
            adminUser = new IdentityUser
            {
                UserName = adminEmail,
                Email = adminEmail,
                EmailConfirmed = true
            };

            // Specify a strong, production-ready password profile
            var result = await userManager.CreateAsync(adminUser, "SuperSecureAdminPassword123!");
            
            if (result.Succeeded)
            {
                // Link user to administrative permissions context
                await userManager.AddToRoleAsync(adminUser, "Admin");
            }
        }
    }
}
```

Invoke the seeder in `Program.cs` right before `app.Run()`:

```csharp
var app = builder.Build();

// Apply middleware pipelines...
app.UseAuthentication();
app.UseAuthorization();

// Seed identity store data safely at startup
await IdentityDataSeeder.SeedRolesAndAdminAsync(app.Services);

app.Run();
```

## Part 2: Refresh Token Workflow Implementation

Refresh tokens should be long-lived, high-entropy random strings stored securely in the database and delivered to the client via secure, HttpOnly cookies to mitigate Cross-Site Scripting (XSS) vulnerabilities.

### 1. Extend the Identity Database Context

```csharp
Create a custom entity model to track active refresh tokens in the database.

public class UserRefreshToken
{
    public int Id { get; set; }
    public required string UserId { get; set; }
    public required string Token { get; set; }
    public DateTime ExpiresAt { get; set; }
    public bool IsRevoked { get; set; }
    public bool IsUsed { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    
    public bool IsExpired => DateTime.UtcNow >= ExpiresAt;
    public bool IsActive => !IsRevoked && !IsUsed && !IsExpired;
}
```

Add this configuration directly to your `ApplicationDbContext`:

```csharp
using Microsoft.AspNetCore.Identity.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

public class ApplicationDbContext : IdentityDbContext
{
    public ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : base(options) { }

    public DbSet<UserRefreshToken> UserRefreshTokens { get; set; }
}
```

Run your migration commands to update your SQL schema:

```PowerShell
dotnet ef migrations add AddRefreshTokensTable
dotnet ef database update
```

### 2. Update TokenService to Generate and Validate Refresh Tokens

Expand your `TokenService` class to handle both JWT generation and cryptographic refresh token tracking.

```csharp
using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.JsonWebTokens;

public class TokenService
{
    private readonly IConfiguration _config;
    private readonly UserManager _userManager;
    private readonly ApplicationDbContext _context;

    public TokenService(IConfiguration config, UserManager userManager, ApplicationDbContext context)
    {
        _config = config;
        _userManager = userManager;
        _context = context;
    }

    // (Keep the previous GenerateJwtTokenAsync method here...)

    public async Task<string> GenerateAndSaveRefreshTokenAsync(string userId)
    {
        // Generate a cryptographically secure random string
        var randomNumber = new byte[64];
        using var rng = RandomNumberGenerator.Create();
        rng.GetBytes(randomNumber);
        var refreshTokenString = Convert.ToBase64String(randomNumber);

        var refreshToken = new UserRefreshToken
        {
            UserId = userId,
            Token = refreshTokenString,
            ExpiresAt = DateTime.UtcNow.AddDays(7) // Long-lived window
        };

        _context.UserRefreshTokens.Add(refreshToken);
        await _context.SaveChangesAsync();

        return refreshTokenString;
    }

    public async Task<UserRefreshToken?> ValidateRefreshTokenAsync(string userId, string token)
    {
        return await _context.UserRefreshTokens
            .FirstOrDefaultAsync(t => t.UserId == userId && t.Token == token && t.IsActive);
    }
}
```

### 3. Update the Authentication Endpoints

Modify your /api/auth/login endpoint to securely append the refresh token to the response headers using an HTTP-Only cookie, and add a /api/auth/refresh endpoint to handle token rotation requests.

```csharp
using System.Security.Claims;
using Microsoft.AspNetCore.Identity;
using Microsoft.IdentityModel.JsonWebTokens;

// Helper to set the secure cookie environment profilevoid SetRefreshTokenCookie(HttpContext context, string token)
{
    var cookieOptions = new CookieOptions
    {
        HttpOnly = true,
        Secure = true, // Enforce HTTPS processing pipelines
        SameSite = SameSiteMode.Strict,
        Expires = DateTime.UtcNow.AddDays(7)
    };
    context.Response.Cookies.Append("refreshToken", token, cookieOptions);
}

// 1. Updated Login Endpoint
app.MapPost("/api/auth/login", async (
    LoginModel model, 
    UserManager userManager, 
    TokenService tokenService,
    HttpContext context) =>
{
    var user = await userManager.FindByEmailAsync(model.Email);
    if (user == null || !await userManager.CheckPasswordAsync(user, model.Password))
    {
        return Results.Unauthorized();
    }

    var accessToken = await tokenService.GenerateJwtTokenAsync(user);
    var refreshToken = await tokenService.GenerateAndSaveRefreshTokenAsync(user.Id);

    SetRefreshTokenCookie(context, refreshToken);

    return Results.Ok(new { AccessToken = accessToken });
});

// 2. Token Rotation (Refresh) Endpoint
app.MapPost("/api/auth/refresh", async (
    RefreshRequestModel model,
    TokenService tokenService,
    UserManager userManager,
    ApplicationDbContext dbContext,
    HttpContext context) =>
{
    // Retrieve the token from the HttpOnly cookie
    if (!context.Request.Cookies.TryGetValue("refreshToken", out var refreshTokenString))
    {
        return Results.BadRequest("Refresh token is required.");
    }

    var storedToken = await tokenService.ValidateRefreshTokenAsync(model.UserId, refreshTokenString);
    if (storedToken == null)
    {
        return Results.Unauthorized();
    }

    // Invalidate the old refresh token (Token Rotation pattern for reuse detection)
    storedToken.IsUsed = true;
    
    var user = await userManager.FindByIdAsync(model.UserId);
    if (user == null) return Results.Unauthorized();

    // Generate a fresh pair of tokens
    var newAccessToken = await tokenService.GenerateJwtTokenAsync(user);
    var newRefreshToken = await tokenService.GenerateAndSaveRefreshTokenAsync(user.Id);

    SetRefreshTokenCookie(context, newRefreshToken);
    await dbContext.SaveChangesAsync();

    return Results.Ok(new { AccessToken = newAccessToken });
});

public record RefreshRequestModel(string UserId);
```

---

Would you like assistance implementing a Token Reuse Detection system to automatically invalidate all of a user's active sessions if a compromised refresh token is reused, or should we set up a automated background worker (IHostedService) to clean up expired tokens from your database?

> Yes please

Here is the comprehensive implementation guide for both Token Reuse Detection (a critical security pattern to detect and mitigate token theft) and an Automated Background Worker (IHostedService) to prevent database bloat by cleaning up expired tokens.

## Part 1: Token Reuse Detection (Replay Attack Mitigation)

If a malicious actor steals a refresh token cookie, they might attempt to use it to get a new access token. If the legitimate user also attempts to use that same token, a reuse condition triggers.
The security best practice is to revoke the entire family of tokens associated with that user immediately, forcing a complete re-authentication across all their devices.
Update the `/api/auth/refresh` endpoint logic to include reuse checking:

```csharp
app.MapPost("/api/auth/refresh", async (
    RefreshRequestModel model,
    TokenService tokenService,
    UserManager userManager,
    ApplicationDbContext dbContext,
    HttpContext context) =>
{
    if (!context.Request.Cookies.TryGetValue("refreshToken", out var refreshTokenString))
    {
        return Results.BadRequest("Refresh token is required.");
    }

    // 1. Fetch the token regardless of whether it has been used or not
    var tokenRecord = await dbContext.UserRefreshTokens
        .FirstOrDefaultAsync(t => t.UserId == model.UserId && t.Token == refreshTokenString);

    if (tokenRecord == null)
    {
        return Results.Unauthorized();
    }

    // 2. REUSE DETECTION TRIGGERED
    if (tokenRecord.IsUsed)
    {
        // Breach condition: Revoke EVERY active token for this user immediately
        var activeTokens = await dbContext.UserRefreshTokens
            .Where(t => t.UserId == model.UserId && !t.IsRevoked && !t.IsUsed)
            .ToListAsync();

        foreach (var token in activeTokens)
        {
            token.IsRevoked = true;
        }

        await dbContext.SaveChangesAsync();
        
        // Clear the bad cookie from the malicious/compromised client
        context.Response.Cookies.Delete("refreshToken");
        
        return Results.Json(new { error = "Security breach detected. All sessions revoked." }, statusCode: 401);
    }

    // 3. Expiration Check
    if (tokenRecord.IsExpired || tokenRecord.IsRevoked)
    {
        return Results.Unauthorized();
    }

    // 4. Legitimate Request processing: Invalidate the token now being used
    tokenRecord.IsUsed = true;
    
    var user = await userManager.FindByIdAsync(model.UserId);
    if (user == null) return Results.Unauthorized();

    // Generate fresh replacements
    var newAccessToken = await tokenService.GenerateJwtTokenAsync(user);
    var newRefreshToken = await tokenService.GenerateAndSaveRefreshTokenAsync(user.Id);

    SetRefreshTokenCookie(context, newRefreshToken);
    await dbContext.SaveChangesAsync();

    return Results.Ok(new { AccessToken = newAccessToken });
});
```

## Part 2: Automated Background Worker (IHostedService)

Over time, your database will accumulate thousands of expired, used, or revoked refresh tokens. A background worker inheriting from BackgroundService runs continuously in the background to purge these safely.

Create a new file named `TokenCleanupBackgroundWorker.cs`:

```csharp
using Microsoft.EntityFrameworkCore;

public class TokenCleanupBackgroundWorker : BackgroundService
{
    private readonly IServiceProvider _services;
    private readonly ILogger<TokenCleanupBackgroundWorker> _logger;

    // Run the cleanup execution sweep once every 24 hours
    private readonly TimeSpan _period = TimeSpan.FromHours(24); 

    public TokenCleanupBackgroundWorker(IServiceProvider services, ILogger<TokenCleanupBackgroundWorker> logger)
    {
        _services = services;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Token Cleanup Background Worker is starting.");

        using var timer = new PeriodicTimer(_period);

        while (!stoppingToken.IsCancellationRequested && await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                _logger.LogInformation("Token Cleanup Worker executing sweep...");

                using var scope = _services.CreateScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<ApplicationDbContext>();

                // Target records that are expired, explicitly marked as used, or revoked
                var cutoffTime = DateTime.UtcNow;
                var deadTokens = await dbContext.UserRefreshTokens
                    .Where(t => t.ExpiresAt <= cutoffTime || t.IsUsed || t.IsRevoked)
                    .ToListAsync(stoppingToken);

                if (deadTokens.Count > 0)
                {
                    dbContext.UserRefreshTokens.RemoveRange(deadTokens);
                    await dbContext.SaveChangesAsync(stoppingToken);
                    _logger.LogInformation("Successfully purged {Count} dead refresh tokens from the database.", deadTokens.Count);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "An error occurred while deleting expired tokens.");
            }
        }
        
        _logger.LogInformation("Token Cleanup Background Worker is stopping.");
    }
}
```

Register the worker in your Program.cs before it compiles:

```csharp
var builder = WebApplication.CreateBuilder(args);

// ... Previous database, identity, and token service configurations

// Register the automated cleanup background worker service
builder.Services.AddHostedService<TokenCleanupBackgroundWorker>();
var app = builder.Build();
```

## Summary of System Defenses

   1. HttpOnly Cookies: Shields your Refresh Tokens from browser-based XSS attacks.
   2. Token Rotation: Every access token refresh invalidates the prior refresh token.
   3. Breach Blast Radius Containment: The moment an old token is resubmitted, the system assumes theft has occurred, kills all tokens for that identity, and stops the breach.
   4. Automated Maintenance: Your database remains lean automatically via the daily BackgroundService execution thread.

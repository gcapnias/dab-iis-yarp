# Windows Authentication in .NET Identity

> I am a .NET 10/C# developer. I want to implement an authentication/authorization mechanism for my application based on .NET's identity framework. The autherization part I want to use windows authentication. If my application uses windows authorization, what information about the logged in account will be availiable to be, in order to build be authorization system out of AD, in a database with Identity framework?

When using Windows Authentication in a .NET 10 application, the framework maps the logged-in Active Directory (AD) or local Windows account to a ClaimsPrincipal. [1]
To build a custom database-backed authorization system using ASP.NET Core Identity, your primary key for linking the AD user to your database will be their unique identifier (SID) or domain username.
Here is the exact information available from the WindowsIdentity that you can extract and use to seed or look up your Identity database: [2]

## 1. Unique Identifiers (For Mapping to Database Users)

* ClaimTypes.PrimarySid (Security Identifier): The most critical piece of information. The SID is a globally unique, immutable string identifier for the AD object (e.g., S-1-5-21-...). Always use the SID as your lookup key or foreign key in your custom AspNetUsers table because it will never change, even if the user changes their name or marries.
* ClaimTypes.Name (Domain Username): Typically provided in the format DOMAIN\samaccountname (e.g., COMPANY\jdoe). You can map this to the NormalizedUserName field in ASP.NET Core Identity.

## 2. User Context & Profile Data

* ClaimTypes.WindowsUserClaim: Signifies that the user identity originated from a valid Windows domain account or local account.
* WindowsIdentity.Name Property: Returns the DOMAIN\username string directly.
* WindowsIdentity.AuthenticationType: Will return Negotiate, NTLM, or Kerberos, allowing you to confirm the exact protocol used. [3, 4]

## 3. Native Active Directory Groups (Optional)

* ClaimTypes.GroupSid: The ClaimsPrincipal will automatically contain a collection of SIDs representing every AD security group the user belongs to.
* Note on Groups: You can translate these group SIDs to human-readable names (e.g., Domain Users) using group.Translate(typeof(NTAccount)). However, because you want a database-driven authorization system, you will likely ignore these native AD group claims and query your database instead. [2, 5]

## How to Bridge Windows Auth and ASP.NET Core Identity

Because you are using Windows Authentication for authentication and ASP.NET Core Identity for authorization, you need to intercept the login, grab the user's SID, and map it to a user record in your database. [1, 2]
The industry-standard way to implement this in .NET 10 is by using an IClaimsTransformation. [5]

## Step 1: Add a WindowsSid column to your Identity User

```csharp
public class ApplicationUser : IdentityUser
{
    // Store the immutable AD SID here
    public string WindowsSid { get; set; }
}
```

## Step 2: Implement the Claims Transformer

Every time a user makes a request, this service intercepts the Windows identity, pulls their database-defined roles/claims, and attaches them dynamically to the current request user. [1, 2]

```csharp
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Identity;
using System.Security.Claims;

public class DbAuthorizationClaimsTransformer : IClaimsTransformation
{
    private readonly UserManager<ApplicationUser> _userManager;

    public DbAuthorizationClaimsTransformer(UserManager<ApplicationUser> userManager)
    {
        _userManager = userManager;
    }

    public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        // 1. Verify the identity is a Windows Identity
        var windowsIdentity = principal.Identity as WindowsIdentity;
        if (windowsIdentity == null) return principal;

        // 2. Extract the Unique SID
        var userSid = windowsIdentity.User?.Value; 
        if (string.IsNullOrEmpty(userSid)) return principal;

        // 3. Find the user in your Identity DB using the SID
        // (Alternatively, use windowsIdentity.Name if mapping via username)
        var user = await _userManager.Users
            .FirstOrDefaultAsync(u => u.WindowsSid == userSid);

        if (user != null)
        {
            var clone = principal.Clone();
            var newIdentity = clone.Identity as ClaimsIdentity;

            // 4. Fetch roles from AspNetUserRoles and append them as claims
            var roles = await _userManager.GetRolesAsync(user);
            foreach (var role in roles)
            {
                newIdentity.AddClaim(new Claim(ClaimTypes.Role, role));
            }
            
            // Append any custom application claims stored in AspNetUserClaims
            var customClaims = await _userManager.GetClaimsAsync(user);
            newIdentity.AddClaims(customClaims);

            return clone;
        }

        // Return unchanged if user isn't provisioned in the authorization database
        return principal;
    }
}
```

## Step 3: Register Services in Program.cs

Ensure you register both the Windows Authentication schemes and your custom transformer: [3]

```csharp
builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme)
    .AddNegotiate(); // Enables Windows Auth

builder.Services.AddTransient<IClaimsTransformation, DbAuthorizationClaimsTransformer>();
builder.Services.AddAuthorization();
```

[1] [https://www.youtube.com](https://www.youtube.com/watch?v=0VJcu10b2pQ)
[2] [https://forums.servicestack.net](https://forums.servicestack.net/t/use-asp-net-core-identity-only-for-authorization/12330)
[3] [https://learn.microsoft.com](https://learn.microsoft.com/aspnet/core/security/authentication/windowsauth?view=aspnetcore-10.0)
[4] [https://learn.microsoft.com](https://learn.microsoft.com/aspnet/mvc/overview/older-versions-1/security/authenticating-users-with-windows-authentication-cs)
[5] [https://www.seeleycoder.com](https://www.seeleycoder.com/blog/expanding-windows-authentication-net-core/)

---

Would you like assistance in auto-provisioning (creating) the user record in the database the very first time they hit the application via Windows Authentication, or do you intend to pre-seed the database manually?

> Yes, please

To handle user auto-provisioning, you can modify your `IClaimsTransformation` implementation. If a user successfully authenticates via Windows Authentication but cannot be found in your database, you can dynamically create their ApplicationUser record on their very first request.
Because `IClaimsTransformation` runs on every request, it is critical to keep this logic performance-optimized and thread-safe.
Here is how you can implement auto-provisioning cleanly in .NET 10:

## 1. Update the Claims Transformer

We need to inject a IServiceProvider rather than injecting UserManager directly. This prevents scope-lifetime issues because IClaimsTransformation can sometimes be called multiple times per request cycle depending on your middleware pipeline.

```csharp
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using System.Security.Claims;
using System.Security.Principal;

public class DbAuthorizationClaimsTransformer : IClaimsTransformation
{
    private readonly IServiceProvider _serviceProvider;
    // Simple concurrent cache to avoid querying the DB on every single request 
    // for users we already verified during this server instance's lifecycle.
    private static readonly HashSet<string> _provisionedUserCache = new();

    public DbAuthorizationClaimsTransformer(IServiceProvider serviceProvider)
    {
        _serviceProvider = serviceProvider;
    }

    public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        // 1. Verify the identity is a valid Windows Identity
        if (principal.Identity is not WindowsIdentity windowsIdentity || !windowsIdentity.IsAuthenticated)
        {
            return principal;
        }

        var userSid = windowsIdentity.User?.Value;
        if (string.IsNullOrEmpty(userSid)) return principal;

        // Create a scoped provider to resolve EF Core dependencies safely
        using var scope = _serviceProvider.CreateScope();
        var userManager = scope.ServiceProvider.GetRequiredService<UserManager<ApplicationUser>>();

        ApplicationUser? user = null;

        // 2. Optimization: Check local cache first before querying database
        if (!_provisionedUserCache.Contains(userSid))
        {
            user = await userManager.Users.FirstOrDefaultAsync(u => u.WindowsSid == userSid);

            // 3. Auto-Provisioning: If the user doesn't exist, create them
            if (user == null)
            {
                user = await ProvisionNewUserAsync(userManager, windowsIdentity, userSid);
            }
            else
            {
                _provisionedUserCache.Add(userSid);
            }
        }
        else
        {
            // User exists in memory cache, grab them from the database to read roles
            user = await userManager.Users.FirstOrDefaultAsync(u => u.WindowsSid == userSid);
        }

        if (user != null)
        {
            var clone = principal.Clone();
            if (clone.Identity is ClaimsIdentity identity)
            {
                // 4. Inject DB-driven Roles into the Claims Principal
                var roles = await userManager.GetRolesAsync(user);
                foreach (var role in roles)
                {
                    identity.AddClaim(new Claim(ClaimTypes.Role, role));
                }

                // Inject DB-driven Custom Claims
                var customClaims = await userManager.GetClaimsAsync(user);
                identity.AddClaims(customClaims);
            }
            return clone;
        }

        return principal;
    }

    private async Task<ApplicationUser?> ProvisionNewUserAsync(
        UserManager<ApplicationUser> userManager, 
        WindowsIdentity windowsIdentity, 
        string userSid)
    {
        // Extract domain username (e.g., "COMPANY\jdoe")
        string domainUsername = windowsIdentity.Name; 
        
        // Clean up email or nickname if desired (Windows accounts don't implicitly expose email here)
        string shortName = domainUsername.Contains('\\') ? domainUsername.Split('\\')[1] : domainUsername;

        var newUser = new ApplicationUser
        {
            UserName = domainUsername,
            NormalizedUserName = domainUsername.ToUpperInvariant(),
            WindowsSid = userSid,
            Email = $"{shortName}@yourcompany.local", // Placeholder email mapping
            EmailConfirmed = true
        };

        // Pass a dummy or empty password since they authenticate seamlessly via Kerberos/NTLM
        var result = await userManager.CreateAsync(newUser);
        
        if (result.Succeeded)
        {
            // Assign a default authorization role to all new domain users (optional)
            await userManager.AddToRoleAsync(newUser, "StandardUser");
            
            _provisionedUserCache.Add(userSid);
            return newUser;
        }

        // Log fallback behavior if DB creation fails (e.g., database constraint issues)
        return null;
    }
}
```

## Crucial Architectural Design Decisions to Consider

* Handling the Domain Name Change: If an IT administrator changes a user's SamAccountName in Active Directory, windowsIdentity.Name will change, but their WindowsSid stays identical. Because our system fetches by WindowsSid, the app will seamlessly find them, update their profile, and keep their authorization roles intact.
* The First-Time User Experience: By defaulting them to a low-privilege group like "StandardUser" upon provisioning, you establish a secure "Closed-Door" policy. Admin users can then navigate to an administration panel in your app to upgrade their role permissions.
* Thread Safety and Race Conditions: If a new user opens 3 different browser tabs simultaneously on their very first visit, 3 parallel requests will try to provision the exact same user. Ensure you have a Unique Index constraint set on your WindowsSid column in SQL Server. If a race condition occurs, EF Core will throw a unique constraint error on the duplicate requests, which is safely handled by your app returning the principal unmodified until the next clean page refresh.

---

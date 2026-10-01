using Microsoft.AspNetCore.Identity;

namespace IdentityIssuer;

public sealed class ApplicationUser : IdentityUser
{
    public required string WindowsSid { get; set; }
    public required string ProfileId { get; set; }
    public string? DisplayName { get; set; }
}
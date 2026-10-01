using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using IdentityIssuer;

namespace IdentityIssuer.Tests;

public sealed class JwtIssuerTests
{
    [Fact]
    public void CreateToken_signs_the_mapped_subject_roles_audience_and_expiry()
    {
        using var key = RSA.Create(2048);
        var settings = new IssuerSettings("https://issuer.example.test", "api://catalog", "test-key", TimeSpan.FromMinutes(10), "dab_access_token", null);
        var issuer = new JwtIssuer(key, settings);
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var profile = new IdentityProfile("S-1-5-21-10-20-30-1001", "user-7", "profile-7", "Example User", ["reader", "editor", "reader"]);

        var token = issuer.CreateToken(profile, now);
        var parts = token.Split('.');
        Assert.Equal(3, parts.Length);

        var header = JsonDocument.Parse(Decode(parts[0]));
        var claims = JsonDocument.Parse(Decode(parts[1]));
        Assert.Equal("RS256", header.RootElement.GetProperty("alg").GetString());
        Assert.Equal("at+jwt", header.RootElement.GetProperty("typ").GetString());
        Assert.Equal("test-key", header.RootElement.GetProperty("kid").GetString());
        Assert.Equal(settings.Issuer, claims.RootElement.GetProperty("iss").GetString());
        Assert.Equal(settings.Audience, claims.RootElement.GetProperty("aud").GetString());
        Assert.Equal("user-7", claims.RootElement.GetProperty("sub").GetString());
        Assert.Equal("profile-7", claims.RootElement.GetProperty("profile_id").GetString());
        Assert.Equal("Example User", claims.RootElement.GetProperty("name").GetString());
        Assert.Equal(now.AddMinutes(10).ToUnixTimeSeconds(), claims.RootElement.GetProperty("exp").GetInt64());
        Assert.Equal(new[] { "reader", "editor" }, claims.RootElement.GetProperty("roles").EnumerateArray().Select(role => role.GetString() ?? string.Empty).ToArray());

        var signature = Decode(parts[2]);
        var signingInput = Encoding.ASCII.GetBytes($"{parts[0]}.{parts[1]}");
        var publishedKey = Assert.Single(issuer.CreatePublicKeySet().Keys);
        using var verifier = RSA.Create();
        verifier.ImportParameters(new RSAParameters { Modulus = Decode(publishedKey.N), Exponent = Decode(publishedKey.E) });
        Assert.True(verifier.VerifyData(signingInput, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
    }

    [Fact]
    public void CreateToken_refuses_profiles_without_roles()
    {
        using var key = RSA.Create(2048);
        var issuer = new JwtIssuer(key, new IssuerSettings("https://issuer.example.test", "api://catalog", "test-key", TimeSpan.FromMinutes(5), "dab_access_token", null));

        Assert.Throws<InvalidOperationException>(() => issuer.CreateToken(new IdentityProfile("sid", "subject", "profile-1", null, []), DateTimeOffset.UtcNow));
    }

    [Fact]
    public void CreatePublicKeySet_publishes_only_the_public_verification_parameters()
    {
        using var key = RSA.Create(2048);
        var issuer = new JwtIssuer(key, new IssuerSettings("https://issuer.example.test", "api://catalog", "test-key", TimeSpan.FromMinutes(5), "dab_access_token", null));

        var jwks = issuer.CreatePublicKeySet();

        var jwk = Assert.Single(jwks.Keys);
        Assert.Equal("RSA", jwk.Kty);
        Assert.Equal("test-key", jwk.Kid);
        var json = JsonSerializer.Serialize(jwks, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        Assert.Contains("\"n\"", json, StringComparison.Ordinal);
        Assert.Contains("\"e\"", json, StringComparison.Ordinal);
        Assert.DoesNotContain("\"d\"", json, StringComparison.Ordinal);
    }

    private static byte[] Decode(string value)
    {
        var base64 = value.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(base64.PadRight(base64.Length + ((4 - base64.Length % 4) % 4), '='));
    }
}

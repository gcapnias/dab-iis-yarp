using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace IdentityIssuer;

public sealed record IssuerSettings(string Issuer, string Audience, string KeyId, TimeSpan Lifetime, string CookieName, string? CookieDomain);

public sealed class JwtIssuer(RSA signingKey, IssuerSettings settings)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public string CreateToken(IdentityProfile profile, DateTimeOffset now)
    {
        if (string.IsNullOrWhiteSpace(profile.Subject) || string.IsNullOrWhiteSpace(profile.ProfileId))
        {
            throw new InvalidOperationException("A mapped identity must have a stable subject and ProfileId.");
        }

        if (profile.Roles.Count == 0 || profile.Roles.Any(string.IsNullOrWhiteSpace))
        {
            throw new InvalidOperationException("A mapped identity must have at least one named role.");
        }

        var header = new Dictionary<string, object>
        {
            ["alg"] = "RS256",
            ["typ"] = "at+jwt",
            ["kid"] = settings.KeyId
        };
        var claims = new Dictionary<string, object>
        {
            ["iss"] = settings.Issuer,
            ["aud"] = settings.Audience,
            ["sub"] = profile.Subject,
            ["iat"] = now.ToUnixTimeSeconds(),
            ["nbf"] = now.ToUnixTimeSeconds(),
            ["exp"] = now.Add(settings.Lifetime).ToUnixTimeSeconds(),
            ["roles"] = profile.Roles.Distinct(StringComparer.Ordinal).ToArray()
        };
        claims["profile_id"] = profile.ProfileId;
        if (!string.IsNullOrWhiteSpace(profile.DisplayName))
            claims["name"] = profile.DisplayName;

        // Profile-derived authorization claims remain deliberately omitted until the real
        // schema and policy mapping are established. The stable subject comes from the mapped row.
        var unsigned = $"{Encode(JsonSerializer.SerializeToUtf8Bytes(header, JsonOptions))}.{Encode(JsonSerializer.SerializeToUtf8Bytes(claims, JsonOptions))}";
        var signature = signingKey.SignData(Encoding.ASCII.GetBytes(unsigned), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return $"{unsigned}.{Encode(signature)}";
    }

    public JsonWebKeySetDocument CreatePublicKeySet()
    {
        var parameters = signingKey.ExportParameters(includePrivateParameters: false);
        return new JsonWebKeySetDocument(
            [new JsonWebKeyDocument("RSA", settings.KeyId, "sig", "RS256", Encode(parameters.Modulus!), Encode(parameters.Exponent!))]);
    }

    private static string Encode(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

public sealed record JsonWebKeySetDocument(IReadOnlyList<JsonWebKeyDocument> Keys);
public sealed record JsonWebKeyDocument(string Kty, string Kid, string Use, string Alg, string N, string E);
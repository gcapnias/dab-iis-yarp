using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;

namespace IdentityIssuer;

public sealed record IssuerSettings(string Issuer, string Audience, string KeyId, TimeSpan Lifetime, string CookieName, string? CookieDomain);
public sealed record PreviousSigningKeyOptions(string KeyId, string PrivateKeyPath);

public sealed class JwtIssuer
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly RSA signingKey;
    private readonly IssuerSettings settings;
    private readonly IReadOnlyList<RsaSecurityKey> verificationKeys;

    public JwtIssuer(RSA signingKey, IssuerSettings settings)
        : this(signingKey, settings, [])
    {
    }

    public JwtIssuer(RSA signingKey, IssuerSettings settings, IReadOnlyList<RsaSecurityKey> previousSigningKeys)
    {
        this.signingKey = signingKey;
        this.settings = settings;
        if (previousSigningKeys.Any(key => string.IsNullOrWhiteSpace(key.KeyId) || key.KeyId == settings.KeyId))
        {
            throw new ArgumentException("Previous signing keys must have unique, non-empty key IDs.", nameof(previousSigningKeys));
        }
        verificationKeys = previousSigningKeys;
    }

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
        foreach (var claim in profile.Claims)
        {
            claims[claim.Key] = claim.Value;
        }
        var unsigned = $"{Encode(JsonSerializer.SerializeToUtf8Bytes(header, JsonOptions))}.{Encode(JsonSerializer.SerializeToUtf8Bytes(claims, JsonOptions))}";
        var signature = signingKey.SignData(Encoding.ASCII.GetBytes(unsigned), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return $"{unsigned}.{Encode(signature)}";
    }

    public JsonWebKeySetDocument CreatePublicKeySet()
    {
        var parameters = signingKey.ExportParameters(includePrivateParameters: false);
        return new JsonWebKeySetDocument(
            [new JsonWebKeyDocument("RSA", settings.KeyId, "sig", "RS256", Encode(parameters.Modulus!), Encode(parameters.Exponent!)),
                .. verificationKeys.Select(key =>
                {
                    var previous = key.Rsa!.ExportParameters(includePrivateParameters: false);
                    return new JsonWebKeyDocument("RSA", key.KeyId!, "sig", "RS256", Encode(previous.Modulus!), Encode(previous.Exponent!));
                })]);
    }

    private static string Encode(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

public sealed record JsonWebKeySetDocument(IReadOnlyList<JsonWebKeyDocument> Keys);
public sealed record JsonWebKeyDocument(string Kty, string Kid, string Use, string Alg, string N, string E);

using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Azure.DataApiBuilder.Core.AuthenticationHelpers;
using Microsoft.AspNetCore.Authentication.JwtBearer;

namespace EmbeddedDab;

/// <summary>Opt-in trust for one local development issuer certificate, without changing OS trust.</summary>
public static class DevelopmentIssuerCertificate
{
    public const string ConfigurationKey = "DAB_DEVELOPMENT_ISSUER_CERTIFICATE_SHA256";

    public static void Configure(WebApplicationBuilder builder)
    {
        string? fingerprint = builder.Configuration[ConfigurationKey];
        if (string.IsNullOrWhiteSpace(fingerprint)) return;
        if (!builder.Environment.IsDevelopment())
            throw new InvalidOperationException("Issuer certificate pinning is permitted only in Development.");
        if (fingerprint.Length != 64 || fingerprint.Any(character => !Uri.IsHexDigit(character)))
            throw new InvalidOperationException("The issuer certificate SHA-256 pin must contain exactly 64 hexadecimal characters.");

        foreach (string scheme in new[] { GenericOAuthDefaults.AUTHENTICATIONSCHEME, JwtBearerDefaults.AuthenticationScheme })
        {
            builder.Services.Configure<JwtBearerOptions>(scheme, options =>
            {
                if (!Uri.TryCreate(options.Authority, UriKind.Absolute, out Uri? issuer)
                    || issuer.Scheme != "https" || issuer.Host != "localhost" || !string.IsNullOrEmpty(issuer.UserInfo))
                    throw new InvalidOperationException("Development issuer certificate pinning requires an HTTPS localhost authority.");
                options.BackchannelHttpHandler = new HttpClientHandler
                {
                    ServerCertificateCustomValidationCallback = (request, certificate, _, errors) =>
                        Accepts(issuer, request.RequestUri, certificate, errors, fingerprint)
                };
            });
        }
    }

    public static bool Accepts(Uri issuer, Uri? target, X509Certificate2? certificate, SslPolicyErrors errors, string fingerprint)
    {
        if (target is null || certificate is null || issuer.Scheme != "https" || issuer.Host != "localhost"
            || target.Scheme != issuer.Scheme || target.Authority != issuer.Authority
            || (errors != SslPolicyErrors.None && errors != SslPolicyErrors.RemoteCertificateChainErrors)) return false;
        DateTime now = DateTime.UtcNow;
        if (now < certificate.NotBefore.ToUniversalTime() || now > certificate.NotAfter.ToUniversalTime()) return false;
        bool serverAuthentication = certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>()
            .Any(extension => extension.EnhancedKeyUsages.Cast<Oid>().Any(oid => oid.Value == "1.3.6.1.5.5.7.3.1"));
        return serverAuthentication && string.Equals(certificate.GetCertHashString(HashAlgorithmName.SHA256), fingerprint, StringComparison.OrdinalIgnoreCase);
    }
}

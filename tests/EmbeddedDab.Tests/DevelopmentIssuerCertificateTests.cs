using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.Builder;

namespace EmbeddedDab.Tests;

public sealed class DevelopmentIssuerCertificateTests
{
    [Fact]
    public void PinAllowsOnlyMatchingCurrentServerCertificateOnExactLocalIssuerOrigin()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(10));
        string pin = certificate.GetCertHashString(HashAlgorithmName.SHA256);
        var issuer = new Uri("https://localhost:5001");
        var target = new Uri("https://localhost:5001/.well-known/jwks");
        Assert.True(DevelopmentIssuerCertificate.Accepts(issuer, target, certificate, SslPolicyErrors.RemoteCertificateChainErrors, pin));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, target, certificate, SslPolicyErrors.RemoteCertificateNameMismatch, pin));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, target, certificate, SslPolicyErrors.None, new string('0', 64)));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, new Uri("https://localhost:5002/jwks"), certificate, SslPolicyErrors.None, pin));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, new Uri("https://remote.test/jwks"), certificate, SslPolicyErrors.None, pin));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, new Uri("http://localhost:5001/jwks"), certificate, SslPolicyErrors.None, pin));
        using var expired = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-2), DateTimeOffset.UtcNow.AddDays(-1));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, target, expired, SslPolicyErrors.RemoteCertificateChainErrors, expired.GetCertHashString(HashAlgorithmName.SHA256)));
        var clientRequest = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        clientRequest.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.2") }, false));
        using var clientCertificate = clientRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(10));
        Assert.False(DevelopmentIssuerCertificate.Accepts(issuer, target, clientCertificate, SslPolicyErrors.RemoteCertificateChainErrors, clientCertificate.GetCertHashString(HashAlgorithmName.SHA256)));
    }

    [Fact]
    public void PinConfigurationIsRejectedOutsideDevelopment()
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = "Production" });
        builder.Configuration[DevelopmentIssuerCertificate.ConfigurationKey] = new string('0', 64);
        Assert.Throws<InvalidOperationException>(() => DevelopmentIssuerCertificate.Configure(builder));
    }
}

# Cloudflare Tunnel to IIS over HTTPS

Research date: 2026-10-13

## Scope and known target

The stated public address is `https://docs.dot-see.dev/`; the existing Cloudflare Tunnel currently forwards to Wiki.js over local HTTP on port 80. The intended origin is IIS over HTTPS at `seedocs.dotsee.local` (no hyphen). Reuse the existing certificate only if its Subject Alternative Name includes `seedocs.dotsee.local`; this has not been verified. The public name and origin name are intentionally different. The connector's host and whether this tunnel is locally or remotely managed have not been established. This note describes a candidate configuration, not a tested deployment; no Cloudflare, IIS, or server settings were changed.

Cloudflare treats the public hostname and the tunnel Service URL as separate values. The Service URL must identify an origin reachable from the `cloudflared` process; pointing it at the public hostname can loop back through the Tunnel. Cloudflare also validates the origin certificate independently of the public edge certificate and zone SSL/TLS mode. For HTTPS origins, `originServerName` supplies the certificate hostname and TLS SNI when the Service URL uses a different host such as `localhost`. [Cloudflare HTTPS origin guidance](https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/)

## Candidate origin settings

Before cutover, inspect the existing certificate locally: confirm it is currently valid, includes `seedocs.dotsee.local` in its Subject Alternative Name, has the expected private key installed for IIS, and chains to an issuer trusted by the machine running `cloudflared`. A `.local` certificate name does not establish that its issuer is publicly trusted. Reuse the existing certificate only if these checks pass; if its SAN does not include `seedocs.dotsee.local`, it cannot serve this origin name with normal TLS hostname verification. If the certificate is issued by a private CA that `cloudflared` does not trust, configure `caPool` with that CA's PEM bundle; Cloudflare documents this as the private-CA path. Leave TLS verification enabled (`noTLSVerify: false` or the dashboard checkbox off). Cloudflare says a Windows `caPool` may also be needed if `cloudflared` reports that it cannot load the system root pool. Do not treat `noTLSVerify: true` as a production fix. [Cloudflare HTTPS origin guidance](https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/) [Cloudflare origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/)

Configure the IIS HTTPS binding to use a certificate that covers the internal host name `seedocs.dotsee.local` on port 443. IIS bindings can specify a host name and SSL settings; SNI carries the TLS server name when enabled. The precise binding and certificate selection must be checked against the installed certificate and IIS site configuration during implementation. [Microsoft IIS binding element](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/sites/site/bindings/binding)

The Service URL depends on where the connector runs:

| `cloudflared` placement | Service URL candidate | Required reachability check |
|---|---|---|
| Same Windows host as IIS | `https://localhost:443` (or `https://127.0.0.1:443`) | Confirm the IIS HTTPS binding accepts the selected connection and host routing. `localhost` refers to the connector machine. |
| Different host | `https://<IIS-hostname-or-address>:443` | Confirm DNS/routing/firewall reachability from the connector host. Do not use `localhost` unless IIS is on that host. |

For either placement, the candidate TLS name is `seedocs.dotsee.local`. If the IIS site is bound to that internal host, set the origin HTTP `Host` header to `seedocs.dotsee.local` as well so IIS selects the intended site. Cloudflare documents `originServerName` as the TLS certificate/SNI name and `httpHostHeader` as the HTTP Host override; these settings serve different purposes. Verify how this combination interacts with the installed IIS binding before cutover. [Cloudflare origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/)

Schematic locally managed `config.yml` only (replace the service address and CA path if applicable; preserve the existing tunnel identity and credentials):

```yaml
ingress:
  - hostname: docs.dot-see.dev
    service: https://<IIS-origin-reachable-from-cloudflared>:443
    originRequest:
      originServerName: seedocs.dotsee.local
      httpHostHeader: seedocs.dotsee.local
      # Add only if the origin issuer is not trusted by cloudflared:
      # caPool: C:\path\to\issuing-ca.pem
      noTLSVerify: false
  - service: http_status:404
```

For a remotely managed tunnel, apply the equivalent values to the existing `docs.dot-see.dev` route in the Cloudflare dashboard: Service URL `https://<IIS-origin-reachable-from-cloudflared>:443`, HTTP Host Header `seedocs.dotsee.local`, TLS Origin Server Name `seedocs.dotsee.local`, and CA Pool only when needed for private CA trust. Keep “Disable TLS certificate verification” off. Cloudflare's locally managed configuration also requires a final catch-all rule; validate it with `cloudflared tunnel ingress validate`. These are alternative control planes, not settings to apply in both places. [Cloudflare HTTPS origin guidance](https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/) [Cloudflare local configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)

## Preserve the public Wiki.js identity

Keep the Cloudflare public hostname and Wiki.js configured Site URL at `https://docs.dot-see.dev/`. The internal TLS name and, if used, internal HTTP Host header are for origin certificate validation and IIS site selection; they must not become Wiki.js's canonical/public URL. Wiki.js's Google provider configuration is application-level authentication, so after cutover verify its generated callback remains under the public `.dev` hostname and exactly matches the Authorized redirect URI configured for the Google OAuth client. Also inspect redirect `Location` headers after login and logout to ensure no redirect exposes `seedocs.dotsee.local`. Wiki.js documents its Google authentication provider separately from IIS/tunnel routing. [Wiki.js Google authentication](https://docs.requarks.io/auth/google)

This public-versus-origin split is a configuration boundary, not evidence that Wiki.js automatically infers the public URL from the Tunnel headers. Keep the configured Site URL explicit and validate callback/redirect behavior with the deployed version before declaring sign-in verified.

## Cutover checks

1. From the `cloudflared` host, connect to the intended IIS origin using TLS SNI `seedocs.dotsee.local`; verify hostname and chain validation. Cloudflare's diagnostic guidance tests from the connector host because the Tunnel's `Healthy` status only proves that `cloudflared` connects to Cloudflare, not that the configured origin works. [Cloudflare HTTPS origin guidance](https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/)
2. Request IIS using HTTP Host `seedocs.dotsee.local` and confirm the Wiki.js site responds, including its static assets and WebSocket-dependent features if enabled.
3. Change the existing public route from the port-80 service to the HTTPS IIS service during the planned maintenance window. Keep the old Node port-80 path available for rollback until the public checks pass.
4. Through `https://docs.dot-see.dev/`, check sign-in, Google OAuth callback and redirects, representative pages/assets, and WebSocket-dependent behavior. Confirm no response redirects to `seedocs.dotsee.local`.
5. For a locally managed tunnel, run `cloudflared tunnel ingress validate` after editing YAML. For either management mode, inspect connector logs for origin connection and `x509`/TLS errors; a green Tunnel status alone is insufficient.

## Sources

- [Troubleshoot HTTPS origins with Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/)
- [Cloudflare Tunnel origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/)
- [Cloudflare locally managed tunnel configuration file](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/)
- [Microsoft IIS binding element](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/sites/site/bindings/binding)
- [Wiki.js Google authentication provider](https://docs.requarks.io/auth/google)

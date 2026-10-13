# Wiki.js stable startup and HttpPlatformHandler compatibility

Research snapshot: 2026-10-13. Scope is the current stable Wiki.js 2.x source and its compatibility with IIS HttpPlatformHandler (HPH). iisnode is excluded from this compatibility assessment.

## Stable source/version

The `Requarks/wiki` repository identifies itself as the beta for Wiki.js 3.0 and links the current stable 2.x repository, `Requarks/wiki-v2`. The v2 repository describes itself as the maintenance version (2.x). Its latest GitHub release as of this research date is **v2.5.316**, released 2026-10-02. The source claims below are pinned to that release tag rather than the v3 beta repository or an unpinned branch.

## Listener behavior at v2.5.316

The stable tag's `config.sample.yml` sets the main HTTP port to `3000` and the bind address to `0.0.0.0` (all interfaces). `server/core/config.js` loads `config.yml`, merges defaults, and replaces the configured port with `process.env.PORT || 80` only when the configured port is less than 1 or the `HEROKU` environment variable is present. A positive configured value such as the sample's 3000 takes precedence over `PORT`. `server/core/servers.js` creates a Node HTTP server and calls `listen(WIKI.config.port, WIKI.config.bindIP)`; this is a numeric TCP port listener, not a named-pipe listener.

The package's normal start script is `node server`. The application does not automatically read the HPH-specific `HTTP_PLATFORM_PORT` as its listening port. One integration route is an environment mapping from `%HTTP_PLATFORM_PORT%` to `PORT`, plus a Wiki.js configuration that activates its `PORT` fallback (for example, setting its configured main `port` below 1). Mapping `HTTP_PLATFORM_PORT` to `PORT` while retaining the sample's positive `port: 3000` will leave Wiki.js on 3000, which does not match HPH's managed listener port.

A simpler candidate is `port: $(HTTP_PLATFORM_PORT)` in Wiki.js's configuration. The pinned `server/helpers/config.js` substitutes `$(ENV_VAR_NAME)` expressions in raw YAML before parsing it; a substituted numeric port is therefore parsed as a number. This establishes an application-side integration mechanism for the environment variable HPH supplies, while an actual HPH deployment still needs verification. Both routes require an explicit configuration change; neither is drop-in compatibility with the unmodified sample config.

The sample's `bindIP: 0.0.0.0` means Wiki.js listens on all local interfaces. This is the shipped default, not a claim that this is the least-exposed binding for a particular server. An implementation decision should explicitly choose and verify the desired bind scope while preserving reachability from HPH.

## Conclusions and limits

- Stable target: Wiki.js v2.5.316, repository `Requarks/wiki-v2`.
- HPH's dynamic port requires explicit Wiki.js configuration, either direct YAML environment substitution or the mapped `PORT` fallback; a numeric positive YAML port overrides `PORT` in stable source.
- The direct source evidence establishes the app's config and bind behavior. It does not establish a tested HPH+Wiki.js deployment, WebSocket compatibility, proxy path-prefix behavior, upgrade behavior, or support for a particular Windows Server/HPH installer version.
- iisnode is outside this note because the user excluded it from the compatibility decision.

## Primary sources

- [Wiki.js 3.0 beta repository README](https://github.com/Requarks/wiki) — states v3 is beta/not for production and identifies the stable 2.x repository.
- [Wiki.js v2 repository](https://github.com/Requarks/wiki-v2) — identifies the repository as the maintenance version (2.x).
- [Wiki.js v2 releases](https://github.com/Requarks/wiki-v2/releases) — latest listed stable release v2.5.316, dated 2026-10-02.
- [v2.5.316 sample configuration](https://github.com/Requarks/wiki-v2/blob/v2.5.316/config.sample.yml) — `port: 3000` and `bindIP: 0.0.0.0` defaults.
- [v2.5.316 config loader](https://github.com/Requarks/wiki-v2/blob/v2.5.316/server/core/config.js) — `PORT` fallback condition and `HEROKU` exception.
- [v2.5.316 configuration helper](https://github.com/Requarks/wiki-v2/blob/v2.5.316/server/helpers/config.js) — environment substitutions before YAML parsing.
- [v2.5.316 HTTP server startup](https://github.com/Requarks/wiki-v2/blob/v2.5.316/server/core/servers.js) — Node HTTP server construction and `listen(config.port, config.bindIP)` call.
- [v2.5.316 package manifest](https://github.com/Requarks/wiki-v2/blob/v2.5.316/package.json) — package startup script (`node server`).
- [Microsoft HttpPlatformHandler Configuration Reference](https://learn.microsoft.com/en-us/iis/extensions/httpplatformhandler/httpplatformhandler-configuration-reference) — HPH manages an HTTP listener process, proxies requests, and exposes the selected listener port through `%HTTP_PLATFORM_PORT%` in its configuration contract.

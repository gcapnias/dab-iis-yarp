# Wiki.js v2.5.311 startup baseline

Research snapshot: 2026-10-13. The installed version is reported as Wiki.js v2.5.311. This note pins the relevant claims to the `v2.5.311` tag in the stable `Requarks/wiki-v2` repository and compares those claims with tag `v2.5.316`. It records source behavior only; it does not claim a deployment has been tested or recommend an upgrade path.

## v2.5.311 source behavior

- The sample `config.sample.yml` sets main HTTP `port: 3000` and `bindIP: 0.0.0.0` (all interfaces).
- `server/core/config.js` reads the YAML text, calls `cfgHelper.parseConfigValue` on that text, and then passes the result to `yaml.safeLoad`. `server/helpers/config.js` replaces `$(ENV_VAR_NAME)` with the environment value, with `$(ENV_VAR_NAME:default)` support. Because substitution happens before YAML parsing, a numeric environment string inserted into an unquoted numeric port value is parsed as a YAML number.
- The config loader sets `appconfig.port = process.env.PORT || 80` only when the configured port is less than 1 or `HEROKU` is set. The shipped positive value `3000` therefore takes precedence over `PORT`.
- `server/core/servers.js` starts Node's HTTP server with `listen(WIKI.config.port, WIKI.config.bindIP)`. The HTTPS server uses `WIKI.config.ssl.port` with the same bind IP.
- `package.json` defines the normal `start` script as `node server`.
- Apollo Server's subscriptions path is explicitly `/graphql-subscriptions`. The code installs subscription handlers on both the HTTP and HTTPS server objects when each is created.

## Comparison with v2.5.316

I compared the corresponding tagged files in `v2.5.311` and `v2.5.316`: `config.sample.yml`, `server/core/config.js`, `server/helpers/config.js`, `server/core/servers.js`, and `package.json`. For the requested behavior, both tags have the same port default, bind default, pre-YAML environment interpolation contract, `PORT` fallback condition, numeric `listen(port, bindIP)` behavior, `node server` start script, and `/graphql-subscriptions` endpoint. No behavior change affecting this comparison was found in those files.

This comparison is limited to the identified configuration/startup and subscription code. It does not establish that all files or runtime dependencies are otherwise identical, nor that either tag works with a particular IIS module or Windows Server version.

## Primary sources

- [Stable Wiki.js v2 repository](https://github.com/Requarks/wiki-v2) — repository identifies itself as the maintenance version (2.x).
- [v2.5.311 source tag](https://github.com/Requarks/wiki-v2/tree/v2.5.311) — installed-version source tag. It is a Git tag; no GitHub Release entry exists for this tag.
- [v2.5.311 sample configuration](https://github.com/Requarks/wiki-v2/blob/v2.5.311/config.sample.yml) — HTTP port and bind IP defaults.
- [v2.5.311 config loader](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/core/config.js) — interpolation-before-YAML parsing and `PORT` fallback condition.
- [v2.5.311 environment interpolation helper](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/helpers/config.js) — `$(ENV_VAR)` and default syntax implementation.
- [v2.5.311 server startup and GraphQL subscriptions](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/core/servers.js) — HTTP/HTTPS numeric listeners and `/graphql-subscriptions` path.
- [v2.5.311 package manifest](https://github.com/Requarks/wiki-v2/blob/v2.5.311/package.json) — `node server` start script.
- [v2.5.316 sample configuration](https://github.com/Requarks/wiki-v2/blob/v2.5.316/config.sample.yml), [config loader](https://github.com/Requarks/wiki-v2/blob/v2.5.316/server/core/config.js), [environment helper](https://github.com/Requarks/wiki-v2/blob/v2.5.316/server/helpers/config.js), [server startup](https://github.com/Requarks/wiki-v2/blob/v2.5.316/server/core/servers.js), and [package manifest](https://github.com/Requarks/wiki-v2/blob/v2.5.316/package.json) — comparison tag files.

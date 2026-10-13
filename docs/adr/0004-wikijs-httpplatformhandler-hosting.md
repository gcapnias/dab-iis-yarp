---
status: accepted
---

# Use IIS process management for standalone Wiki.js

For the standalone Wiki.js installation, the user selected HttpPlatformHandler to make IIS start and manage the Node process, instead of adding a separately supervised service behind ARR or YARP. iisnode was excluded because its functional release history is too old for this new deployment. This choice applies to the Wiki.js guidance; the repository's ASP.NET Core/DAB application continues to use ANCM.

Upgrade the existing v2.5.311 installation in `C:\wiki` to the verified stable 2.x release and validate it first under Task Scheduler. Then, in a separate planned outage, deploy the upgraded runtime at `C:\inetpub\www-wikijs`, disable the scheduled Wiki.js launcher, and let HPH manage one loopback Node listener. Preserve the existing SQL Server database/connection and use a recovery point that includes the matching database, configuration, and persistent files.

Keep the public Wiki.js address `https://docs.dot-see.dev/` and Google authentication in Wiki.js. Cloudflare Tunnel connects over validated HTTPS to the IIS origin `https://seedocs.dotsee.local`; the existing origin certificate must cover that name and be trusted by the connector. HPH forwards to Node over local HTTP. Public and origin names must remain distinct in Site URL, callback, TLS, and IIS routing configuration.

The user confirmed this design in Q14 on 2026-10-13. Design acceptance does not establish a successful deployment. HPH WebSocket forwarding and target-server startup/recycle/recovery must pass the [guide's acceptance checks](../runbooks/wikijs-upgrade-and-iis-httpplatformhandler.md). Failure returns to the working upgraded task-based installation; switching hosting technology requires a new decision. Supporting evidence is in the [research index](../../archive/research/nodejs-iis/README.md).

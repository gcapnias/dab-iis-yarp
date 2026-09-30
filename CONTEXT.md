# Integrated DAB Application

An application that provides end users access to the API described by its DAB configuration.

## Language

**Configuration-driven DAB access**:
Access through the application to every REST and GraphQL endpoint enabled by DAB configuration, including configured operations and permissions. Configuration changes take effect after restarting the application, without recompiling it; MCP access is optional.
_Avoid_: Products-only integration, fixed-endpoint integration

**Identity issuer**:
The separate application that authenticates a Windows user, retrieves that user's profile and roles from the existing identity database, and issues the JWT used to access the DAB application.
_Avoid_: DAB login service, DAB application

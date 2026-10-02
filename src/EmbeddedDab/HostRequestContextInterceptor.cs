using Azure.DataApiBuilder.Core.Parsers;
using Azure.DataApiBuilder.Core.Authorization;
using HotChocolate.Execution;
using HotChocolate.Execution.Configuration;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

namespace EmbeddedDab;

internal sealed class HostRequestContextInterceptor : IntrospectionInterceptor
{
    public override async ValueTask OnCreateAsync(
        HttpContext context,
        IRequestExecutor requestExecutor,
        OperationRequestBuilder requestBuilder,
        CancellationToken cancellationToken)
    {
        await base.OnCreateAsync(context, requestExecutor, requestBuilder, cancellationToken);
        requestBuilder.SetGlobalState(nameof(HttpContext), context);
        requestBuilder.SetGlobalState(nameof(System.Security.Claims.ClaimsPrincipal), context.User);
        StringValues clientRole = context.Request.Headers[AuthorizationResolver.CLIENT_ROLE_HEADER];
        requestBuilder.SetGlobalState(AuthorizationResolver.CLIENT_ROLE_HEADER, clientRole);
    }
}

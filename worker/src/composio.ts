/**
 * Composio proxy routes for Teachy.
 */

const COMPOSIO_API_BASE_URL = "https://backend.composio.dev/api/v3.1";

interface ComposioEnv {
  COMPOSIO_API_KEY?: string;
}

async function composioAPIRequest(
  apiKey: string,
  path: string,
  options: RequestInit = {}
): Promise<Record<string, unknown>> {
  const response = await fetch(`${COMPOSIO_API_BASE_URL}${path}`, {
    ...options,
    headers: {
      "x-api-key": apiKey,
      "content-type": "application/json",
      ...(options.headers as Record<string, string> | undefined),
    },
  });

  const responseText = await response.text();
  let responseBody: Record<string, unknown>;
  try {
    responseBody = responseText ? (JSON.parse(responseText) as Record<string, unknown>) : {};
  } catch {
    responseBody = { raw: responseText };
  }

  if (!response.ok) {
    const errorObject = responseBody.error as { message?: string } | undefined;
    const errorMessage =
      errorObject?.message ||
      (responseBody.message as string | undefined) ||
      `Composio API error ${response.status}`;
    throw new Error(errorMessage);
  }

  return responseBody;
}

async function fetchActiveConnectedToolkitSlugs(
  apiKey: string,
  userID: string
): Promise<string[]> {
  const responseBody = await composioAPIRequest(
    apiKey,
    `/connected_accounts?user_ids[]=${encodeURIComponent(userID)}&statuses[]=ACTIVE&limit=100`
  );

  const connectedItems = (responseBody.items as Array<{ toolkit?: { slug?: string } }>) || [];
  return connectedItems
    .map((connectedAccount) => connectedAccount.toolkit?.slug)
    .filter((slug): slug is string => Boolean(slug));
}

function pickAuthConfigID(
  authConfigItems: Array<{ id?: string; status?: string }> | undefined
): string | null {
  const enabledAuthConfig = (authConfigItems || []).find(
    (authConfig) => authConfig.status === "ENABLED"
  );
  return enabledAuthConfig?.id || authConfigItems?.[0]?.id || null;
}

async function listAuthConfigIDForToolkit(
  apiKey: string,
  toolkitSlug: string,
  composioManagedOnly: boolean
): Promise<string | null> {
  const managedFilter = composioManagedOnly ? "&is_composio_managed=true" : "";
  const responseBody = await composioAPIRequest(
    apiKey,
    `/auth_configs?toolkit_slug=${encodeURIComponent(toolkitSlug)}${managedFilter}&limit=10`
  );
  return pickAuthConfigID(
    responseBody.items as Array<{ id?: string; status?: string }> | undefined
  );
}

async function createManagedAuthConfigForToolkit(
  apiKey: string,
  toolkitSlug: string
): Promise<string | null> {
  const responseBody = await composioAPIRequest(apiKey, "/auth_configs", {
    method: "POST",
    body: JSON.stringify({
      toolkit: { slug: toolkitSlug },
      auth_config: {
        type: "use_composio_managed_auth",
        name: `Teachy ${toolkitSlug}`,
      },
    }),
  });

  // Create responses vary: top-level id, nested auth_config.id, or auth_config_id.
  const nestedAuthConfig = responseBody.auth_config as { id?: string } | undefined;
  return (
    (responseBody.id as string | undefined) ||
    (responseBody.auth_config_id as string | undefined) ||
    nestedAuthConfig?.id ||
    null
  );
}

async function fetchAuthConfigIDForToolkit(
  apiKey: string,
  toolkitSlug: string
): Promise<string | null> {
  // Prefer an existing Composio-managed config; fall back to any config for the toolkit.
  const managedAuthConfigID = await listAuthConfigIDForToolkit(apiKey, toolkitSlug, true);
  if (managedAuthConfigID) {
    return managedAuthConfigID;
  }

  const anyAuthConfigID = await listAuthConfigIDForToolkit(apiKey, toolkitSlug, false);
  if (anyAuthConfigID) {
    return anyAuthConfigID;
  }

  // New projects often have zero auth configs — create a managed one on first sync.
  return createManagedAuthConfigForToolkit(apiKey, toolkitSlug);
}

export function composioIsConfigured(env: ComposioEnv): boolean {
  return Boolean(env.COMPOSIO_API_KEY);
}

async function fetchAvailableToolkits(
  apiKey: string,
  searchQuery = "",
  limit = 30
): Promise<Array<{ slug: string; name: string; description: string; logo_url: string | null }>> {
  const searchParameter = searchQuery.trim()
    ? `&search=${encodeURIComponent(searchQuery.trim())}`
    : "";
  const responseBody = await composioAPIRequest(
    apiKey,
    `/toolkits?sort_by=usage&limit=${limit}${searchParameter}`
  );

  const toolkitItems =
    (responseBody.items as Array<{
      slug?: string;
      name?: string;
      meta?: { description?: string; logo?: string };
    }>) || [];

  return toolkitItems
    .filter((toolkitItem) => toolkitItem.slug && toolkitItem.name)
    .map((toolkitItem) => ({
      slug: toolkitItem.slug!,
      name: toolkitItem.name!,
      description: toolkitItem.meta?.description || "",
      logo_url: toolkitItem.meta?.logo || null,
    }));
}

export function composioHealthPayload(env: ComposioEnv): Record<string, unknown> {
  const isConfigured = composioIsConfigured(env);
  return {
    composio: isConfigured,
    composio_routes: isConfigured
      ? ["/composio/connections", "/composio/connect", "/composio/toolkits"]
      : [],
  };
}

export async function handleComposioConnections(
  request: Request,
  env: ComposioEnv
): Promise<Response> {
  if (!env.COMPOSIO_API_KEY) {
    return jsonResponse({ error: "COMPOSIO_API_KEY not configured" }, 503);
  }

  const url = new URL(request.url);
  const userID = url.searchParams.get("user_id");
  if (!userID) {
    return jsonResponse({ error: "Missing user_id query parameter" }, 400);
  }

  try {
    const connectedToolkitSlugs = await fetchActiveConnectedToolkitSlugs(
      env.COMPOSIO_API_KEY,
      userID
    );
    return jsonResponse({
      user_id: userID,
      connected_toolkit_slugs: connectedToolkitSlugs,
    });
  } catch (error) {
    return jsonResponse({ error: String(error) }, 502);
  }
}

export async function handleComposioConnect(
  request: Request,
  env: ComposioEnv
): Promise<Response> {
  if (!env.COMPOSIO_API_KEY) {
    return jsonResponse({ error: "COMPOSIO_API_KEY not configured" }, 503);
  }

  const requestBody = (await request.json()) as {
    user_id?: string;
    toolkit_slug?: string;
  };

  const userID = requestBody.user_id?.trim();
  const toolkitSlug = requestBody.toolkit_slug?.trim();

  if (!userID || !toolkitSlug) {
    return jsonResponse({ error: "Missing user_id or toolkit_slug" }, 400);
  }

  try {
    const authConfigID = await fetchAuthConfigIDForToolkit(env.COMPOSIO_API_KEY, toolkitSlug);
    if (!authConfigID) {
      return jsonResponse(
        {
          error: `Could not create a Composio auth config for toolkit "${toolkitSlug}".`,
        },
        502
      );
    }

    const responseBody = await composioAPIRequest(env.COMPOSIO_API_KEY, "/connected_accounts/link", {
      method: "POST",
      body: JSON.stringify({
        auth_config_id: authConfigID,
        user_id: userID,
      }),
    });

    return jsonResponse({
      toolkit_slug: toolkitSlug,
      redirect_url: responseBody.redirect_url,
      link_token: responseBody.link_token,
      expires_at: responseBody.expires_at,
      connected_account_id: responseBody.connected_account_id,
    });
  } catch (error) {
    return jsonResponse({ error: String(error) }, 502);
  }
}

export async function handleComposioToolkits(
  request: Request,
  env: ComposioEnv
): Promise<Response> {
  if (!env.COMPOSIO_API_KEY) {
    return jsonResponse({ error: "COMPOSIO_API_KEY not configured" }, 503);
  }

  const url = new URL(request.url);
  const searchQuery = url.searchParams.get("search") || "";
  const limitParameter = Number(url.searchParams.get("limit") || "30");
  const limit = Number.isFinite(limitParameter) ? Math.min(limitParameter, 50) : 30;

  try {
    const toolkits = await fetchAvailableToolkits(env.COMPOSIO_API_KEY, searchQuery, limit);
    return jsonResponse({ toolkits });
  } catch (error) {
    return jsonResponse({ error: String(error) }, 502);
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

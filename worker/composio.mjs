/**
 * Composio API helpers — shared by Cloudflare Worker and local proxy.
 */

const COMPOSIO_API_BASE_URL = "https://backend.composio.dev/api/v3.1";

export async function composioAPIRequest(apiKey, path, options = {}) {
  const response = await fetch(`${COMPOSIO_API_BASE_URL}${path}`, {
    ...options,
    headers: {
      "x-api-key": apiKey,
      "content-type": "application/json",
      ...(options.headers || {}),
    },
  });

  const responseText = await response.text();
  let responseBody;
  try {
    responseBody = responseText ? JSON.parse(responseText) : {};
  } catch {
    responseBody = { raw: responseText };
  }

  if (!response.ok) {
    const errorMessage =
      responseBody?.error?.message ||
      responseBody?.message ||
      `Composio API error ${response.status}`;
    throw new Error(errorMessage);
  }

  return responseBody;
}

export async function fetchActiveConnectedToolkitSlugs(apiKey, userID) {
  const responseBody = await composioAPIRequest(
    apiKey,
    `/connected_accounts?user_ids[]=${encodeURIComponent(userID)}&statuses[]=ACTIVE&limit=100`
  );

  const connectedItems = responseBody.items || [];
  return connectedItems
    .map((connectedAccount) => connectedAccount?.toolkit?.slug)
    .filter(Boolean);
}

function pickAuthConfigID(authConfigItems) {
  const enabledAuthConfig = (authConfigItems || []).find(
    (authConfig) => authConfig?.status === "ENABLED"
  );
  return enabledAuthConfig?.id || authConfigItems?.[0]?.id || null;
}

async function listAuthConfigIDForToolkit(apiKey, toolkitSlug, composioManagedOnly) {
  const managedFilter = composioManagedOnly ? "&is_composio_managed=true" : "";
  const responseBody = await composioAPIRequest(
    apiKey,
    `/auth_configs?toolkit_slug=${encodeURIComponent(toolkitSlug)}${managedFilter}&limit=10`
  );
  return pickAuthConfigID(responseBody.items);
}

async function createManagedAuthConfigForToolkit(apiKey, toolkitSlug) {
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
  return (
    responseBody.id ||
    responseBody.auth_config_id ||
    responseBody.auth_config?.id ||
    null
  );
}

export async function fetchAuthConfigIDForToolkit(apiKey, toolkitSlug) {
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

export async function createComposioConnectLink(apiKey, userID, toolkitSlug) {
  const authConfigID = await fetchAuthConfigIDForToolkit(apiKey, toolkitSlug);
  if (!authConfigID) {
    throw new Error(
      `Could not create a Composio auth config for toolkit "${toolkitSlug}".`
    );
  }

  const responseBody = await composioAPIRequest(apiKey, "/connected_accounts/link", {
    method: "POST",
    body: JSON.stringify({
      auth_config_id: authConfigID,
      user_id: userID,
    }),
  });

  return {
    redirect_url: responseBody.redirect_url,
    link_token: responseBody.link_token,
    expires_at: responseBody.expires_at,
    connected_account_id: responseBody.connected_account_id,
  };
}

export async function fetchAvailableToolkits(apiKey, searchQuery = "", limit = 30) {
  const searchParameter = searchQuery.trim()
    ? `&search=${encodeURIComponent(searchQuery.trim())}`
    : "";
  const responseBody = await composioAPIRequest(
    apiKey,
    `/toolkits?sort_by=usage&limit=${limit}${searchParameter}`
  );

  const toolkitItems = responseBody.items || [];
  return toolkitItems.map((toolkitItem) => ({
    slug: toolkitItem.slug,
    name: toolkitItem.name,
    description: toolkitItem.meta?.description || "",
    logo_url: toolkitItem.meta?.logo || null,
  }));
}

export function composioHealthPayload(isConfigured) {
  return {
    composio: isConfigured,
    composio_routes: isConfigured
      ? ["/composio/connections", "/composio/connect", "/composio/toolkits"]
      : [],
  };
}

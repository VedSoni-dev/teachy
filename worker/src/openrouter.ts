/**
 * Multi-provider handlers for the Cloudflare Worker.
 *
 * Supports OpenRouter, Anthropic, and OpenAI. The active provider is determined
 * by which API key is present in the worker environment.
 *
 * Priority: OPENROUTER_API_KEY > ANTHROPIC_API_KEY > OPENAI_API_KEY
 */

import {
  resolveChatModel,
  resolveCompletionsModel,
  detectProvider,
  providerVisionModel,
  providerTextModel,
} from "./model-routing";

export interface ProviderEnv {
  OPENROUTER_API_KEY?: string;
  ANTHROPIC_API_KEY?: string;
  OPENAI_API_KEY?: string;
  CHAT_MODEL?: string;
  AGENT_MODEL?: string;
  MODEL?: string;
  VISION_MODEL?: string;
  TEXT_MODEL?: string;
  WORKER_REFERER?: string;
}

// ─── Provider Detection ──────────────────────────────────────────────────────

function getProvider(env: ProviderEnv): string {
  return detectProvider(env);
}

function providerLabel(provider: string): string {
  const labels: Record<string, string> = {
    openrouter: "OpenRouter",
    anthropic: "Anthropic",
    openai: "OpenAI",
  };
  return labels[provider] || provider;
}

// ─── Model Resolution ────────────────────────────────────────────────────────

const LEGACY_CLAUDE_MODEL_MAP: Record<string, true> = {
  "claude-sonnet-4-6": true,
  "claude-opus-4-6": true,
};

export function chatModelForRequest(env: ProviderEnv, requestedModel?: string): string {
  const provider = getProvider(env);
  const fallback = env.VISION_MODEL || env.CHAT_MODEL || env.MODEL || providerVisionModel(provider);
  if (!requestedModel || requestedModel in LEGACY_CLAUDE_MODEL_MAP) {
    return fallback;
  }
  return resolveChatModel(requestedModel, provider);
}

export function agentModelForRequest(
  env: ProviderEnv,
  requestedModel?: string,
  messages?: unknown
): string {
  const provider = getProvider(env);
  const fallback = env.TEXT_MODEL || env.AGENT_MODEL || env.MODEL || providerTextModel(provider);
  if (!requestedModel) {
    return fallback;
  }
  return resolveCompletionsModel(requestedModel, messages, provider);
}

// ─── Format Converters ───────────────────────────────────────────────────────

/**
 * Convert Anthropic Messages API format → OpenAI Chat Completions format.
 */
function anthropicToOpenAI(body: Record<string, unknown>, model: string) {
  const messages: Array<Record<string, unknown>> = [];

  if (typeof body.system === "string") {
    messages.push({ role: "system", content: body.system });
  }

  for (const msg of (body.messages as Array<Record<string, unknown>>) || []) {
    if (typeof msg.content === "string") {
      messages.push({ role: msg.role, content: msg.content });
      continue;
    }

    if (Array.isArray(msg.content)) {
      const converted = msg.content.map((block: Record<string, unknown>) => {
        if (block.type === "text") {
          return { type: "text", text: block.text };
        }
        if (block.type === "image") {
          const source = block.source as Record<string, string>;
          return {
            type: "image_url",
            image_url: {
              url: `data:${source.media_type || "image/jpeg"};base64,${source.data}`,
            },
          };
        }
        return block;
      });
      messages.push({ role: msg.role, content: converted });
    }
  }

  return {
    model,
    max_tokens: (body.max_tokens as number) || 1024,
    stream: body.stream !== false,
    messages,
  };
}

/**
 * Convert OpenAI Chat Completions format → Anthropic Messages API format.
 */
function openAIToAnthropic(body: Record<string, unknown>, model: string) {
  const messages: Array<Record<string, unknown>> = [];

  for (const msg of (body.messages as Array<Record<string, unknown>>) || []) {
    if (msg.role === "system") continue; // handled separately
    if (typeof msg.content === "string") {
      messages.push({ role: msg.role, content: msg.content });
      continue;
    }
    if (Array.isArray(msg.content)) {
      const converted = msg.content.map((block: Record<string, unknown>) => {
        if (block.type === "text") {
          return { type: "text", text: block.text };
        }
        if (block.type === "image_url") {
          const url = (block.image_url as Record<string, string>)?.url || "";
          const match = url.match(/^data:([^;]+);base64,(.+)$/);
          if (match) {
            return {
              type: "image",
              source: { type: "base64", media_type: match[1], data: match[2] },
            };
          }
        }
        return block;
      });
      messages.push({ role: msg.role, content: converted });
    }
  }

  const systemMsg = (body.messages as Array<Record<string, unknown>>)?.find(
    (m) => m.role === "system"
  );
  const systemContent = systemMsg
    ? typeof systemMsg.content === "string"
      ? systemMsg.content
      : undefined
    : undefined;

  return {
    model,
    max_tokens: (body.max_tokens as number) || 1024,
    stream: body.stream !== false,
    ...(systemContent ? { system: systemContent } : {}),
    messages,
  };
}

// ─── Response Converters ─────────────────────────────────────────────────────

function openAIChunkToAnthropic(chunk: Record<string, unknown>) {
  const choices = chunk.choices as Array<Record<string, unknown>> | undefined;
  const delta = choices?.[0]?.delta as Record<string, unknown> | undefined;
  const content = delta?.content as string | undefined;
  if (!content) return null;
  return { type: "content_block_delta", delta: { type: "text_delta", text: content } };
}

function openAIResponseToAnthropic(response: Record<string, unknown>) {
  const choices = response.choices as Array<Record<string, unknown>> | undefined;
  const message = choices?.[0]?.message as Record<string, unknown> | undefined;
  const text = (message?.content as string) || "";
  return { content: [{ type: "text", text }] };
}

// ─── Headers ─────────────────────────────────────────────────────────────────

function openRouterHeaders(env: ProviderEnv, title: string): Record<string, string> {
  return {
    Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
    "Content-Type": "application/json",
    "HTTP-Referer": env.WORKER_REFERER || "https://github.com/VedSoni-dev/teachy",
    "X-Title": title,
  };
}

function anthropicHeaders(env: ProviderEnv): Record<string, string> {
  return {
    "x-api-key": env.ANTHROPIC_API_KEY!,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json",
  };
}

function openAIHeaders(env: ProviderEnv): Record<string, string> {
  return {
    Authorization: `Bearer ${env.OPENAI_API_KEY}`,
    "Content-Type": "application/json",
  };
}

// ─── /chat Handler ───────────────────────────────────────────────────────────

/**
 * POST /chat — Companion vision chat.
 *
 * The Swift app sends Anthropic Messages API format. Routes to the active
 * provider with format conversion as needed.
 */
export async function handleProviderChat(
  request: Request,
  env: ProviderEnv
): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  const provider = getProvider(env);
  const requestedModel = body.model as string | undefined;
  const isStream = body.stream !== false;

  const resolvedModel = chatModelForRequest(env, requestedModel);

  console.log(`[/chat] provider=${provider} model=${resolvedModel} stream=${isStream}`);

  try {
    let upstream: Response;

    if (provider === "openrouter") {
      const openAIBody = anthropicToOpenAI(body, resolvedModel);
      upstream = await fetch("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: openRouterHeaders(env, "Teachy"),
        body: JSON.stringify(openAIBody),
      });
    } else if (provider === "anthropic") {
      const anthropicBody = { ...body, model: resolvedModel };
      upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: anthropicHeaders(env),
        body: JSON.stringify(anthropicBody),
      });
    } else {
      const openAIBody = anthropicToOpenAI(body, resolvedModel);
      upstream = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: openAIHeaders(env),
        body: JSON.stringify(openAIBody),
      });
    }

    if (!upstream.ok) {
      const errorText = await upstream.text();
      console.error(`[/chat] ${providerLabel(provider)} error ${upstream.status}: ${errorText}`);
      return new Response(errorText, {
        status: upstream.status,
        headers: { "content-type": "application/json" },
      });
    }

    // Anthropic provider returns Anthropic format directly
    if (provider === "anthropic") {
      return new Response(upstream.body, {
        status: upstream.status,
        headers: {
          "content-type": upstream.headers.get("content-type") || "text/event-stream",
          "cache-control": "no-cache",
          "Access-Control-Allow-Origin": "*",
        },
      });
    }

    // OpenRouter/OpenAI return OpenAI format — convert to Anthropic format
    if (!isStream) {
      const data = (await upstream.json()) as Record<string, unknown>;
      return Response.json(openAIResponseToAnthropic(data));
    }

    // Streaming: OpenAI SSE → Anthropic SSE
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    (async () => {
      const reader = upstream.body!.getReader();
      let buffer = "";
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const payload = line.slice(6).trim();
            if (payload === "[DONE]") {
              await writer.write(encoder.encode("data: [DONE]\n\n"));
              continue;
            }
            try {
              const anthropicEvent = openAIChunkToAnthropic(JSON.parse(payload));
              if (anthropicEvent) {
                await writer.write(encoder.encode(`data: ${JSON.stringify(anthropicEvent)}\n\n`));
              }
            } catch {
              // skip malformed chunks
            }
          }
        }
      } finally {
        await writer.close();
      }
    })();

    return new Response(readable, {
      status: 200,
      headers: {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
      },
    });
  } catch (error) {
    console.error(`[/chat] Unhandled error:`, error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
}

// ─── /v1/chat/completions Handler ────────────────────────────────────────────

/**
 * POST /v1/chat/completions — Background agent tool loop.
 *
 * The Swift app sends OpenAI Chat Completions format. Routes to the active
 * provider with format conversion as needed.
 */
export async function handleProviderCompletions(
  request: Request,
  env: ProviderEnv
): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  const provider = getProvider(env);
  const messages = body.messages;
  const resolvedModel = agentModelForRequest(env, body.model as string, messages);
  const forwardedBody = { ...body, model: resolvedModel };

  const hasTools = Array.isArray(forwardedBody.tools) && forwardedBody.tools.length > 0;
  console.log(
    `[/v1/chat/completions] provider=${provider} model=${resolvedModel} tools=${hasTools} messages=${(forwardedBody.messages || []).length}`
  );

  try {
    let upstream: Response;

    if (provider === "anthropic") {
      // OpenAI format → Anthropic Messages API
      const anthropicBody = openAIToAnthropic(forwardedBody, resolvedModel);
      upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: anthropicHeaders(env),
        body: JSON.stringify(anthropicBody),
      });
    } else if (provider === "openrouter") {
      upstream = await fetch("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: openRouterHeaders(env, "Teachy Agent"),
        body: JSON.stringify(forwardedBody),
      });
    } else {
      upstream = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: openAIHeaders(env),
        body: JSON.stringify(forwardedBody),
      });
    }

    if (!upstream.ok) {
      const errorText = await upstream.text();
      console.error(`[/v1/chat/completions] ${providerLabel(provider)} error ${upstream.status}: ${errorText}`);
      return new Response(errorText, {
        status: upstream.status,
        headers: { "content-type": "application/json" },
      });
    }

    if (provider === "anthropic") {
      // Convert Anthropic response → OpenAI format for the Swift agent loop
      const data = (await upstream.json()) as Record<string, unknown>;
      const openAIResponse = {
        choices: [
          {
            message: {
              role: "assistant",
              content: (data.content as Array<Record<string, unknown>>)?.[0]?.text || "",
            },
            finish_reason: "stop",
          },
        ],
      };
      return Response.json(openAIResponse);
    }

    // OpenRouter and OpenAI both return OpenAI format
    const data = await upstream.json();
    return Response.json(data);
  } catch (error) {
    console.error(`[/v1/chat/completions] Unhandled error:`, error);
    return new Response(JSON.stringify({ error: String(error) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
}

// ─── Health ──────────────────────────────────────────────────────────────────

export function providerHealthPayload(env: ProviderEnv) {
  const provider = getProvider(env);
  return {
    ok: true,
    service: "teachy-proxy",
    backend: provider,
    backendLabel: providerLabel(provider),
    openrouter: Boolean(env.OPENROUTER_API_KEY),
    anthropic: Boolean(env.ANTHROPIC_API_KEY),
    openai: Boolean(env.OPENAI_API_KEY),
    models: {
      default: env.MODEL || providerVisionModel(provider),
      vision: env.VISION_MODEL || env.MODEL || providerVisionModel(provider),
      text: env.TEXT_MODEL || env.MODEL || providerTextModel(provider),
      chat: chatModelForRequest(env),
      agent: agentModelForRequest(env),
    },
    routes: ["/health", "/chat", "/v1/chat/completions", "/tts", "/transcribe-token"],
  };
}

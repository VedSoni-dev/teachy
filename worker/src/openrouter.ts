/**
 * OpenRouter helpers shared by the Cloudflare Worker.
 * Mirrors worker/config.mjs used by the local proxy.
 */

import {
  resolveChatModel,
  resolveCompletionsModel,
  TEXT_MODEL,
  VISION_MODEL,
} from "./model-routing";

export interface OpenRouterEnv {
  OPENROUTER_API_KEY: string;
  CHAT_MODEL?: string;
  AGENT_MODEL?: string;
  MODEL?: string;
  VISION_MODEL?: string;
  TEXT_MODEL?: string;
  WORKER_REFERER?: string;
}

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

const LEGACY_CLAUDE_MODEL_MAP: Record<string, true> = {
  "claude-sonnet-4-6": true,
  "claude-opus-4-6": true,
};

export function chatModelForRequest(env: OpenRouterEnv, requestedModel?: string): string {
  const fallback = env.VISION_MODEL || env.CHAT_MODEL || env.MODEL || VISION_MODEL;
  if (!requestedModel || requestedModel in LEGACY_CLAUDE_MODEL_MAP) {
    return fallback;
  }
  return resolveChatModel(requestedModel);
}

export function agentModelForRequest(
  env: OpenRouterEnv,
  requestedModel?: string,
  messages?: unknown
): string {
  const fallback = env.TEXT_MODEL || env.AGENT_MODEL || env.MODEL || TEXT_MODEL;
  if (!requestedModel) {
    return fallback;
  }
  return resolveCompletionsModel(requestedModel, messages);
}

function openRouterHeaders(env: OpenRouterEnv, title: string): Record<string, string> {
  return {
    Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
    "Content-Type": "application/json",
    "HTTP-Referer": env.WORKER_REFERER || "https://github.com/farzaa/clicky",
    "X-Title": title,
  };
}

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

export async function handleOpenRouterChat(
  request: Request,
  env: OpenRouterEnv
): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  const openAIBody = anthropicToOpenAI(body, chatModelForRequest(env, body.model as string));
  const isStream = body.stream !== false;

  const upstream = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: openRouterHeaders(env, "Teachy"),
    body: JSON.stringify(openAIBody),
  });

  if (!upstream.ok) {
    const errorText = await upstream.text();
    console.error(`[/chat] OpenRouter error ${upstream.status}: ${errorText}`);
    return new Response(errorText, {
      status: upstream.status,
      headers: { "content-type": "application/json" },
    });
  }

  if (!isStream) {
    const data = (await upstream.json()) as Record<string, unknown>;
    return Response.json(openAIResponseToAnthropic(data));
  }

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
}

export async function handleOpenRouterCompletions(
  request: Request,
  env: OpenRouterEnv
): Promise<Response> {
  const body = (await request.json()) as Record<string, unknown>;
  const messages = body.messages;
  const resolvedModel = agentModelForRequest(env, body.model as string, messages);
  const forwardedBody = { ...body, model: resolvedModel };

  const upstream = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: openRouterHeaders(env, "Teachy Agent"),
    body: JSON.stringify(forwardedBody),
  });

  if (!upstream.ok) {
    const errorText = await upstream.text();
    console.error(`[/v1/chat/completions] OpenRouter error ${upstream.status}: ${errorText}`);
    return new Response(errorText, {
      status: upstream.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await upstream.json();
  return Response.json(data);
}

export function openRouterHealthPayload(env: OpenRouterEnv) {
  return {
    ok: true,
    service: "teachy-proxy",
    backend: "openrouter",
    openrouter: true,
    models: {
      default: env.MODEL || VISION_MODEL,
      vision: env.VISION_MODEL || env.MODEL || VISION_MODEL,
      text: env.TEXT_MODEL || env.MODEL || TEXT_MODEL,
      chat: chatModelForRequest(env),
      agent: agentModelForRequest(env),
    },
    routes: ["/health", "/chat", "/v1/chat/completions", "/tts", "/transcribe-token"],
  };
}

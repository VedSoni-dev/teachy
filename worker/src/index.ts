/**
 * Teachy Proxy Worker (Cloudflare)
 *
 * Multi-provider AI backend — supports OpenRouter, Anthropic, and OpenAI.
 * The active provider is determined by which API key is present.
 *
 * Priority: OPENROUTER_API_KEY > ANTHROPIC_API_KEY > OPENAI_API_KEY
 *
 * Routes:
 *   GET  /health                  — proxy status + active backend + models
 *   POST /chat                    — companion vision chat (Anthropic format in)
 *   POST /v1/chat/completions     — background agent tool loop (OpenAI format in)
 *   POST /tts                     — ElevenLabs TTS (or stub)
 *   POST /transcribe-token        — AssemblyAI streaming token
 */

import {
  handleProviderChat,
  handleProviderCompletions,
  providerHealthPayload,
  type ProviderEnv,
} from "./openrouter";
import {
  composioHealthPayload,
  handleComposioConnect,
  handleComposioConnections,
  handleComposioToolkits,
} from "./composio";
import { detectProvider } from "./model-routing";

interface Env extends ProviderEnv {
  ELEVENLABS_API_KEY?: string;
  ELEVENLABS_VOICE_ID?: string;
  ASSEMBLYAI_API_KEY?: string;
  COMPOSIO_API_KEY?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(),
      });
    }

    if (request.method === "GET" && url.pathname === "/health") {
      return handleHealth(env);
    }

    if (request.method === "GET" && url.pathname === "/composio/connections") {
      return handleComposioConnections(request, env);
    }

    if (request.method === "GET" && url.pathname === "/composio/toolkits") {
      return handleComposioToolkits(request, env);
    }

    if (request.method === "POST" && url.pathname === "/composio/connect") {
      return handleComposioConnect(request, env);
    }

    if (request.method !== "POST") {
      return jsonResponse({ error: "Method not allowed" }, 405);
    }

    try {
      if (url.pathname === "/chat") {
        return await handleProviderChat(request, env);
      }

      if (url.pathname === "/v1/chat/completions") {
        return await handleProviderCompletions(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: String(error) }, 500);
    }

    return jsonResponse({ error: "Not found" }, 404);
  },
};

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      ...corsHeaders(),
    },
  });
}

function handleHealth(env: Env): Response {
  const provider = detectProvider(env);

  // Composio payload (independent of AI provider)
  const composio = composioHealthPayload(env);

  if (provider === "openrouter" || provider === "anthropic" || provider === "openai") {
    return jsonResponse({
      ...providerHealthPayload(env),
      ...composio,
    });
  }

  return jsonResponse({
    ok: true,
    service: "teachy-proxy",
    backend: "unconfigured",
    openrouter: false,
    anthropic: false,
    openai: false,
    ...composio,
    models: {
      chat: null,
      agent: null,
    },
    routes: ["/health", "/chat", "/tts", "/transcribe-token", "/composio/connections", "/composio/connect"],
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!env.ASSEMBLYAI_API_KEY) {
    return jsonResponse({
      token: "local",
      note: "ASSEMBLYAI_API_KEY not configured",
    });
  }

  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY || !env.ELEVENLABS_VOICE_ID) {
    return jsonResponse({ ok: true, note: "TTS not configured — app uses local speech" });
  }

  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID;

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
      ...corsHeaders(),
    },
  });
}

#!/usr/bin/env node
/**
 * Teachy Local Proxy — multi-provider AI backend.
 *
 * Supports OpenRouter, Anthropic, and OpenAI. The proxy auto-detects which
 * provider to use based on which API key is present in worker/.env.
 *
 * Priority: OPENROUTER_API_KEY > ANTHROPIC_API_KEY > OPENAI_API_KEY
 *
 * Usage:
 *   1. Create worker/.env (see .env.template) with at least one provider key
 *   2. npm run local
 *   3. App points at http://localhost:8787 (CompanionManager.workerBaseURL)
 *
 * Routes:
 *   GET  /health                  — proxy status + active backend + models
 *   POST /chat                    — companion vision chat (Anthropic format in)
 *   POST /v1/chat/completions     — background agent tool loop (OpenAI format in)
 *   POST /tts                     — ElevenLabs / OpenAI TTS (or stub → local neural)
 *   POST /transcribe-token        — AssemblyAI streaming token (or stub)
 */

import { createServer } from 'http';
import {
  composioHealthPayload,
  createComposioConnectLink,
  fetchActiveConnectedToolkitSlugs,
  fetchAvailableToolkits,
} from './composio.mjs';
import {
  ACTIVE_PROVIDER,
  ANTHROPIC_API_KEY,
  ANTHROPIC_URL,
  ASSEMBLYAI_API_KEY,
  ELEVENLABS_API_KEY,
  ELEVENLABS_VOICE_ID,
  OPENAI_API_KEY,
  OPENAI_URL,
  OPENROUTER_API_KEY,
  OPENROUTER_URL,
  PORT,
  anthropicHeaders,
  openAIHeaders,
  openRouterHeaders,
  resolveAgentModel,
  resolveChatModelRequest,
  VISION_MODEL,
  TEXT_MODEL,
  MODEL,
  CHAT_MODEL,
  AGENT_MODEL,
} from './config.mjs';
import {
  resolveChatModel,
  resolveCompletionsModel,
  providerVisionModel,
  providerTextModel,
  requestMessagesContainImages,
} from './model-routing.mjs';

const COMPOSIO_API_KEY = process.env.COMPOSIO_API_KEY;

// ─── Startup ─────────────────────────────────────────────────────────────────

if (!ACTIVE_PROVIDER) {
  console.error('❌ No AI provider configured.');
  console.error('   Add at least one key to worker/.env:');
  console.error('     OPENROUTER_API_KEY  (recommended — free tier available)');
  console.error('     ANTHROPIC_API_KEY   (Claude direct)');
  console.error('     OPENAI_API_KEY      (GPT direct)');
  console.error('   Copy .env.template → .env and fill in your key.');
  process.exit(1);
}

const BACKEND_LABELS = {
  openrouter: 'OpenRouter',
  anthropic: 'Anthropic (Claude)',
  openai: 'OpenAI (GPT)',
};

// ─── Format Converters ───────────────────────────────────────────────────────

/**
 * Convert Anthropic Messages API format → OpenAI Chat Completions format.
 * Used when the upstream expects OpenAI format (OpenRouter, OpenAI direct).
 */
function anthropicToOpenAI(body, model) {
  const messages = [];

  if (body.system) {
    messages.push({ role: 'system', content: body.system });
  }

  for (const msg of body.messages || []) {
    if (typeof msg.content === 'string') {
      messages.push({ role: msg.role, content: msg.content });
    } else if (Array.isArray(msg.content)) {
      const converted = msg.content.map((block) => {
        if (block.type === 'text') {
          return { type: 'text', text: block.text };
        }
        if (block.type === 'image') {
          const source = block.source;
          return {
            type: 'image_url',
            image_url: {
              url: `data:${source.media_type || 'image/jpeg'};base64,${source.data}`,
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
    max_tokens: body.max_tokens || 1024,
    stream: body.stream !== false,
    messages,
  };
}

/**
 * Convert OpenAI Chat Completions format → Anthropic Messages API format.
 * Used when the upstream expects Anthropic format (Anthropic direct).
 */
function openAIToAnthropic(body, model) {
  const messages = [];

  for (const msg of body.messages || []) {
    if (msg.role === 'system') {
      // Anthropic puts system as a top-level field
      continue; // handled separately below
    }
    if (typeof msg.content === 'string') {
      messages.push({ role: msg.role, content: msg.content });
    } else if (Array.isArray(msg.content)) {
      const converted = msg.content.map((block) => {
        if (block.type === 'text') {
          return { type: 'text', text: block.text };
        }
        if (block.type === 'image_url') {
          const url = block.image_url?.url || '';
          // Parse data URI
          const match = url.match(/^data:([^;]+);base64,(.+)$/);
          if (match) {
            return {
              type: 'image',
              source: { type: 'base64', media_type: match[1], data: match[2] },
            };
          }
        }
        return block;
      });
      messages.push({ role: msg.role, content: converted });
    }
  }

  // Extract system message
  const systemMsg = (body.messages || []).find((m) => m.role === 'system');
  const systemContent = systemMsg
    ? (typeof systemMsg.content === 'string' ? systemMsg.content : '')
    : undefined;

  return {
    model,
    max_tokens: body.max_tokens || 1024,
    stream: body.stream !== false,
    ...(systemContent ? { system: systemContent } : {}),
    messages,
  };
}

// ─── Upstream Senders ────────────────────────────────────────────────────────

/**
 * Send to OpenRouter (OpenAI-compatible API).
 * Returns { status, headers, body } for the upstream response.
 */
async function sendToOpenRouter(openAIBody, title = 'Teachy') {
  return fetch(OPENROUTER_URL, {
    method: 'POST',
    headers: openRouterHeaders(title),
    body: JSON.stringify(openAIBody),
  });
}

/**
 * Send to Anthropic Messages API directly.
 */
async function sendToAnthropic(anthropicBody) {
  return fetch(ANTHROPIC_URL, {
    method: 'POST',
    headers: anthropicHeaders(),
    body: JSON.stringify(anthropicBody),
  });
}

/**
 * Send to OpenAI Chat Completions API directly.
 */
async function sendToOpenAI(openAIBody) {
  return fetch(OPENAI_URL, {
    method: 'POST',
    headers: openAIHeaders(),
    body: JSON.stringify(openAIBody),
  });
}

// ─── Response Converters (SSE Streaming) ─────────────────────────────────────

/** Convert OpenAI streaming chunk → Anthropic streaming event. */
function openAIChunkToAnthropic(chunk) {
  const content = chunk.choices?.[0]?.delta?.content;
  if (!content) return null;
  return { type: 'content_block_delta', delta: { type: 'text_delta', text: content } };
}

/** Convert OpenAI non-streaming response → Anthropic response. */
function openAIResponseToAnthropic(response) {
  const text = response.choices?.[0]?.message?.content || '';
  return { content: [{ type: 'text', text }] };
}

/** Convert Anthropic streaming event → Anthropic SSE for the Swift client. */
function anthropicEventToSSE(event) {
  return `data: ${JSON.stringify(event)}\n\n`;
}

// ─── Streaming Proxy Helper ──────────────────────────────────────────────────

/**
 * Pipe an upstream SSE stream through a chunk converter, sending Anthropic-format
 * SSE events to the downstream client.
 */
async function pipeSSEStream(upstream, res, chunkToAnthropic) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  });

  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (!line.startsWith('data: ')) continue;
        const payload = line.slice(6).trim();
        if (payload === '[DONE]') {
          res.write('data: [DONE]\n\n');
          continue;
        }
        try {
          const anthropicEvent = chunkToAnthropic(JSON.parse(payload));
          if (anthropicEvent) res.write(anthropicEventToSSE(anthropicEvent));
        } catch {
          // skip malformed chunks
        }
      }
    }
  } finally {
    reader.cancel().catch(() => {});
    res.end();
  }
}

// ─── Route Handlers ──────────────────────────────────────────────────────────

function handleHealth(_req, res) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(
    JSON.stringify({
      ok: true,
      service: 'teachy-local-proxy',
      backend: ACTIVE_PROVIDER,
      backendLabel: BACKEND_LABELS[ACTIVE_PROVIDER],
      openrouter: Boolean(OPENROUTER_API_KEY),
      anthropic: Boolean(ANTHROPIC_API_KEY),
      openai: Boolean(OPENAI_API_KEY),
      assemblyai: Boolean(ASSEMBLYAI_API_KEY),
      ...composioHealthPayload(Boolean(COMPOSIO_API_KEY)),
      models: {
        default: MODEL,
        vision: providerVisionModel(ACTIVE_PROVIDER),
        text: providerTextModel(ACTIVE_PROVIDER),
        chat: CHAT_MODEL,
        agent: AGENT_MODEL,
      },
      routes: [
        '/health',
        '/chat',
        '/v1/chat/completions',
        '/tts',
        '/transcribe-token',
        '/composio/connections',
        '/composio/connect',
        '/composio/toolkits',
      ],
    })
  );
}

/**
 * POST /chat — Companion vision chat.
 *
 * The Swift app sends Anthropic Messages API format. We route to the active
 * provider, converting formats as needed:
 *   - OpenRouter: Anthropic → OpenAI → OpenRouter
 *   - Anthropic:  Anthropic → Anthropic (passthrough)
 *   - OpenAI:     Anthropic → OpenAI → OpenAI
 */
async function handleChat(req, res) {
  const buffers = [];
  for await (const chunk of req) buffers.push(chunk);
  const body = JSON.parse(Buffer.concat(buffers).toString());

  const requestedModel = body.model;
  const isStream = body.stream !== false;

  console.log(`[/chat] provider=${ACTIVE_PROVIDER} model=${requestedModel || '(default)'} stream=${isStream}`);

  try {
    let upstream;

    if (ACTIVE_PROVIDER === 'openrouter') {
      const resolvedModel = resolveChatModelRequest(requestedModel);
      const openAIBody = anthropicToOpenAI(body, resolvedModel);
      upstream = await sendToOpenRouter(openAIBody, 'Teachy');
    } else if (ACTIVE_PROVIDER === 'anthropic') {
      // Anthropic format → Anthropic API (passthrough with model resolution)
      const resolvedModel = resolveChatModel(requestedModel, 'anthropic');
      const anthropicBody = { ...body, model: resolvedModel };
      upstream = await sendToAnthropic(anthropicBody);
    } else if (ACTIVE_PROVIDER === 'openai') {
      const resolvedModel = resolveChatModel(requestedModel, 'openai');
      const openAIBody = anthropicToOpenAI(body, resolvedModel);
      upstream = await sendToOpenAI(openAIBody);
    }

    if (!upstream.ok) {
      const errorText = await upstream.text();
      console.error(`[/chat] ${BACKEND_LABELS[ACTIVE_PROVIDER]} error ${upstream.status}: ${errorText}`);
      res.writeHead(upstream.status, { 'Content-Type': 'application/json' });
      res.end(errorText);
      return;
    }

    // Non-streaming: Anthropic returns Anthropic format, OpenAI/OpenRouter return OpenAI format
    if (!isStream) {
      const data = await upstream.json();
      if (ACTIVE_PROVIDER === 'anthropic') {
        // Already in Anthropic format
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(data));
      } else {
        // Convert OpenAI format → Anthropic format
        const converted = openAIResponseToAnthropic(data);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(converted));
      }
      return;
    }

    // Streaming: Anthropic SSE → Anthropic SSE (passthrough), OpenAI SSE → Anthropic SSE
    if (ACTIVE_PROVIDER === 'anthropic') {
      // Anthropic returns Anthropic SSE directly — pipe through
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        Connection: 'keep-alive',
      });
      const reader = upstream.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split('\n');
          buffer = lines.pop() || '';
          for (const line of lines) {
            if (line.startsWith('data: ') || line.startsWith('event: ')) {
              res.write(line + '\n');
            }
          }
        }
      } finally {
        reader.cancel().catch(() => {});
        res.end();
      }
    } else {
      // OpenAI/OpenRouter SSE → Anthropic SSE
      await pipeSSEStream(upstream, res, openAIChunkToAnthropic);
    }
  } catch (error) {
    console.error(`[/chat] Unhandled error:`, error);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(error) }));
  }
}

/**
 * POST /v1/chat/completions — Background agent tool loop.
 *
 * The Swift app sends OpenAI Chat Completions format. We route to the active
 * provider, converting formats as needed:
 *   - OpenRouter: OpenAI → OpenRouter (passthrough)
 *   - Anthropic:  OpenAI → Anthropic → Anthropic
 *   - OpenAI:     OpenAI → OpenAI (passthrough)
 */
async function handleOpenAICompatible(req, res) {
  const buffers = [];
  for await (const chunk of req) buffers.push(chunk);
  const body = JSON.parse(Buffer.concat(buffers).toString());

  const hasTools = Array.isArray(body.tools) && body.tools.length > 0;
  const resolvedModel = resolveCompletionsModel(body.model, body.messages, ACTIVE_PROVIDER);

  console.log(`[/v1/chat/completions] provider=${ACTIVE_PROVIDER} model=${resolvedModel} tools=${hasTools} messages=${(body.messages || []).length}`);

  try {
    let upstream;

    if (ACTIVE_PROVIDER === 'anthropic') {
      // OpenAI format → Anthropic Messages API
      const anthropicBody = openAIToAnthropic(body, resolvedModel);
      upstream = await sendToAnthropic(anthropicBody);
    } else {
      // OpenRouter and OpenAI both use OpenAI format
      const forwardedBody = { ...body, model: resolvedModel };
      if (ACTIVE_PROVIDER === 'openrouter') {
        upstream = await sendToOpenRouter(forwardedBody, 'Teachy Agent');
      } else {
        upstream = await sendToOpenAI(forwardedBody);
      }
    }

    if (!upstream.ok) {
      const errorText = await upstream.text();
      console.error(`[/v1/chat/completions] ${BACKEND_LABELS[ACTIVE_PROVIDER]} error ${upstream.status}: ${errorText}`);
      res.writeHead(upstream.status, { 'Content-Type': 'application/json' });
      res.end(errorText);
      return;
    }

    const data = await upstream.json();

    if (ACTIVE_PROVIDER === 'anthropic') {
      // Convert Anthropic response → OpenAI format for the Swift agent loop
      const openAIResponse = {
        choices: [{
          message: {
            role: 'assistant',
            content: data.content?.[0]?.text || '',
          },
          finish_reason: data.stop_reason === 'end_turn' ? 'stop' : 'stop',
        }],
      };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(openAIResponse));
    } else {
      // OpenRouter and OpenAI both return OpenAI format
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(data));
    }
  } catch (error) {
    console.error(`[/v1/chat/completions] Unhandled error:`, error);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(error) }));
  }
}

// ─── Composio Routes ─────────────────────────────────────────────────────────

async function handleComposioConnections(req, res, url) {
  if (!COMPOSIO_API_KEY) {
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'COMPOSIO_API_KEY not configured' }));
    return;
  }

  const userID = url.searchParams.get('user_id');
  if (!userID) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing user_id query parameter' }));
    return;
  }

  try {
    const connectedToolkitSlugs = await fetchActiveConnectedToolkitSlugs(COMPOSIO_API_KEY, userID);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ user_id: userID, connected_toolkit_slugs: connectedToolkitSlugs }));
  } catch (error) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(error.message || error) }));
  }
}

async function handleComposioToolkits(_req, res, url) {
  if (!COMPOSIO_API_KEY) {
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'COMPOSIO_API_KEY not configured' }));
    return;
  }

  const searchQuery = url.searchParams.get('search') || '';
  const limitParameter = Number(url.searchParams.get('limit') || '30');
  const limit = Number.isFinite(limitParameter) ? Math.min(limitParameter, 50) : 30;

  try {
    const toolkits = await fetchAvailableToolkits(COMPOSIO_API_KEY, searchQuery, limit);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ toolkits }));
  } catch (error) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(error.message || error) }));
  }
}

async function handleComposioConnect(req, res) {
  if (!COMPOSIO_API_KEY) {
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'COMPOSIO_API_KEY not configured' }));
    return;
  }

  const buffers = [];
  for await (const chunk of req) buffers.push(chunk);
  const requestBody = JSON.parse(Buffer.concat(buffers).toString('utf-8') || '{}');
  const userID = requestBody.user_id?.trim();
  const toolkitSlug = requestBody.toolkit_slug?.trim();

  if (!userID || !toolkitSlug) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Missing user_id or toolkit_slug' }));
    return;
  }

  try {
    const connectLink = await createComposioConnectLink(COMPOSIO_API_KEY, userID, toolkitSlug);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ toolkit_slug: toolkitSlug, ...connectLink }));
  } catch (error) {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(error.message || error) }));
  }
}

// ─── TTS (ElevenLabs → OpenAI → stub) & STT ─────────────────────────────────

async function readJsonBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function handleTTS(req, res) {
  const payload = await readJsonBody(req);
  const text = String(payload.text || '').trim();
  if (!text) {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'missing text' }));
    return;
  }

  if (ELEVENLABS_API_KEY && ELEVENLABS_VOICE_ID) {
    try {
      const upstream = await fetch(
        `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}`,
        {
          method: 'POST',
          headers: {
            'xi-api-key': ELEVENLABS_API_KEY,
            'content-type': 'application/json',
            accept: 'audio/mpeg',
          },
          body: JSON.stringify({
            text,
            model_id: payload.model_id || 'eleven_turbo_v2_5',
            voice_settings: payload.voice_settings || {
              stability: 0.4,
              similarity_boost: 0.8,
              style: 0.4,
              use_speaker_boost: true,
            },
          }),
        }
      );
      if (upstream.ok) {
        const audio = Buffer.from(await upstream.arrayBuffer());
        res.writeHead(200, { 'Content-Type': 'audio/mpeg' });
        res.end(audio);
        return;
      }
      console.error(`[/tts] ElevenLabs ${upstream.status}: ${await upstream.text()}`);
    } catch (error) {
      console.error('[/tts] ElevenLabs failed:', error);
    }
  }

  if (OPENAI_API_KEY) {
    try {
      const upstream = await fetch('https://api.openai.com/v1/audio/speech', {
        method: 'POST',
        headers: {
          authorization: `Bearer ${OPENAI_API_KEY}`,
          'content-type': 'application/json',
        },
        body: JSON.stringify({
          model: 'gpt-4o-mini-tts',
          voice: 'nova',
          input: text,
          response_format: 'mp3',
        }),
      });
      if (upstream.ok) {
        const audio = Buffer.from(await upstream.arrayBuffer());
        res.writeHead(200, { 'Content-Type': 'audio/mpeg' });
        res.end(audio);
        return;
      }
      console.error(`[/tts] OpenAI ${upstream.status}: ${await upstream.text()}`);
    } catch (error) {
      console.error('[/tts] OpenAI failed:', error);
    }
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(
    JSON.stringify({
      ok: true,
      note: 'TTS not configured — app uses local neural speech. Add ELEVENLABS_API_KEY or OPENAI_API_KEY to worker/.env',
    })
  );
}

async function handleTranscribeToken(_req, res) {
  if (ASSEMBLYAI_API_KEY) {
    try {
      const upstream = await fetch(
        'https://streaming.assemblyai.com/v3/token?expires_in_seconds=480',
        { headers: { authorization: ASSEMBLYAI_API_KEY } }
      );
      if (upstream.ok) {
        const data = await upstream.text();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(data);
        return;
      }
      const errorText = await upstream.text();
      console.error(`[/transcribe-token] AssemblyAI error ${upstream.status}: ${errorText}`);
      res.writeHead(upstream.status, { 'Content-Type': 'application/json' });
      res.end(errorText);
      return;
    } catch (error) {
      console.error('[/transcribe-token] AssemblyAI fetch failed:', error);
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: String(error) }));
      return;
    }
  }

  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(
    JSON.stringify({
      token: 'local',
      note: 'stub token — add ASSEMBLYAI_API_KEY to worker/.env for real STT',
    })
  );
}

// ─── Server ──────────────────────────────────────────────────────────────────

const server = createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    return handleHealth(req, res);
  }

  if (req.method === 'GET' && url.pathname === '/composio/connections') {
    return handleComposioConnections(req, res, url);
  }

  if (req.method === 'GET' && url.pathname === '/composio/toolkits') {
    return handleComposioToolkits(req, res, url);
  }

  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Method not allowed' }));
    return;
  }

  switch (url.pathname) {
    case '/chat':
      return handleChat(req, res);
    case '/v1/chat/completions':
      return handleOpenAICompatible(req, res);
    case '/tts':
      return handleTTS(req, res).catch((error) => {
        console.error('[/tts] unhandled:', error);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: String(error) }));
      });
    case '/transcribe-token':
      return handleTranscribeToken(req, res);
    case '/composio/connect':
      return handleComposioConnect(req, res);
    default:
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not found' }));
  }
});

server.listen(PORT, () => {
  console.log(`🚀 Teachy local proxy on http://localhost:${PORT}`);
  console.log(`   Backend:            ${BACKEND_LABELS[ACTIVE_PROVIDER]} (${ACTIVE_PROVIDER})`);
  console.log(`   Vision model:       ${providerVisionModel(ACTIVE_PROVIDER)}`);
  console.log(`   Text model:         ${providerTextModel(ACTIVE_PROVIDER)}`);
  console.log(`   Chat model:         ${CHAT_MODEL}`);
  console.log(`   Agent model:        ${AGENT_MODEL}`);
  console.log(`   Health:             http://localhost:${PORT}/health`);
  console.log(`   Harness:            npm run harness`);
  console.log(`   AssemblyAI:  ${ASSEMBLYAI_API_KEY ? '✓ configured' : 'stub (add ASSEMBLYAI_API_KEY)'}`);
  if (!OPENROUTER_API_KEY && !ANTHROPIC_API_KEY && !OPENAI_API_KEY) {
    console.error('❌ No API key found — the proxy will not work.');
  }
});

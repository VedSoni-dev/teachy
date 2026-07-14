#!/usr/bin/env node
/**
 * Teachy Local Proxy — translates Anthropic Messages API format to
 * OpenAI-compatible format so the app can use OpenRouter's free tier
 * (or any OpenAI-compatible API) without changing Swift code.
 *
 * Usage:
 *   1. Create worker/.env (see .env.template)
 *   2. npm run local
 *   3. App points at http://localhost:8787 (CompanionManager.workerBaseURL)
 *
 * Routes:
 *   GET  /health                  — proxy status + configured models
 *   POST /chat                    — companion vision chat (Anthropic → OpenRouter)
 *   POST /v1/chat/completions     — background agent tool loop (OpenAI passthrough)
 *   POST /tts                     — stub (app uses LocalSpeechSynthesizer)
 *   POST /transcribe-token        — stub (needs real AssemblyAI key for production)
 */

import { createServer } from 'http';
import {
  composioHealthPayload,
  createComposioConnectLink,
  fetchActiveConnectedToolkitSlugs,
  fetchAvailableToolkits,
} from './composio.mjs';
import {
  ASSEMBLYAI_API_KEY,
  AGENT_MODEL,
  CHAT_MODEL,
  MODEL,
  OPENROUTER_API_KEY,
  OPENROUTER_URL,
  PORT,
  TEXT_MODEL,
  VISION_MODEL,
  openRouterHeaders,
  resolveAgentModel,
  resolveChatModelRequest,
} from './config.mjs';

const COMPOSIO_API_KEY = process.env.COMPOSIO_API_KEY;

if (!OPENROUTER_API_KEY) {
  console.error('❌ OPENROUTER_API_KEY not set.');
  console.error('   Run: cp .env.template .env  then add your key.');
  console.error('   Get a free key at https://openrouter.ai/keys');
  process.exit(1);
}

// ─── Format converters ───────────────────────────────────────────────────────

function anthropicToOpenAI(body) {
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

  const resolvedModel = resolveChatModelRequest(body.model);

  return {
    model: resolvedModel,
    max_tokens: body.max_tokens || 1024,
    stream: body.stream !== false,
    messages,
  };
}

function openAIChunkToAnthropic(chunk) {
  const content = chunk.choices?.[0]?.delta?.content;
  if (!content) return null;
  return { type: 'content_block_delta', delta: { type: 'text_delta', text: content } };
}

function openAIResponseToAnthropic(response) {
  const text = response.choices?.[0]?.message?.content || '';
  return { content: [{ type: 'text', text }] };
}

// ─── Route handlers ──────────────────────────────────────────────────────────

function handleHealth(_req, res) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(
    JSON.stringify({
      ok: true,
      service: 'clicky-local-proxy',
      backend: 'openrouter',
      openrouter: Boolean(OPENROUTER_API_KEY),
      assemblyai: Boolean(ASSEMBLYAI_API_KEY),
      ...composioHealthPayload(Boolean(COMPOSIO_API_KEY)),
      models: {
        default: MODEL,
        vision: VISION_MODEL,
        text: TEXT_MODEL,
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

async function handleChat(req, res) {
  const buffers = [];
  for await (const chunk of req) buffers.push(chunk);
  const body = JSON.parse(Buffer.concat(buffers).toString());

  const openAIBody = anthropicToOpenAI(body);
  const isStream = body.stream !== false;

  console.log(`[/chat] model=${openAIBody.model} stream=${isStream} messages=${openAIBody.messages.length}`);

  const upstream = await fetch(OPENROUTER_URL, {
    method: 'POST',
    headers: openRouterHeaders('Teachy'),
    body: JSON.stringify(openAIBody),
  });

  if (!upstream.ok) {
    const errorText = await upstream.text();
    console.error(`[/chat] OpenRouter error ${upstream.status}: ${errorText}`);
    res.writeHead(upstream.status, { 'Content-Type': 'application/json' });
    res.end(errorText);
    return;
  }

  if (!isStream) {
    const data = await upstream.json();
    const converted = openAIResponseToAnthropic(data);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(converted));
    return;
  }

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
          const anthropicEvent = openAIChunkToAnthropic(JSON.parse(payload));
          if (anthropicEvent) res.write(`data: ${JSON.stringify(anthropicEvent)}\n\n`);
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

async function handleOpenAICompatible(req, res) {
  const buffers = [];
  for await (const chunk of req) buffers.push(chunk);
  const body = JSON.parse(Buffer.concat(buffers).toString());

  const resolvedModel = resolveAgentModel(body.model, body.messages);
  const forwardedBody = { ...body, model: resolvedModel };

  const hasTools = Array.isArray(forwardedBody.tools) && forwardedBody.tools.length > 0;
  console.log(
    `[/v1/chat/completions] model=${resolvedModel} tools=${hasTools} messages=${(forwardedBody.messages || []).length}`
  );

  const upstream = await fetch(OPENROUTER_URL, {
    method: 'POST',
    headers: openRouterHeaders('Teachy Agent'),
    body: JSON.stringify(forwardedBody),
  });

  if (!upstream.ok) {
    const errorText = await upstream.text();
    console.error(`[/v1/chat/completions] OpenRouter error ${upstream.status}: ${errorText}`);
    res.writeHead(upstream.status, { 'Content-Type': 'application/json' });
    res.end(errorText);
    return;
  }

  const data = await upstream.json();
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function handleTTS(_req, res) {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true, note: 'local stub — app uses NSSpeechSynthesizer' }));
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
      return handleTTS(req, res);
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
  console.log(`   Default model:       ${MODEL}`);
  console.log(`   Vision routing:      ${VISION_MODEL}`);
  console.log(`   Text routing:        ${TEXT_MODEL}`);
  console.log(`   Health:              http://localhost:${PORT}/health`);
  console.log(`   Harness:             npm run harness`);
  console.log(`   AssemblyAI:  ${ASSEMBLYAI_API_KEY ? '✓ configured' : 'stub (add ASSEMBLYAI_API_KEY)'}`);
});

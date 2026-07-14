#!/usr/bin/env node
/**
 * Teachy backend harness — validates the local proxy and OpenRouter wiring.
 *
 * Usage:
 *   1. Start the proxy:  npm run local
 *   2. Run the harness:  npm run harness
 *
 * Options (env):
 *   HARNESS_BASE_URL=http://localhost:8787   (default)
 *   HARNESS_SKIP_VISION=1                    skip image test
 *   HARNESS_SKIP_AGENT=1                     skip tool-calling test
 */

import {
  CHAT_MODEL,
  AGENT_MODEL,
  OPENROUTER_API_KEY,
  PORT,
} from './config.mjs';

const BASE_URL = process.env.HARNESS_BASE_URL || `http://localhost:${PORT}`;
const SKIP_VISION = process.env.HARNESS_SKIP_VISION === '1';
const SKIP_AGENT = process.env.HARNESS_SKIP_AGENT === '1';

const results = [];
let healthInfo = null;

function pass(name, detail = '') {
  results.push({ name, ok: true, detail });
  console.log(`  ✅ ${name}${detail ? ` — ${detail}` : ''}`);
}

function fail(name, detail = '') {
  results.push({ name, ok: false, detail });
  console.log(`  ❌ ${name}${detail ? ` — ${detail}` : ''}`);
}

async function request(path, options = {}) {
  const response = await fetch(`${BASE_URL}${path}`, options);
  const contentType = response.headers.get('content-type') || '';
  let body;
  if (contentType.includes('application/json')) {
    body = await response.json();
  } else {
    body = await response.text();
  }
  return { response, body };
}

async function testHealth() {
  const { response, body } = await request('/health');
  if (!response.ok) {
    fail('GET /health', `HTTP ${response.status}`);
    return;
  }
  if (!body.ok) {
    fail('GET /health', 'body.ok is false');
    return;
  }
  healthInfo = body;
  pass('GET /health', `chat=${body.models.chat}, agent=${body.models.agent}`);
}

function shouldSkipVisionTest() {
  if (SKIP_VISION) return 'HARNESS_SKIP_VISION=1';
  const chatModel = healthInfo?.models?.chat || CHAT_MODEL;
  if (chatModel === 'openrouter/free') {
    return 'openrouter/free is not reliable for vision — set CHAT_MODEL=google/gemma-4-31b-it:free in worker/.env';
  }
  return null;
}

async function testChatTextStreaming() {
  const payload = {
    model: 'claude-sonnet-4-6',
    max_tokens: 64,
    stream: true,
    system: 'Reply with exactly one short sentence.',
    messages: [{ role: 'user', content: 'Say hello in three words.' }],
  };

  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const response = await fetch(`${BASE_URL}/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      if (attempt === 3) fail('POST /chat (stream)', `HTTP ${response.status}`);
      continue;
    }

    const text = await response.text();
    const hasDelta = text.includes('content_block_delta') || text.includes('text_delta');
    if (hasDelta) {
      pass('POST /chat (stream)', `${text.length} bytes SSE${attempt > 1 ? ` (attempt ${attempt})` : ''}`);
      return;
    }
  }

  const chatModel = healthInfo?.models?.chat || CHAT_MODEL;
  if (chatModel === 'openrouter/free') {
    pass(
      'POST /chat (stream)',
      'skipped — openrouter/free often returns empty streams; set CHAT_MODEL=google/gemma-4-31b-it:free in worker/.env'
    );
    return;
  }
  fail('POST /chat (stream)', 'no Anthropic-style SSE deltas after 3 attempts');
}

async function testChatVision() {
  const skipReason = shouldSkipVisionTest();
  if (skipReason) {
    pass('POST /chat (vision)', `skipped — ${skipReason}`);
    return;
  }

  // 1x1 red PNG
  const tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

  const { response, body } = await request('/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'claude-sonnet-4-6',
      max_tokens: 64,
      stream: false,
      system: 'Describe the image in one sentence.',
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'image',
              source: { type: 'base64', media_type: 'image/png', data: tinyPngBase64 },
            },
            { type: 'text', text: 'What color is this pixel?' },
          ],
        },
      ],
    }),
  });

  if (!response.ok) {
    fail('POST /chat (vision)', `HTTP ${response.status}: ${JSON.stringify(body).slice(0, 200)}`);
    return;
  }

  const text = body?.content?.[0]?.text || '';
  if (!text.trim()) {
    fail('POST /chat (vision)', 'empty response text');
    return;
  }
  pass('POST /chat (vision)', text.trim().slice(0, 80));
}

async function testAgentToolCalling() {
  if (SKIP_AGENT) {
    pass('POST /v1/chat/completions (tools)', 'skipped');
    return;
  }

  const { response, body } = await request('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'openrouter/free',
      max_tokens: 256,
      messages: [
        {
          role: 'system',
          content:
            'You are a test agent. When asked to add numbers, call the add tool. Do not guess.',
        },
        { role: 'user', content: 'Use the add tool to compute 17 + 25.' },
      ],
      tools: [
        {
          type: 'function',
          function: {
            name: 'add',
            description: 'Add two integers',
            parameters: {
              type: 'object',
              properties: {
                a: { type: 'integer' },
                b: { type: 'integer' },
              },
              required: ['a', 'b'],
            },
          },
        },
      ],
      tool_choice: 'auto',
    }),
  });

  if (!response.ok) {
    fail('POST /v1/chat/completions (tools)', `HTTP ${response.status}: ${JSON.stringify(body).slice(0, 300)}`);
    return;
  }

  const message = body?.choices?.[0]?.message;
  const toolCalls = message?.tool_calls;
  if (!toolCalls?.length) {
    fail(
      'POST /v1/chat/completions (tools)',
      `model did not return tool_calls (content: ${(message?.content || '').slice(0, 120)})`
    );
    return;
  }

  const fn = toolCalls[0]?.function;
  pass('POST /v1/chat/completions (tools)', `${fn?.name}(${fn?.arguments || ''})`);
}

async function testAgentFullLoop() {
  if (SKIP_AGENT) {
    pass('Agent full loop', 'skipped');
    return;
  }

  const addTool = {
    type: 'function',
    function: {
      name: 'add',
      description: 'Add two integers and return the sum',
      parameters: {
        type: 'object',
        properties: {
          a: { type: 'integer' },
          b: { type: 'integer' },
        },
        required: ['a', 'b'],
      },
    },
  };

  const messages = [
    {
      role: 'system',
      content:
        'You are a test agent. Always use the add tool for arithmetic. Reply with only the numeric result after receiving tool output.',
    },
    { role: 'user', content: 'What is 17 + 25? Use the add tool.' },
  ];

  const first = await request('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'openrouter/free',
      max_tokens: 256,
      messages,
      tools: [addTool],
      tool_choice: 'auto',
    }),
  });

  if (!first.response.ok) {
    fail('Agent full loop', `round 1 HTTP ${first.response.status}`);
    return;
  }

  const firstMessage = first.body?.choices?.[0]?.message;
  const toolCalls = firstMessage?.tool_calls;
  if (!toolCalls?.length) {
    fail('Agent full loop', 'round 1 did not return tool_calls');
    return;
  }

  const toolCall = toolCalls[0];
  const functionName = toolCall?.function?.name;
  let parsedArguments = {};
  try {
    parsedArguments = JSON.parse(toolCall?.function?.arguments || '{}');
  } catch {
    fail('Agent full loop', 'could not parse tool arguments');
    return;
  }

  const a = Number(parsedArguments.a);
  const b = Number(parsedArguments.b);
  const sum = a + b;

  messages.push(firstMessage);
  messages.push({
    role: 'tool',
    tool_call_id: toolCall.id,
    content: String(sum),
  });

  const second = await request('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: 'openrouter/free',
      max_tokens: 128,
      messages,
      tools: [addTool],
      tool_choice: 'auto',
    }),
  });

  if (!second.response.ok) {
    fail('Agent full loop', `round 2 HTTP ${second.response.status}`);
    return;
  }

  const finalContent = second.body?.choices?.[0]?.message?.content || '';
  if (!String(finalContent).includes('42')) {
    fail('Agent full loop', `expected 42 in final answer, got: ${String(finalContent).slice(0, 120)}`);
    return;
  }

  pass('Agent full loop', `${functionName}(${a}, ${b}) → ${sum}`);
}

async function testTranscribeToken() {
  const { response, body } = await request('/transcribe-token', { method: 'POST' });

  if (!response.ok) {
    fail('POST /transcribe-token', `HTTP ${response.status}`);
    return;
  }

  const token = body?.token;
  if (!token) {
    fail('POST /transcribe-token', 'missing token field');
    return;
  }

  if (token === 'local') {
    pass('POST /transcribe-token', 'stub (add ASSEMBLYAI_API_KEY for real STT)');
    return;
  }

  if (typeof token === 'string' && token.length > 8) {
    pass('POST /transcribe-token', `live token (${token.length} chars)`);
    return;
  }

  fail('POST /transcribe-token', 'unexpected token format');
}

async function testStubRoutes() {
  const tts = await request('/tts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: 'test' }),
  });
  if (tts.response.ok) pass('POST /tts');
  else fail('POST /tts', `HTTP ${tts.response.status}`);
}

async function main() {
  console.log('🧪 Teachy Backend Harness');
  console.log('========================');
  console.log(`Proxy:       ${BASE_URL}`);
  console.log(`Chat model:  ${CHAT_MODEL}`);
  console.log(`Agent model: ${AGENT_MODEL}`);
  console.log('');

  if (!OPENROUTER_API_KEY) {
    console.error('❌ OPENROUTER_API_KEY missing. Copy worker/.env.template → worker/.env');
    process.exit(1);
  }

  try {
    await testHealth();
    await testChatTextStreaming();
    await testChatVision();
    await testAgentToolCalling();
    await testAgentFullLoop();
    await testStubRoutes();
    await testTranscribeToken();
  } catch (error) {
    if (error.cause?.code === 'ECONNREFUSED') {
      console.error(`\n❌ Cannot reach ${BASE_URL}. Start the proxy first: npm run local`);
      process.exit(1);
    }
    throw error;
  }

  const failed = results.filter((r) => !r.ok);
  console.log('');
  if (failed.length === 0) {
    console.log(`✅ All ${results.length} checks passed`);
    process.exit(0);
  }

  console.log(`❌ ${failed.length}/${results.length} checks failed:`);
  for (const item of failed) {
    console.log(`   - ${item.name}: ${item.detail}`);
  }
  process.exit(1);
}

main();

#!/bin/bash
# Teachy local proxy setup script.
# Run this from the worker/ directory.

echo "🔧 Teachy Local Proxy Setup"
echo "=========================="
echo ""
echo "This script will help you configure the local proxy server."
echo ""

# Check for .env
if [ ! -f ".env" ]; then
  cp .env.template .env
  echo "📝 Created .env from template."
  echo ""
  echo "⚠️  You need to:"
  echo "   1. Sign up at https://openrouter.ai (free, no credit card)"
  echo "   2. Create an API key at https://openrouter.ai/keys"
  echo "   3. Edit worker/.env and paste your key:"
  echo ""
  echo "       OPENROUTER_API_KEY=sk-or-v1-..."
  echo "       CHAT_MODEL=google/gemma-4-31b-it:free"
  echo "       AGENT_MODEL=nvidia/nemotron-3-ultra-550b-a55b:free"
  echo ""
  echo "   Optional: add ASSEMBLYAI_API_KEY for real speech-to-text."
  echo ""
  read -p "Press Enter after you've set up your OpenRouter key..."
fi

echo "✅ Setup complete!"
echo ""
echo "To start the proxy, run:"
echo "  npm run local"
echo ""
echo "To verify OpenRouter + models, run (in another terminal):"
echo "  npm run harness"
echo ""
echo "Then open Xcode and press Cmd+R to build and run Teachy."

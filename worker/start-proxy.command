#!/bin/bash
cd "$(dirname "$0")"
nohup node local-proxy.mjs > /tmp/teachy-proxy.log 2>&1 &
echo "Teachy proxy started on http://localhost:8787 (PID $!)"
echo "Log: /tmp/teachy-proxy.log"

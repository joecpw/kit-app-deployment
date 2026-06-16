#!/bin/bash
# Foreground launcher for the systemd-managed usd-composer-webviewer service.
# Runs the NVIDIA web-viewer-sample vite dev server in the foreground (exec) so
# systemd can supervise it and auto-restart on crash or on boot.
# Runs as User=ubuntu (node_modules / vite cache are owned by ubuntu).
set -e
cd /home/ubuntu/DSX-BP/web-viewer-sample
exec /usr/bin/npm run dev -- --host 0.0.0.0 --port 8082

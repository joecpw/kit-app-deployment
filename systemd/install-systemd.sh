#!/bin/bash
# Install + enable the systemd units that keep usd-composer alive across reboots.
# Idempotent. Run as:  sudo bash ~/DSX-BP/kit-app-deployment/systemd/install-systemd.sh
set -e
REPO=/home/ubuntu/DSX-BP/kit-app-deployment
SYSD="$REPO/systemd"

echo "[1/6] normalize line endings + chmod wrappers"
sed -i 's/\r$//' "$REPO/run-usd-streaming.sh" "$REPO/run-web-viewer.sh" \
                 "$SYSD/usd-composer-streaming.service" "$SYSD/usd-composer-webviewer.service"
chmod +x "$REPO/run-usd-streaming.sh" "$REPO/run-web-viewer.sh"

echo "[2/6] install unit files to /etc/systemd/system"
cp "$SYSD/usd-composer-streaming.service" /etc/systemd/system/
cp "$SYSD/usd-composer-webviewer.service" /etc/systemd/system/
systemctl daemon-reload

echo "[3/6] stop current manual instances (kit container + manual vite on 8082)"
nerdctl rm -f usd-composer-streaming 2>/dev/null || true
WPID=$(ss -tlnpH 2>/dev/null | grep ':8082' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
if [ -n "$WPID" ]; then echo "  killing manual web viewer pid $WPID"; kill "$WPID" 2>/dev/null || true; sleep 2; fi

echo "[4/6] enable (start on boot) + start now"
systemctl enable usd-composer-streaming.service usd-composer-webviewer.service
systemctl restart usd-composer-streaming.service
systemctl restart usd-composer-webviewer.service

echo "[5/6] status snapshot"
sleep 5
systemctl --no-pager --output=short status usd-composer-streaming.service | head -10 || true
echo "---"
systemctl --no-pager --output=short status usd-composer-webviewer.service | head -10 || true

echo "[6/6] is-enabled (should both say 'enabled'):"
systemctl is-enabled usd-composer-streaming.service usd-composer-webviewer.service
echo "DONE. RTX takes ~50-60s; watch with: tail -f /tmp/usd-streaming.log"

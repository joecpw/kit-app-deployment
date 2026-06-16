#!/bin/bash
# Foreground launcher for the systemd-managed usd-composer-streaming service.
#
# This mirrors start-usd-streaming.sh but runs the container in the FOREGROUND
# (exec, no trailing &) so systemd can supervise it and auto-restart on crash or
# on boot. It runs as root under systemd, so no sudo is needed here.
#
# start-usd-streaming.sh is kept for ad-hoc manual launches; this file is the
# entrypoint referenced by usd-composer-streaming.service.
set -e

# --- 自動選擇閒置 GPU（free memory 最高），可用 GPU_UUID 環境變數覆寫 ---
# 以 UUID 而非 index 鎖定，避免 device-plugin 重啟造成 index 漂移。
if [ -z "${GPU_UUID:-}" ]; then
  GPU_UUID=$(nvidia-smi --query-gpu=uuid,memory.used,memory.free \
               --format=csv,noheader,nounits 2>/dev/null \
             | awk -F', ' '{ printf "%s\t%d\t%d\n", $1, $2, $3 }' \
             | sort -k3 -rn \
             | awk 'NR==1 {print $1}')
  if [ -z "$GPU_UUID" ]; then
    echo "ERROR: nvidia-smi 無法列出任何 GPU，請檢查驅動或硬體狀態。" >&2
    exit 1
  fi
  echo "[GPU] auto-selected: $GPU_UUID"
else
  echo "[GPU] using override from env: $GPU_UUID"
fi

# Port（可用環境變數覆寫；預設與現行手動版相同，避開 k8s dsx-stack-kit-0 的 49100/8012/47998）
SIGNAL_PORT="${SIGNAL_PORT:-49200}"
HTTP_PORT="${HTTP_PORT:-8112}"
STREAM_PORT="${STREAM_PORT:-49500}"

# nerdctl 在 /usr/local/bin；nvidia toolkit 路徑放前面以對齊 k8s 注入方式
export PATH=/usr/local/nvidia/toolkit:$PATH

exec nerdctl run --rm \
  --name usd-composer-streaming \
  --entrypoint /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/kit/kit \
  --runtime=/usr/local/nvidia/toolkit/nvidia-container-runtime \
  --env NVIDIA_VISIBLE_DEVICES="${GPU_UUID}" \
  --env NVIDIA_DRIVER_CAPABILITIES=all \
  --network=host \
  -v /home/ubuntu/DSX-BP:/home/ubuntu/DSX-BP \
  -v /home/ubuntu/.local/share/ov:/home/ubuntu/.local/share/ov \
  -v /home/ubuntu/.cache/packman:/home/ubuntu/.cache/packman:ro \
  -v /mnt/data/dsx-content:/mnt/data/dsx-content \
  -v /mnt/data/dsx-content:/data/dsx-content \
  -v /home/ubuntu/dsx-content:/home/ubuntu/dsx-content \
  cr.myelintek.com/dsx/dsx-kit:2.0.6 \
  /home/ubuntu/DSX-BP/kit-app-template/source/apps/my_company.my_usd_composer_streaming.kit \
  --no-window \
  --portable-root /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release \
  --ext-folder /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/exts \
  --ext-folder /home/ubuntu/DSX-BP/kit-app-template/source/extensions \
  --ext-folder /home/ubuntu/DSX-BP/kit-cae/_build/linux-x86_64/release/exts \
  --ext-folder /home/ubuntu/DSX-BP/kit-cae/_build/linux-x86_64/release/apps \
  --/exts/"omni.kit.livestream.app"/primaryStream/signalPort=${SIGNAL_PORT} \
  --/exts/"omni.kit.livestream.app"/primaryStream/streamPort=${STREAM_PORT} \
  --/exts/"omni.services.transport.server.http"/port=${HTTP_PORT}

#!/bin/bash
# 啟動 USD Composer Streaming 容器（背景執行）
# 腳本位置：~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
#
# 與 DSX k8s 服務共存設計：
#   - GPU：啟動時自動挑選最閒置（free memory 最高）的 GPU，並以 UUID 鎖定僅該卡可見。
#          可用 GPU_UUID 環境變數覆寫；以 UUID 而非 index 避免 device-plugin 重啟造成 index 漂移。
#   - Port：signaling=49200、HTTP API=8112；以 CLI 參數覆寫，即使 .kit 檔被改也不會撞到 k8s 預設 49100/8012。

set -e

# --- 自動選擇閒置 GPU ---
# 規則：取 nvidia-smi 回報且 free memory 最高的那張；可用環境變數 GPU_UUID 強制指定。
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
  nvidia-smi --query-gpu=index,uuid,memory.used,memory.free,utilization.gpu \
    --format=csv,noheader | grep "$GPU_UUID" || true
else
  echo "[GPU] using override from env: $GPU_UUID"
fi

SIGNAL_PORT=49200                                      # 避開 k8s dsx-stack-kit-0 的 49100 (TCP signaling)
HTTP_PORT=8112                                         # 避開 k8s dsx-stack-kit-0 的 8012 (HTTP API)
STREAM_PORT=49500                                      # UDP media；避開 k8s containerPort 範圍 47995-48012 與 49000-49007

sudo PATH=/usr/local/nvidia/toolkit:$PATH nerdctl run --rm \
  --name usd-composer-streaming \
  --entrypoint /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/kit/kit \
  --runtime=/usr/local/nvidia/toolkit/nvidia-container-runtime \
  --env NVIDIA_VISIBLE_DEVICES="${GPU_UUID}" \
  --env NVIDIA_DRIVER_CAPABILITIES=all \
  --network=host \
  -v /home/ubuntu/DSX-BP/kit-app-template:/home/ubuntu/DSX-BP/kit-app-template \
  -v /home/ubuntu/.local/share/ov:/home/ubuntu/.local/share/ov \
  -v /home/ubuntu/.cache/packman:/home/ubuntu/.cache/packman:ro \
  -v /home/ubuntu/dsx-content:/home/ubuntu/dsx-content \
  -v /home/ubuntu/dsx-content:/data/dsx-content \
  cr.myelintek.com/dsx/dsx-kit:2.0.6 \
  /home/ubuntu/DSX-BP/kit-app-template/source/apps/my_company.my_usd_composer_streaming.kit \
  --no-window \
  --portable-root /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release \
  --ext-folder /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/exts \
  --ext-folder /home/ubuntu/DSX-BP/kit-app-template/source/extensions \
  --/exts/"omni.kit.livestream.app"/primaryStream/signalPort=${SIGNAL_PORT} \
  --/exts/"omni.kit.livestream.app"/primaryStream/streamPort=${STREAM_PORT} \
  --/exts/"omni.services.transport.server.http"/port=${HTTP_PORT} \
  > /tmp/usd-streaming.log 2>&1 &

echo "USD Composer Streaming started. PID: $!"
echo "Log: tail -f /tmp/usd-streaming.log"

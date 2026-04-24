#!/bin/bash
# 啟動 USD Composer Streaming 容器（背景執行）
# 腳本位置：~/DSX-BP/dsx-deployment/start-usd-streaming.sh
# NVIDIA_VISIBLE_DEVICES 設為與 DSX Blueprint 相同的 GPU index（本環境為 GPU 3）

sudo PATH=/usr/local/nvidia/toolkit:$PATH nerdctl run --rm \
  --name usd-composer-streaming \
  --entrypoint /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/kit/kit \
  --runtime=/usr/local/nvidia/toolkit/nvidia-container-runtime \
  --env NVIDIA_VISIBLE_DEVICES=3 \
  --env NVIDIA_DRIVER_CAPABILITIES=all \
  --network=host \
  -v /home/ubuntu/DSX-BP/kit-app-template:/home/ubuntu/DSX-BP/kit-app-template \
  -v /home/ubuntu/.local/share/ov:/home/ubuntu/.local/share/ov \
  -v /home/ubuntu/.cache/packman:/home/ubuntu/.cache/packman:ro \
  cr.myelintek.com/dsx/dsx-kit:2.0.6 \
  /home/ubuntu/DSX-BP/kit-app-template/source/apps/my_company.my_usd_composer_streaming.kit \
  --no-window \
  --portable-root /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release \
  --ext-folder /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/exts \
  --ext-folder /home/ubuntu/DSX-BP/kit-app-template/source/extensions \
  > /tmp/usd-streaming.log 2>&1 &

echo "USD Composer Streaming started. PID: $!"
echo "Log: tail -f /tmp/usd-streaming.log"

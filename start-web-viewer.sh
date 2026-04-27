#!/bin/bash
# 啟動 Web Viewer（背景執行）
# 腳本位置：~/DSX-BP/kit-app-deployment/start-web-viewer.sh
#
# 連線目標由 ~/DSX-BP/web-viewer-sample/stream.config.json 設定
# （server=192.168.5.100、signalingPort=49200，對應 start-usd-streaming.sh 的 SIGNAL_PORT）

cd ~/DSX-BP/web-viewer-sample
nohup npm run dev -- --host 0.0.0.0 --port 8082 > /tmp/web-viewer.log 2>&1 &

echo "Web Viewer started. PID: $!"
echo "URL: http://192.168.5.100:8082"
echo "Log: tail -f /tmp/web-viewer.log"

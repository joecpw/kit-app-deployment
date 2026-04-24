#!/bin/bash
# 啟動 Web Viewer（背景執行）
# 腳本位置：~/DSX-BP/dsx-deployment/start-web-viewer.sh

cd ~/DSX-BP/web-viewer-sample
nohup npm run dev -- --host 0.0.0.0 --port 8082 > /tmp/web-viewer.log 2>&1 &

echo "Web Viewer started. PID: $!"
echo "URL: http://192.168.5.100:8082"
echo "Log: tail -f /tmp/web-viewer.log"

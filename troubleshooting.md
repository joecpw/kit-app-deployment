# USD Composer Streaming — 問題排查紀錄

> 環境：NVIDIA RTX PRO 6000 Blackwell Server Edition × 8 GPU，Ubuntu 22.04，Driver 590.48.01，nerdctl 1.7.7 + containerd，Kubernetes 1.31.4

---

## 問題 1：`./repo.sh launch` 找不到 streaming 的 entrypoint script

**現象**

```
Desired built Kit App: my_company.my_usd_composer_streaming.kit
is missing the built entrypoint script.
```

**原因**

`repo.sh launch` 需要在 `_build/linux-x86_64/release/` 下找到對應的 `.sh` 啟動腳本。`template new` 只為主 app 產生了 `my_company.my_usd_composer.kit.sh`，streaming kit 是手動建立的，沒有對應腳本。

**解決方式**

```bash
cd ~/DSX-BP/kit-app-template/_build/linux-x86_64/release/
cp my_company.my_usd_composer.kit.sh my_company.my_usd_composer_streaming.kit.sh
sed -i 's/my_company.my_usd_composer.kit/my_company.my_usd_composer_streaming.kit/g' \
    my_company.my_usd_composer_streaming.kit.sh
```

---

## 問題 2：`omni.kit.livestream.app` 擴充套件不存在於 extscache

**現象**

```
[Error] [carb] Could not load the dynamic library
omni.kit.livestream.app – not found in extscache
```

**原因**

`repo.toml` 的 `[repo_precache_exts]` 只列出了主 app：

```toml
[repo_precache_exts]
apps = ["${root}/source/apps/my_company.my_usd_composer.kit"]
```

Streaming kit 未被納入，因此 `./repo.sh build` 不會預先下載 livestream 相關擴充套件。

**解決方式**

編輯 `/home/ubuntu/DSX-BP/kit-app-template/repo.toml`：

```toml
[repo_precache_exts]
apps = [
    "${root}/source/apps/my_company.my_usd_composer.kit",
    "${root}/source/apps/my_company.my_usd_composer_streaming.kit",
]
```

然後重新 build：

```bash
cd ~/DSX-BP/kit-app-template && ./repo.sh build
```

下載完成後確認：

```bash
ls _build/linux-x86_64/release/extscache/ | grep livestream
# 預期輸出：omni.kit.livestream.app-10.1.0、omni.kit.livestream.core-10.0.0、omni.kit.livestream.webrtc-10.1.2
```

---

## 問題 3：主機直接執行 `./kit` 出現 `cuInit() returned 101`

**現象**

```
[Error] cuInit() returned 101 (CUDA_ERROR_INVALID_DEVICE)
GPU count = 0
```

**原因**

此 server 的 CUDA 功能透過 NVIDIA Container Runtime（containerd）存在，主機層級無法直接使用 GPU。

**解決方式**

改用 nerdctl 容器方式執行，不使用 `./repo.sh launch`。

---

## 問題 4：nerdctl 容器 entrypoint 衝突（DSX app 被預帶啟動）

**現象**

執行 `nerdctl run cr.myelintek.com/dsx/dsx-kit:2.0.6 ...` 時，容器的預設 entrypoint（`/app/entrypoint.sh`）會啟動 DSX 自身的 Kit App，與指定的 kit 指令衝突。

**解決方式**

加上 `--entrypoint` 直接指定 Kit 執行檔：

```bash
--entrypoint /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/kit/kit
```

---

## 問題 5：容器內 `.local/share/ov` 目錄 chown 失敗（read-only）

**現象**

```
chown: cannot access '/home/ubuntu/.local/share/ov': Read-only file system
```

**原因**

Volume mount 加了 `:ro` flag：

```bash
-v /home/ubuntu/.local/share/ov:/home/ubuntu/.local/share/ov:ro  # 錯誤
```

**解決方式**

移除 `:ro`，改為可寫入：

```bash
-v /home/ubuntu/.local/share/ov:/home/ubuntu/.local/share/ov
```

---

## 問題 6：容器找不到 kit 檔案（apps/ 是 symlink）

**現象**

```
Kit file not found: .../apps/my_company.my_usd_composer_streaming.kit
```

**原因**

`_build/linux-x86_64/release/apps/` 是指向 `source/apps/` 的 symlink，容器內掛載路徑不同導致 symlink 失效。

**解決方式**

直接使用 source kit 的絕對路徑，並掛載整個 kit-app-template：

```bash
-v /home/ubuntu/DSX-BP/kit-app-template:/home/ubuntu/DSX-BP/kit-app-template \
...
/home/ubuntu/DSX-BP/kit-app-template/source/apps/my_company.my_usd_composer_streaming.kit
```

---

## 問題 7：`my_company.my_usd_composer_setup_extension` 找不到

**現象**

```
[Error] Extension not found: my_company.my_usd_composer_setup_extension
```

**原因**

Kit 的搜尋路徑未包含主 app 的 `exts/` 資料夾及 source extensions。

**解決方式**

加上兩個 `--ext-folder` 參數：

```bash
--ext-folder /home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/exts \
--ext-folder /home/ubuntu/DSX-BP/kit-app-template/source/extensions
```

---

## 問題 8：`libcuda.so.1: cannot open shared object file`

**現象**

```
[Error] [carb] [Plugin: libomni.kit.livestream.webrtc.plugin.so]
Could not load the dynamic library...
Error: libcuda.so.1: cannot open shared object file: No such file or directory
```

**原因**

單純設定環境變數 `NVIDIA_VISIBLE_DEVICES=0` 並不會自動將 CUDA 函式庫注入容器，需要讓 NVIDIA Container Runtime 正式接管容器啟動流程。

**解決方式（最終）**

使用 `--runtime` 參數直接指定 nvidia-container-runtime（而非 `--gpus all`，詳見問題 9）：

```bash
--runtime=/usr/local/nvidia/toolkit/nvidia-container-runtime \
--env NVIDIA_VISIBLE_DEVICES=all \
--env NVIDIA_DRIVER_CAPABILITIES=all
```

---

## 問題 9：`--gpus all` 無法正確注入 Vulkan ICD（Blackwell GPU 特有問題）

**現象**

使用 `--gpus all`（即使加上 `PATH=/usr/local/nvidia/toolkit:$PATH`）後，CUDA 可存在，但 Vulkan 仍失敗：

```
[Error] [omni.rtx] vkCreateInstance failed.
Vulkan 1.1 is not supported, or your driver requires an update.
[Error] GPU Foundation is not initialized!
```

**診斷過程**

| 檢查項目 | k8s dsx-stack-kit-0（正常） | 我的容器（異常） |
| --- | --- | --- |
| `/etc/vulkan/icd.d/nvidia_icd.json` api_version | `1.4.325`（host driver） | `1.3.194`（container image 帶的） |
| `/dev/nvidia-modeset` | 存在 | 不存在（`--gpus all` 沒注入） |
| NVIDIA runtime 方式 | k8s NVIDIA device plugin | nvidia-container-cli（不完整） |

**根本原因**

- `--gpus all` 透過 `nvidia-container-cli` 執行，只注入 CUDA 相關函式庫，但未正確更新容器內的 Vulkan ICD JSON（保留了 container image 裡的舊版 `api_version: 1.3.194`），也未注入 `/dev/nvidia-modeset`。
- k8s 使用的 `nvidia-container-runtime` 能完整注入所有 NVIDIA 組件（CUDA、Vulkan ICD、modeset device 等）。

**解決方式**

改用 `--runtime` 參數，讓 nerdctl 直接使用 nvidia-container-runtime：

```bash
sudo PATH=/usr/local/nvidia/toolkit:$PATH nerdctl run \
  --runtime=/usr/local/nvidia/toolkit/nvidia-container-runtime \
  --env NVIDIA_VISIBLE_DEVICES=all \
  --env NVIDIA_DRIVER_CAPABILITIES=all \
  ...
```

此方式與 k8s 使用相同的 runtime，完整注入 GPU 環境（Vulkan ICD api_version 1.4.325、/dev/nvidia-modeset、libcuda 等）。

---

## 問題 10：Port 與現有 k8s 服務衝突

**現象**

DSX Blueprint k8s 服務佔用：
- `49100` → WebRTC signaling（`dsx-stack-kit-0`）
- `8012` → HTTP API（`dsx-stack-kit-0`）

**解決方式**

在 streaming kit 設定中改用不衝突的 Port：

```toml
[settings]
exts."omni.kit.livestream.app".primaryStream.signalPort = 49200
exts."omni.services.transport.server.http".port = 8112
```

---

## 問題 11：`app.livestream.port` 設定已過時警告

**現象**

```
[Warning] Applying legacy setting /app/livestream/port with value 49200
to new setting /exts/omni.kit.livestream.app/primaryStream/signalPort
Please replace all usage of deprecated setting
```

**解決方式**

將 kit 檔案中的舊設定：

```toml
app.livestream.port = 49200  # 舊（deprecated）
```

替換為：

```toml
exts."omni.kit.livestream.app".primaryStream.signalPort = 49200  # 新
```

---

## 問題 12：選擇「UI for any streaming app」後瀏覽器空白畫面

**現象**

開啟 `http://192.168.5.100:8082`，選擇「UI for any streaming app」後頁面空白，無任何串流畫面出現。

**原因**

`web-viewer-sample/stream.config.json` 的預設值未修改：

```json
"local": {
    "server": "127.0.0.1",   ← 瀏覽器嘗試連到自己的 127.0.0.1
    "signalingPort": 49100,  ← DSX k8s 的服務，非 streaming 容器
    "mediaPort": null
}
```

`AppStream.tsx` 直接讀取此設定建立 WebRTC 連線，導致信令連線失敗、畫面空白。

**解決方式**

修改 `~/DSX-BP/web-viewer-sample/stream.config.json`：

```json
"local": {
    "server": "192.168.5.100",
    "signalingPort": 49200,
    "mediaPort": null
}
```

修改後重啟 web viewer：

```bash
pkill -f vite
cd ~/DSX-BP/web-viewer-sample
nohup npm run dev -- --host 0.0.0.0 --port 8082 > /tmp/web-viewer.log 2>&1 &
```

---

## 問題 13：USD Composer 佔用所有 GPU（`NVIDIA_VISIBLE_DEVICES=all`）

**現象**

使用 `--env NVIDIA_VISIBLE_DEVICES=all` 啟動容器後，`nvidia-smi` 顯示 USD Composer 的 kit 程序出現在全部 8 張 GPU 上，佔用其他服務的資源。

**原因**

`NVIDIA_VISIBLE_DEVICES=all` 讓 nvidia-container-runtime 將所有 GPU 全部注入容器，Kit 在初始化時會在每張可見的 GPU 上建立渲染 context。

**解決方式**

啟動前先確認 DSX Blueprint 使用的 GPU index，讓 USD Composer 共用同一張卡：

```bash
# 1. 找出 DSX Blueprint 的 GPU（程序名為 /app/kit/kit）
nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory,process_name --format=csv,noheader

# 2. 將 UUID 對應到 index
nvidia-smi --query-gpu=index,uuid --format=csv,noheader | grep <上面的UUID>

# 3. 啟動時指定該 index（本環境 DSX Blueprint 在 GPU 3）
--env NVIDIA_VISIBLE_DEVICES=3
```

確認兩個 kit 程序共用同一張卡：

```bash
nvidia-smi --query-compute-apps=pid,gpu_uuid,process_name --format=csv,noheader | grep kit
# 預期：兩筆記錄的 gpu_uuid 相同
```

> **更穩定的做法**：用 UUID 而非 index。`NVIDIA_VISIBLE_DEVICES=GPU-1e01282d-...`。當主機 GPU 數量變動或 NVIDIA device-plugin 重啟時，index 順序可能改變；UUID 永遠對應到同一塊實體卡。

---

## 問題 14：手動容器與 k8s pod 的 WebRTC UDP 媒體 port 撞（NO_PORTS_AVAILABLE）

**現象**

手動 `usd-composer-streaming` 已用 `signalPort=49200`，TCP 部分不衝突；但 k8s `dsx-stack-kit-0` 啟動後 livestream 持續噴：

```
[Fatal] [omni.kit.livestream.streamsdk] Configuring failed:
  StreamSdkException 800b001e [NVST_R_ERROR_UDP_RTP_SOURCE_OPEN_FAILED_NO_PORTS_AVAILABLE]
  Failed to bind WebRtcTransport socket.
```

**原因**

`omni.kit.livestream.app.primaryStream` 有兩個 port：

| 設定 | 預設值 | 用途 |
| --- | --- | --- |
| `signalPort` | 49100 | TCP 信令 |
| `streamPort` | 47998 | UDP RTP 媒體 |

僅覆寫 `signalPort` 不夠 — 預設 `streamPort=47998` 仍落在 k8s pod 的 containerPort 範圍 `47995-48012` 內，導致 k8s pod 的 NVST 無法綁 UDP socket。

**解決方式**

在 `start-usd-streaming.sh` 的 nerdctl 啟動參數加上：

```bash
--/exts/"omni.kit.livestream.app"/primaryStream/streamPort=49500 \
```

`49500` 同時避開 k8s 兩段 containerPort 範圍（`47995-48012` 與 `49000-49007`）。修改後重啟手動容器，再 `kubectl -n dsx-factory delete pod dsx-stack-kit-0` 讓 k8s pod 帶著 fresh state 重啟即可。

---

## 問題 15：k8s `dsx-stack-kit-0` CrashLoopBackOff（unresolvable CDI device）

**現象**

```
Error: failed to create containerd task: failed to create shim task:
OCI runtime create failed: could not apply required modification to OCI specification:
error modifying OCI spec: failed to inject CDI devices:
unresolvable CDI devices runtime.nvidia.com/gpu=GPU-08ee3f34-e027-2961-9dee-85f354027972: unknown
```

**原因**

NVIDIA device-plugin 把一顆**實際不存在**的 GPU UUID（`08ee3f34...`）配給 pod。常見成因：

- 主機 GPU 數量變動（例如硬體故障被移除一顆），但 kubelet/device-plugin 帳本沒同步
- Node label `nvidia.com/gpu.count` 已是正確值（例如 7），但 Allocatable 仍寫 8
- CDI registry (`/etc/cdi/nvidia.yaml`) 只列出實際 7 顆 UUID，所以「第 8 顆」被分到 pod 後 OCI runtime 找不到

**診斷指令**

```bash
# 實際 GPU
nvidia-smi --query-gpu=index,uuid,memory.used --format=csv

# CDI 註冊的 UUID（應與上面一致）
grep -E 'name: GPU-' /etc/cdi/nvidia.yaml | sort -u

# kubelet/scheduler 認知的數量
kubectl describe node ubuntu | grep -E 'Allocatable:|Allocated' -A20 | grep nvidia.com/gpu
```

**解決方式（不動 nvidia-gpu-operator）**

直接在 StatefulSet 上 patch：

1. 移除 `nvidia.com/gpu` resource request（不再走 device-plugin）
2. 加環境變數 `NVIDIA_VISIBLE_DEVICES=<真實存在的 GPU UUID>`
3. 加 `NVIDIA_DRIVER_CAPABILITIES=all`

NVIDIA Container Runtime（pod spec 已有 `runtimeClassName: nvidia`）會直接根據 env 注入指定那顆 GPU。

```bash
kubectl -n dsx-factory patch statefulset dsx-stack-kit --type=strategic --patch '
spec:
  template:
    spec:
      containers:
      - name: kit
        env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: GPU-1e01282d-1e27-4ea3-7e1f-584762ed1ad7
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: all
        resources:
          limits:
            nvidia.com/gpu: null
          requests:
            nvidia.com/gpu: null
'
```

**重要警告**

此 patch **不會寫回 Helm chart**。下次 `helm upgrade dsx-stack` 會被覆蓋。要永久化需修改 chart values（建議路徑：`values.yaml` 內的 `kit.resources` 與 `kit.env`）。

**根治方式（需要動 cluster 元件，非必要不做）**

重啟 nvidia-device-plugin pod 讓它重新 scan：

```bash
kubectl -n nvidia-gpu-operator delete pod -l app=nvidia-device-plugin-daemonset
```

重啟期間（約 5–10 秒）node 暫時無 GPU 容量；已 attach GPU 的 pod 不會被踢，但新 GPU pod 排程會等待。

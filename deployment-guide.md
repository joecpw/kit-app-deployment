# USD Composer Streaming — 完整部署與維運指南

> **環境規格**
>
> Server IP：`192.168.5.100`
>
> OS：Ubuntu 22.04
>
> GPU：NVIDIA RTX PRO 6000 Blackwell Edition × 8（Driver 590.48.01）
>
> Container Runtime：nerdctl 1.7.7 + containerd
>
> NVIDIA Toolkit：`/usr/local/nvidia/toolkit/`
>
> 專案根目錄：`~/DSX-BP/`

---

## 架構概覽

```
[Browser]
    ↑  HTTP :8082
    ↓
[web-viewer-sample]  (npm vite dev server)
    ↑  WebRTC signaling :49200
    ↓
[usd-composer-streaming container]
    ↑  kit binary + streaming extensions
    ↓
[NVIDIA GPU via nvidia-container-runtime]

現有服務（不可影響）：
  DSX BP Web (vite dev)  → port 8081   （主機直接執行，非 k8s）
  dsx-stack-kit-0        → port 49100 (WebRTC) / 8012 (HTTP API)
  dsx-stack-web-*        → port 30811 (NodePort)
```

**Port 配置**

| 服務 | Port | 說明 |
| --- | --- | --- |
| web-viewer-sample | 8082 | 瀏覽器入口（本地案） |
| WebRTC signaling | 49200 | Kit streaming 信令（本地案） |
| HTTP API (Kit) | 8112 | Kit REST API（本地案） |
| DSX BP Web | 8081 | DSX Blueprint 前端（主機 vite dev server，勿佔用） |
| DSX k8s Kit | 49100 | `dsx-stack-kit-0` WebRTC signaling（勿佔用） |
| DSX k8s Kit HTTP | 8012 | `dsx-stack-kit-0` HTTP API（勿佔用） |
| DSX k8s Web | 30811 | `dsx-stack-web` NodePort（勿佔用） |

---

## 一、前置準備（僅首次部署）

### 1.1 確認環境

```bash
# 確認 k8s DSX 服務正常（不可影響這兩個）
kubectl get pods -n dsx-factory
# 預期：dsx-stack-kit-0 1/1 Running、dsx-stack-web-* 1/1 Running

# 確認 nvidia-container-runtime 存在
ls /usr/local/nvidia/toolkit/nvidia-container-runtime

# 確認 GPU 設備
ls /dev/nvidia*

# 確認 Node.js（web viewer 需要）
node --version  # 需要 v18+
npm --version
```

### 1.2 目錄結構

```
~/DSX-BP/
├── kit-app-template/          # NVIDIA Kit App Template 專案
│   ├── source/
│   │   ├── apps/
│   │   │   ├── my_company.my_usd_composer.kit          # 主 app
│   │   │   └── my_company.my_usd_composer_streaming.kit # streaming app
│   │   └── extensions/
│   ├── _build/linux-x86_64/release/   # build 產物
│   │   ├── kit/kit                    # Kit 執行檔
│   │   ├── extscache/                 # 擴充套件快取
│   │   └── exts/                      # 額外擴充套件
│   └── repo.toml
├── web-viewer-sample/         # NVIDIA WebRTC 前端
└── usd-composer-deployment/            # 部署腳本與文件（版控目錄）
    ├── start-usd-streaming.sh
    ├── start-web-viewer.sh
    ├── deployment-guide.md
    └── troubleshooting.md
```

---

## 二、建立 Kit App（首次僅做一次）

### 2.1 使用 kit-app-template 建立主 app

```bash
cd ~/DSX-BP/kit-app-template

# 建立主 app（互動式）
./repo.sh template new
# 選擇：USD Composer → 輸入公司名 my_company、app 名 my_usd_composer
# Do you want to add application layers? → No（或選 default streaming）
```

### 2.2 手動建立 Streaming Kit 設定檔

建立 `source/apps/my_company.my_usd_composer_streaming.kit`：

```toml
#SPDX-FileCopyrightText: Copyright (c) 2024 NVIDIA CORPORATION & AFFILIATES.
#SPDX-License-Identifier: LicenseRef-NvidiaProprietary

[package]
title = "My USD Composer Streaming"
version = "0.1.0"
description = "Configuration for streaming deployments of My USD Composer"
keywords = ["experience", "app", "dev", "streaming"]
template_name = "omni.streaming_configuration"

[dependencies]
"my_company.my_usd_composer" = {}   # 主 app
"omni.kit.livestream.app" = {}       # Livestream 擴充套件

[settings.app]
fastShutdown = true
name = "My USD Composer Streaming"
renderer.resolution.height = 1080
renderer.resolution.width = 1920
window.height = 1080
window.width = 1920

[settings.app.extensions]
registryEnabled = true
supportedTargets.platform = []
exclude = [
    "omni.kit.developer.bundle",
    "omni.kit.widget.cache_indicator",
]

[settings.app.exts]
folders.'++' = [
    "${app}/../exts",
    "${app}/../apps",
    "${app}/../extscache"
]

[settings.app.file]
ignoreUnsavedOnExit = true

[settings]
rtx.post.aa.op = 3
rtx.verifyDriverVersion.enabled = false

# Port 設定（避免與 DSX k8s 服務衝突）
exts."omni.kit.livestream.app".primaryStream.signalPort = 49200
exts."omni.services.transport.server.http".port = 8112
```

### 2.3 將 Streaming Kit 加入 repo.toml 的 precache 清單

編輯 `~/DSX-BP/kit-app-template/repo.toml`，找到 `[repo_precache_exts]`：

```toml
[repo_precache_exts]
apps = [
    "${root}/source/apps/my_company.my_usd_composer.kit",
    "${root}/source/apps/my_company.my_usd_composer_streaming.kit",   # ← 新增
]
```

> **重要**：若沒有這一行，build 時不會下載 `omni.kit.livestream.app` 等 streaming 套件。

### 2.4 Build（下載擴充套件並編譯）

```bash
cd ~/DSX-BP/kit-app-template
./repo.sh build
# 預估 10～20 分鐘（首次），後續 rebuild 差異下載
```

Build 完成後確認 streaming 套件存在：

```bash
ls _build/linux-x86_64/release/extscache/ | grep livestream
# 應看到：
# omni.kit.livestream.app-10.1.0+...
# omni.kit.livestream.core-10.0.0+...
# omni.kit.livestream.webrtc-10.1.2+...
```

---

## 三、部署 Web Viewer（首次僅做一次）

```bash
cd ~/DSX-BP
git clone https://github.com/NVIDIA-Omniverse/web-viewer-sample.git
cd web-viewer-sample
npm install
```

### 3.1 設定 stream.config.json

安裝完成後，**必須**修改 `~/DSX-BP/web-viewer-sample/stream.config.json`：

```json
{
    "source": "local",
    "stream": { "appServer": "", "streamServer": "" },
    "gfn": { "catalogClientId": "", "clientId": "", "cmsId": 0 },
    "local": {
        "server": "192.168.5.100",
        "signalingPort": 49200,
        "mediaPort": null
    }
}
```

> **重要**：若未修改此檔案，WebRTC 無法連線（預設值指向 127.0.0.1:49100，會連到 DSX k8s 服務）。

---

## 四、啟動 Streaming 服務

### 4.0 確認目標 GPU

此 server 有多張 GPU，啟動前確認 DSX Blueprint 使用的 GPU index，讓 USD Composer 共用同一張卡：

```bash
# 查看各 GPU 上的程序與佔用
nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory,process_name --format=csv,noheader

# 查 UUID → index 對應
nvidia-smi --query-gpu=index,uuid,memory.used --format=csv,noheader

# DSX Blueprint 的 kit 程序路徑為 /app/kit/kit
# 找到後記下其 GPU index（本環境為 GPU 3）
```

將下方指令的 `NVIDIA_VISIBLE_DEVICES` 設為該 index（例如 `3`）。

### 4.1 啟動 USD Composer Streaming 容器

```bash
~/DSX-BP/usd-composer-deployment/start-usd-streaming.sh
```

**確認啟動成功**，等待輸出出現：

```
[ext: omni.kit.livestream.webrtc-10.1.2] startup
[ext: omni.kit.livestream.app-10.1.0] startup
app ready
```

確認 Port 已監聽：

```bash
ss -tlnp | grep -E '49200|8112'
# LISTEN  0.0.0.0:49200   (WebRTC signaling)
# LISTEN  0.0.0.0:8112    (HTTP API)
```

### 4.2 啟動 Web Viewer

```bash
~/DSX-BP/usd-composer-deployment/start-web-viewer.sh
```

查看 log：

```bash
tail -f /tmp/web-viewer.log
```

---

## 五、連線操作

1. 在本機開啟 Chrome 或 Edge，前往：`http://192.168.5.100:8082`
2. 在 web viewer 的連線介面填入：
    - **Server**：`192.168.5.100`
    - **Port**：`49200`
3. 點擊 Connect，等待 USD Composer 畫面串流出現。
4. 可用滑鼠、鍵盤在瀏覽器內直接操作 USD Composer viewport。

---

## 六、維運操作

### 查看容器狀態

```bash
sudo nerdctl ps | grep usd-composer
```

### 查看即時 Log

```bash
# 背景啟動時
tail -f /tmp/usd-streaming.log

# 或直接查容器 log
sudo nerdctl logs -f usd-composer-streaming
```

### 停止 Streaming 容器

```bash
sudo nerdctl stop usd-composer-streaming
```

### 重啟 Streaming

```bash
sudo nerdctl stop usd-composer-streaming 2>/dev/null || true
~/DSX-BP/usd-composer-deployment/start-usd-streaming.sh
```

### 確認 DSX k8s 服務未受影響

```bash
kubectl get pods -n dsx-factory
# 應顯示：
# dsx-stack-kit-0                  1/1 Running
# dsx-stack-web-6f9c498f47-zqtz9   1/1 Running
```

### 查看 Kit 詳細 Log（位於 build 目錄內）

```bash
ls ~/DSX-BP/kit-app-template/_build/linux-x86_64/release/logs/Kit/My\ USD\ Composer\ Streaming/0.1/
tail -100 ~/DSX-BP/kit-app-template/_build/linux-x86_64/release/logs/Kit/My\ USD\ Composer\ Streaming/0.1/kit_*.log
```

---

## 七、更新 Kit App

若需更新 streaming kit 設定（如更改解析度、port 等）：

1. 修改 `source/apps/my_company.my_usd_composer_streaming.kit`
2. 若有新增擴充套件依賴，重新 build：

    ```bash
    cd ~/DSX-BP/kit-app-template && ./repo.sh build
    ```

3. 重啟容器：

    ```bash
    sudo nerdctl stop usd-composer-streaming 2>/dev/null || true
    ~/DSX-BP/usd-composer-deployment/start-usd-streaming.sh
    ```

---

## 八、關鍵技術說明

### 為何必須使用 `--runtime` 而非 `--gpus all`

| 方式 | CUDA | Vulkan ICD（正確版本） | `/dev/nvidia-modeset` |
| --- | --- | --- | --- |
| `--gpus all`（nvidia-container-cli） | ✅ | ❌（保留 container 裡的 1.3.194） | ❌ |
| `--runtime=nvidia-container-runtime` | ✅ | ✅（注入 host 的 1.4.325） | ✅ |

Blackwell GPU（Architecture 12.x）需要 Vulkan ICD `api_version ≥ 1.4.x` 且需要 `/dev/nvidia-modeset` 才能正常初始化渲染管線。`--gpus all` 只由 nvidia-container-cli 處理，無法完整注入；`nvidia-container-runtime` 才是 k8s 所使用的完整注入方式。

### 為何需要這些 Volume Mount

| Mount | 用途 |
| --- | --- |
| `kit-app-template:/...` | Kit 執行檔、extscache、source kit 檔案全部在此 |
| `.local/share/ov:/...` | extscache symlink 的實際資料（約 16GB） |
| `.cache/packman:/...:ro` | packman 套件快取（唯讀即可） |

### extscache 與實際資料的關係

`_build/.../extscache/` 內的項目都是 symlink，指向：

```
~/.local/share/ov/data/exts/v2/<extension-version>/
```

因此容器必須掛載 `~/.local/share/ov` 才能存取實際擴充套件資料。

---

## 九、常見問題 FAQ

**Q：容器啟動後 app ready 但瀏覽器連不上？**

A：確認 port 49200 已開放防火牆，且 web-viewer-sample 正在 8082 執行。用 `ss -tlnp | grep -E '49200|8082'` 確認。

**Q：Vulkan 初始化失敗（ERROR_INCOMPATIBLE_DRIVER）？**

A：確認使用了 `--runtime=/usr/local/nvidia/toolkit/nvidia-container-runtime` 而非 `--gpus all`。前者才能正確注入 Vulkan ICD。

**Q：重開機後服務消失？**

A：目前未設定 systemd service，重開機後手動執行：

```bash
~/DSX-BP/usd-composer-deployment/start-usd-streaming.sh
~/DSX-BP/usd-composer-deployment/start-web-viewer.sh
```

**Q：streaming 畫面沒有 GPU 渲染（黑畫面）？**

A：查看 log 確認 GPU Foundation 是否初始化成功：

```bash
grep -E '(GPU Foundation|omni.rtx|vulkan|cuda)' /tmp/usd-streaming.log | grep -iE '(error|fail|init)'
```

**Q：如何指定使用哪張 GPU？**

A：先用 `nvidia-smi --query-compute-apps=... --format=csv,noheader` 找到 DSX Blueprint（`/app/kit/kit`）所在的 GPU index，再將 `NVIDIA_VISIBLE_DEVICES` 設為該 index，讓兩個服務共用同一張卡，不額外佔用顯卡資源。亦可指定 UUID：

```bash
--env NVIDIA_VISIBLE_DEVICES=GPU-1e01282d-...
```

**Q：web-viewer-sample 如何設定預設連線資訊？**

A：編輯 `~/DSX-BP/web-viewer-sample/stream.config.json`，將 `server` 和 `signalingPort` 設為正確值（見第三節）。

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
    ↑  WebRTC signaling :49200 (TCP)  +  media :49500 (UDP)
    ↓
[usd-composer-streaming container]
    ↑  kit binary + streaming extensions
    ↓
[NVIDIA GPU via nvidia-container-runtime]  ← 啟動時自動挑選最閒置 GPU（可用 GPU_UUID 環境變數覆寫）

現有服務（不可影響）：
  DSX BP Web (vite dev)  → port 8081           （主機直接執行，非 k8s）
  dsx-stack-kit-0        → 49100 (TCP signaling) / 8012 (HTTP) / 47998 (UDP media)
  dsx-stack-web-*        → port 30811 (NodePort)
```

**Port 配置**

| 服務 | Port | Proto | 說明 |
| --- | --- | --- | --- |
| web-viewer-sample | 8082 | TCP | 瀏覽器入口（本地案） |
| WebRTC signaling | 49200 | TCP | Kit streaming 信令（本地案） |
| WebRTC media (RTP) | 49500 | UDP | Kit streaming 媒體（本地案，避開 k8s 47995-49007 範圍） |
| HTTP API (Kit) | 8112 | TCP | Kit REST API（本地案） |
| DSX BP Web | 8081 | TCP | DSX Blueprint 前端（主機 vite dev server，勿佔用） |
| DSX k8s Kit signaling | 49100 | TCP | `dsx-stack-kit-0`（勿佔用） |
| DSX k8s Kit HTTP | 8012 | TCP | `dsx-stack-kit-0`（勿佔用） |
| DSX k8s Kit media | 47998 | UDP | `dsx-stack-kit-0` 預設 streamPort（勿佔用） |
| DSX k8s Web | 30811 | TCP | `dsx-stack-web` NodePort（勿佔用） |

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
└── kit-app-deployment/            # 部署腳本與文件（版控目錄）
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

### 4.0 GPU 選擇策略（預設自動）

`start-usd-streaming.sh` **預設會自動挑選 free memory 最高的 GPU** 並以 UUID 鎖定，多數情況不需手動指定。啟動時會印出實際選到的 UUID，例如：

```
[GPU] auto-selected: GPU-dcd67700-310b-3157-29c8-d94bfac9d133
1, GPU-dcd67700-310b-3157-29c8-d94bfac9d133, 0 MiB, 97253 MiB, 0 %
```

**何時需要手動覆寫**：

- 想讓 USD Composer 與 `dsx-stack-kit-0` 共用同一張卡（節省 VRAM）
- 想避開正在跑訓練 / 推論的 GPU
- 多人測試時固定一張 GPU 方便除錯

**覆寫方式**（用環境變數，不用改腳本）：

```bash
# 1. 先用 nvidia-smi 取得目標 UUID
nvidia-smi --query-gpu=index,uuid,memory.used,memory.free --format=csv,noheader

# 2. 啟動時透過環境變數覆寫
GPU_UUID="GPU-1e01282d-1e27-4ea3-7e1f-584762ed1ad7" \
  ~/DSX-BP/kit-app-deployment/start-usd-streaming.sh

# 啟動 log 會顯示：
# [GPU] using override from env: GPU-1e01282d-...
```

> **為什麼用 UUID 而非 index**：當主機 GPU 數量變動或 NVIDIA device-plugin 重啟時，index 順序可能改變；UUID 永遠對應到同一塊實體卡。

> **觀察 DSX Blueprint 跑在哪張卡**：`nvidia-smi --query-compute-apps=pid,gpu_uuid,used_memory,process_name --format=csv,noheader`，DSX Blueprint 的 kit 程序路徑為 `/app/kit/kit`。

### 4.1 啟動 USD Composer Streaming 容器

```bash
~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
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
~/DSX-BP/kit-app-deployment/start-web-viewer.sh
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

> **服務現由 systemd 管理（2026-06-16 起）**：`usd-composer-streaming.service`（kit 容器）+ `usd-composer-webviewer.service`（web viewer）已 `enable`，**開機會自動啟動、crash 會自動重啟**，根治「重開機後服務消失」。手動 `start-*.sh` / `setsid` 方式保留作 ad-hoc 用途，但日常維運請優先用 systemd。
>
> 註：此為**過渡方案**。最終目標是把 usd composer 比照 `aif-dt-factory` 重打包成 k8s 服務（namespace `aif-usd-composer`），屆時 systemd unit 會 disable 退役。

### systemd 管理（主要方式）

```bash
# 狀態
sudo systemctl status usd-composer-streaming usd-composer-webviewer

# 重啟（ExecStartPre 會先清殘留容器再起，~50-60s 到 RTX ready）
sudo systemctl restart usd-composer-streaming
sudo systemctl restart usd-composer-webviewer

# 停止 / 啟動
sudo systemctl stop  usd-composer-streaming usd-composer-webviewer
sudo systemctl start usd-composer-streaming usd-composer-webviewer

# 看 log（取代背景版的 /tmp/usd-streaming.log）
sudo journalctl -u usd-composer-streaming -f
sudo journalctl -u usd-composer-webviewer -f

# 確認開機會自動起（兩個都應為 enabled）
sudo systemctl is-enabled usd-composer-streaming usd-composer-webviewer
```

Unit 與 foreground wrapper（版控於本 repo）：

| 檔案 | 用途 |
| --- | --- |
| `systemd/usd-composer-streaming.service` → `run-usd-streaming.sh` | kit 容器；foreground 版 `start-usd-streaming.sh`（含 kit-cae ext-folder + 自動挑最閒 GPU）；`Restart=always`、`After=containerd`、`ExecStartPre` 清殘留 |
| `systemd/usd-composer-webviewer.service` → `run-web-viewer.sh` | vite web viewer（`User=ubuntu`，port 8082）|
| `systemd/install-systemd.sh` | 安裝/重裝 installer：`sudo bash systemd/install-systemd.sh`（idempotent）|

> **stdout 走 journald**（不是 `/tmp/usd-streaming.log`）。原因：systemd 255 用 `StandardOutput=append:` 開既有 `ubuntu:ubuntu` 擁有的 `/tmp/*.log` 會 `Permission denied`（連 root 服務都被擋），故改 journald。kit 自己的詳細 log 仍在 `_build/.../logs/Kit/`。

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

### 重啟 Streaming（手動 ad-hoc fallback；日常請用上面的 `systemctl restart`）

```bash
# 僅在刻意不走 systemd 時用；會與 systemd 版搶 name/port，務必先停 systemd
sudo systemctl stop usd-composer-streaming 2>/dev/null || true
sudo nerdctl rm -f usd-composer-streaming 2>/dev/null || true
~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
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
    ~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
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
| `DSX-BP:/home/ubuntu/DSX-BP` | 整個 DSX-BP 專案根（含 kit-app-template、web-viewer-sample、kit-app-deployment 與專案內 USD 場景／文件），讓 USD Composer 可直接以 `/home/ubuntu/DSX-BP/...` 開啟任何檔案（rw） |
| `.local/share/ov:/...` | extscache symlink 的實際資料（約 16GB） |
| `.cache/packman:/...:ro` | packman 套件快取（唯讀即可） |
| `/mnt/data/dsx-content:/mnt/data/dsx-content` | DSX 大型 dataset（90 GB，DSX_BP/、Datacenter_NVD/、GB300/...）真實位置；container 內以同名路徑直接暴露，使用者可瀏覽 `/mnt/data/dsx-content/...` 開啟檔案（rw） |
| `/mnt/data/dsx-content:/data/dsx-content` | 與 k8s pod 慣例對齊，container 內 `.kit` / USD 既有絕對路徑 `/data/dsx-content/...` 仍可解析到大型 dataset（rw） |
| `/home/ubuntu/dsx-content:/home/ubuntu/dsx-content` | 客製 / 在地內容（如 `AIF_DT/`），保留在 root volume，跟搬到大碟的 dataset 分開（rw） |

> **關於 host 路徑分工**：
> - 大型 read-only NVIDIA dataset（DSX_BP、Datacenter_NVD 等）放 `/mnt/data/dsx-content`（datalv 1.5 TB）
> - 小型可寫客製內容（AIF_DT 等）留在 `/home/ubuntu/dsx-content`（root volume）
> - 兩條路在 container 內用各自原生路徑暴露，**不做 symlink**，避免混淆檔案來源
> - k8s `dsx-stack-kit-0` 同步把 hostPath 改為 `/mnt/data/dsx-content/DSX_BP`，與此處對齊

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

A：**已於 2026-06-16 用 systemd 解決** — `usd-composer-streaming.service` + `usd-composer-webviewer.service` 已 `enable`，重開機會自動啟動、crash 也自動重啟，不需再手動拉起。詳見「六、維運操作」的 systemd 段。

若 systemd unit 被移除、需要手動拉起（ad-hoc fallback）：

```bash
~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
~/DSX-BP/kit-app-deployment/start-web-viewer.sh
```

**Q：streaming 畫面沒有 GPU 渲染（黑畫面）？**

A：查看 log 確認 GPU Foundation 是否初始化成功：

```bash
grep -E '(GPU Foundation|omni.rtx|vulkan|cuda)' /tmp/usd-streaming.log | grep -iE '(error|fail|init)'
```

**Q：如何指定使用哪張 GPU？**

A：預設**自動挑選 free memory 最高的 GPU**（見 4.0 節）。要覆寫請用環境變數而非改腳本：

```bash
# 先用 nvidia-smi 取得目標 UUID
nvidia-smi --query-gpu=index,uuid,memory.free --format=csv,noheader

# 啟動時 inline override
GPU_UUID="GPU-1e01282d-1e27-4ea3-7e1f-584762ed1ad7" \
  ~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
```

腳本會把 `NVIDIA_VISIBLE_DEVICES=${GPU_UUID}` 傳進 container，nvidia-container-runtime 只會注入該卡。一律用 UUID 而非 index，避免日後 GPU 數量變動或 device-plugin 重啟造成 index 漂移。

**Q：為什麼 start script 要再用 `--/exts/.../signalPort=49200` 覆寫 port？**

A：防呆。若 `my_company.my_usd_composer_streaming.kit` 內的 port 設定被誤改回預設，會撞到 k8s `dsx-stack-kit-0` 的 49100/8012。CLI 參數優先於 .kit 設定，確保兩套服務共存。

**Q：為什麼還要設 `streamPort=49500`？signalPort 不夠嗎？**

A：不夠。`omni.kit.livestream.app.primaryStream` 有兩個 port：

- `signalPort`：TCP 信令（連線協商）
- `streamPort`：UDP RTP 媒體（實際視訊串流）

預設 `streamPort = 47998` 落在 k8s pod 的 containerPort 範圍 `47995-48012` 內，會跟 k8s 撞 UDP。改用 `49500`（k8s 範圍外）才能讓兩套 livestream 完全並存。

**Q：k8s `dsx-stack-kit-0` 啟動就 CrashLoopBackOff，錯誤是 `unresolvable CDI devices runtime.nvidia.com/gpu=GPU-08ee3f34-...`？**

A：node 上 NVIDIA device-plugin 帳本與實際 GPU 數量不一致（例如曾有 GPU 被移除），device-plugin 仍 advertise 一個不存在的「幽靈 UUID」給 scheduler。修法是繞過 device-plugin、直接用 NVIDIA Container Runtime 的環境變數鎖定真實 UUID：

```bash
kubectl -n dsx-factory patch statefulset dsx-stack-kit --type=strategic --patch '
spec:
  template:
    spec:
      containers:
      - name: kit
        env:
        - name: NVIDIA_VISIBLE_DEVICES
          value: GPU-1e01282d-1e27-4ea3-7e1f-584762ed1ad7   # 改成實際存在的 GPU UUID
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: all
        resources:
          limits:
            nvidia.com/gpu: null
          requests:
            nvidia.com/gpu: null
'
```

> 此 patch **不會寫回 Helm chart**，下次 `helm upgrade dsx-stack` 會被覆蓋；要永久化需改 chart values。

**Q：web-viewer-sample 如何設定預設連線資訊？**

A：編輯 `~/DSX-BP/web-viewer-sample/stream.config.json`，將 `server` 和 `signalingPort` 設為正確值（見第三節）。

---

## 附錄：dsx-content 路徑分工調整

90 GB NVIDIA dataset 從 `/home/ubuntu/dsx-content`（root volume 252 GB）搬到 `/mnt/data/dsx-content`（datalv 1.5 TB）。**不做 symlink**，兩個位置在 container 內用各自原生路徑分別暴露：

| 位置 | 內容 | 大小 | 寫入特性 |
| --- | --- | --- | --- |
| `/mnt/data/dsx-content` | NVIDIA 大型 read-only dataset：`DSX_BP/`、`Datacenter_NVD/`、`GB300/`、`GB300_cooling/`、`GB300_power/` | ~90 GB | 視為 immutable |
| `/home/ubuntu/dsx-content` | 客製 / 在地內容：`AIF_DT/` 與其他 user-authored 資料 | 小（< 100 MB 量級） | rw |

### 對應的服務變更

**USD Composer streaming container**（本 repo 的 `start-usd-streaming.sh`）：三條 mount，兩個位置都暴露給 container 同名路徑（見上方 Volume Mount 表）。

**k8s `dsx-stack-kit-0`**（gcai-dsx 的 `dsx-live-values.yaml`）：
```yaml
extraVolumeMounts:
  - name: dsx-content
    mountPath: /data/dsx-content/DSX_BP   # 從 /data/dsx-content 改成 DSX_BP 子層
    readOnly: true
extraVolumes:
  - name: dsx-content
    hostPath:
      path: /mnt/data/dsx-content/DSX_BP  # 從 /home/ubuntu/dsx-content 改成 /mnt/data/.../DSX_BP
      type: Directory
```

`kitArgs` 裡的 `--/app/auto_load_usd=/data/dsx-content/DSX_BP/Assembly/DSX_Main_BP.usda` 不變。

### 套用步驟（資料已搬完的情境）

如果資料已經自行用 `mv` / `rsync` 搬到 `/mnt/data/dsx-content`：

```bash
# 1. 拉最新 kit-app-deployment 腳本
cd ~/DSX-BP/kit-app-deployment && git pull --ff-only

# 2. 重啟 USD Composer streaming container
sudo nerdctl stop usd-composer-streaming 2>/dev/null
sudo nerdctl rm   usd-composer-streaming 2>/dev/null
~/DSX-BP/kit-app-deployment/start-usd-streaming.sh
tail -f /tmp/usd-streaming.log     # 等 "app ready"

# 3. 更新 dsx-live-values.yaml 並 helm upgrade
cd ~/DSX-BP/gcai-dsx
# 編輯 dsx-live-values.yaml 把 extraVolumes / extraVolumeMounts 改為上述新路徑
helm upgrade dsx-stack /home/ubuntu/DSX-BP/omniverse-dsx-blueprint-for-ai-factories/helm/dsx \
  -n dsx-factory -f dsx-live-values.yaml
kubectl -n dsx-factory wait --for=condition=Ready pod/dsx-stack-kit-0 --timeout=180s
```

### 驗證

```bash
# USD Composer container 看到 3 個位置
sudo nerdctl exec usd-composer-streaming ls /mnt/data/dsx-content/  | head
sudo nerdctl exec usd-composer-streaming ls /data/dsx-content/      | head
sudo nerdctl exec usd-composer-streaming ls /home/ubuntu/dsx-content/

# k8s pod 看到 DSX_BP 內容
kubectl -n dsx-factory exec dsx-stack-kit-0 -- ls /data/dsx-content/DSX_BP/ | head
curl -s http://192.168.5.100:8012/api/agent/health | python3 -m json.tool
```

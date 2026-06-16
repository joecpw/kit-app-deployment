# USD Composer Streaming — Kubernetes 部署與維運（權威文件）

> **狀態（2026-06-16）**：USD Composer streaming **kit + web viewer 皆已從「手動 nerdctl + systemd」遷移為 Kubernetes 託管**，namespace `aif-usd-composer`。兩者都由 k8s Deployment 管理，**重開機自動啟動、crash 自動重啟**。systemd unit 已 stop+disable，僅保留作 rollback。
>
> 本文是 k8s 版的單一真相。手動/systemd 時期的文件見 [`deployment-guide.md`](deployment-guide.md)（仍適用於 緊急 rollback 與首次 build 背景）。

---

## 一、系統流程與架構

```
[Browser]  http://192.168.5.100:8082
    │
    ▼
[usd-composer-web pod]  vite dev (node:20-slim), port 8082    ← k8s Deployment（hostNetwork）
    │   WebRTC signaling  TCP 49200
    │   WebRTC media (RTP) UDP 49500
    ▼
[usd-composer-kit pod]  hostNetwork，綁 49200/49500/8112      ← k8s Deployment
    │   command = host build 的 kit 執行檔
    │   app = my_company.my_usd_composer_streaming.kit
    ▼
[NVIDIA GPU 3]  via runtimeClassName: nvidia
    UUID GPU-1e01282d-1e27-4ea3-7e1f-584762ed1ad7
```

**同一台 server 上並存的 streaming 服務（互不干擾，各據一張 GPU）：**

| 服務 | Namespace / 管理 | signaling | media(UDP) | HTTP | GPU |
| --- | --- | --- | --- | --- | --- |
| **usd-composer-kit** | **k8s `aif-usd-composer`** | **49200** | **49500** | **8112** | **GPU3** |
| **usd-composer-web** | **k8s `aif-usd-composer`** | — | — | — (8082) | — |
| dsx-stack-kit-0 | k8s `dsx-factory`（NVIDIA） | 49100 | 47998 | 8012 | 別張 |
| aif-dt-stack-kit-0 | k8s `aif-dt-factory` | 49300 | 47999 | 8212 | GPU2 |

> Port 規劃刻意錯開，三套 streaming kit + web viewer 可同時運作。

---

## 二、完整專案路徑

### Git repo
| Repo | 位置 | 內容 |
| --- | --- | --- |
| `joecpw/kit-app-deployment` | 本機 `…/DSX-BP-remote/kit-app-deployment/`；server `/home/ubuntu/DSX-BP/kit-app-deployment/` | k8s manifest、systemd unit（rollback）、啟動腳本、本文件 |

### k8s manifest（本 repo `k8s/`）
| 檔案 | 用途 |
| --- | --- |
| `k8s/namespace.yaml` | namespace `aif-usd-composer` |
| `k8s/kit-deployment.yaml` | **kit** Deployment（單一真相，含 image/GPU/port/mount/probe）|
| `k8s/web-deployment.yaml` | **web viewer** Deployment（`node:20-slim` glibc runtime 跑 hostPath 掛的 web-viewer-sample 之 vite dev，port 8082）|

### Server 上的執行檔與資產（hostPath 掛進 pod）
| 路徑 | 內容 | 大小 |
| --- | --- | --- |
| `/home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/kit/kit` | kit 執行檔（kit pod 的 `command`） | — |
| `/home/ubuntu/DSX-BP/kit-app-template/source/apps/my_company.my_usd_composer_streaming.kit` | streaming app 設定 | — |
| `/home/ubuntu/DSX-BP/kit-cae/_build/linux-x86_64/release/{exts,apps}` | kit-cae 擴充（CAE/CFD）| — |
| `/home/ubuntu/.local/share/ov` | extscache 實體資料（symlink 目標）| ~16 GB |
| `/home/ubuntu/.cache/packman` | packman 套件快取（kit pod 內 ro）| — |
| `/mnt/data/dsx-content` | NVIDIA 大型資料集；kit pod 內同時掛 `/mnt/data/dsx-content` 與 `/data/dsx-content` | ~90 GB |
| `/home/ubuntu/dsx-content` | 客製/在地內容（AIF_DT 等）| 小 |
| `/home/ubuntu/DSX-BP/web-viewer-sample` | web viewer 原始碼 + node_modules（web pod hostPath 掛載）；`stream.config.json` 指向 49200 | node_modules ~174 MB |

> 擁有者皆 `ubuntu:ubuntu`（uid 1000）→ 兩個 pod 都以 `runAsUser: 1000` 讀寫。

### Image
| Image | 用途 | 來源 |
| --- | --- | --- |
| `cr.myelintek.com/dsx/dsx-kit:2.0.6` | kit pod | 已在 containerd `k8s.io`（dsx-factory 也用），`IfNotPresent` 命中本地、免 pull |
| `docker.io/library/node:20-slim` | web pod 的 node runtime | **必須 glibc**（host node_modules 是 gnu rollup/esbuild；Alpine/musl image 會噴 `Cannot find module @rollup/rollup-linux-x64-musl`）。已 pull 進 k8s.io |

---

## 三、k8s 物件規格重點

### `usd-composer-kit` Deployment（replicas 1，`strategy: Recreate`）
- **hostNetwork**: `true` + `dnsPolicy: ClusterFirstWithHostNet`（WebRTC SDK 才能廣播正確主機 IP）。
- **GPU**: `runtimeClassName: nvidia` + env `NVIDIA_VISIBLE_DEVICES=GPU-1e01282d…` + `NVIDIA_DRIVER_CAPABILITIES=all`。**不用 `nvidia.com/gpu`**（避幽靈 UUID CrashLoop 與雙重注入）。
- **command/args 覆寫**：image 預設 entrypoint 會自動跑 DSX 自家 app，故用 `command` 指向 host build 的 kit 執行檔（等同 nerdctl `--entrypoint`），`args` 帶 `.kit` 路徑、4 條 `--ext-folder`(含 kit-cae)、`--no-window`、`--portable-root`、3 個 port 覆寫。
- **securityContext**: `runAsUser/Group 1000`、`fsGroup 1000`、`runAsNonRoot`、`drop [ALL]`、`seccomp RuntimeDefault`、`readOnlyRootFilesystem false`。
- **probes**: 皆 `tcpSocket: signaling(49200)`；startup `80 × 15s ≈ 20 分鐘`（首次 RTX shader compile）。
- **resources**: requests cpu2/mem16Gi；limits cpu8/mem64Gi。
- **mounts**：6 條 hostPath（`dsx-content` 一個 volume 掛兩路徑）。

### `usd-composer-web` Deployment（replicas 1，`strategy: Recreate`）
- **hostNetwork**: `true`（vite 直接綁 host 8082，瀏覽器入口；連 49200 由 `stream.config.json` 設定）。
- **image** `node:20-slim`（glibc），`command: ["npm"]` `args: ["run","dev","--","--host","0.0.0.0","--port","8082"]`，`workingDir` + hostPath 掛 `/home/ubuntu/DSX-BP/web-viewer-sample`，`HOME=/tmp`。
- **securityContext**: 同 kit（uid 1000…）。**probes**: `httpGet / :8082`。**resources**: req cpu100m/mem256Mi；lim cpu1/mem1Gi。

---

## 四、啟動與開機行為

- **重開機**：kubelet 自動拉起 `usd-composer-kit` + `usd-composer-web`（**無需人工**）。→ 兩者皆 reboot-safe。
- **crash**：Deployment 控制器自動重建 pod（kit 已實測 `delete pod` → 72s 回 1/1 + RTX ready）。
- **舊 systemd**：`usd-composer-streaming.service` 與 `usd-composer-webviewer.service` 皆 **stop + disable**，開機不再啟動、不搶 port。unit 檔保留作 rollback。

---

## 五、維運 Runbook

```bash
# --- 狀態 ---
kubectl -n aif-usd-composer get pods -o wide
ss -tlnp | grep -e :49200 -e :8112 -e :8082          # 49200/8112=kit, 8082=web
nvidia-smi --query-compute-apps=gpu_uuid,process_name --format=csv,noheader | grep -i kit

# --- log ---
kubectl -n aif-usd-composer logs deploy/usd-composer-kit -f
kubectl -n aif-usd-composer logs deploy/usd-composer-web -f

# --- 重啟 / 套用變更 ---
kubectl -n aif-usd-composer rollout restart deploy/usd-composer-kit
kubectl -n aif-usd-composer rollout restart deploy/usd-composer-web
# 改 port / ext-folder / GPU 後：編輯 k8s/*.yaml 再
kubectl apply -f /home/ubuntu/DSX-BP/kit-app-deployment/k8s/kit-deployment.yaml
kubectl apply -f /home/ubuntu/DSX-BP/kit-app-deployment/k8s/web-deployment.yaml

# --- 換 GPU ---
# 編輯 kit-deployment.yaml 的 NVIDIA_VISIBLE_DEVICES 為新的真實 UUID 再 apply
nvidia-smi --query-gpu=index,uuid,memory.free --format=csv,noheader

# --- 進 pod 檢查掛載 ---
kubectl -n aif-usd-composer exec deploy/usd-composer-kit -- ls /data/dsx-content
```

**驗證「正常」的訊號**：兩個 pod `1/1 Running` + `ss` 看到 49200 由 `kit` 持有、8082 由 `node` 持有 + kit log 出現 `RTX ready` + 瀏覽器 `http://192.168.5.100:8082`（Server 192.168.5.100 / Port 49200）能串流。

---

## 六、Rollback（回到 systemd 版）

k8s 版若出問題，systemd 版是現成安全網（unit 檔仍在）：

```bash
# 1. 讓出 port（49200/49500/8112 + 8082）
kubectl -n aif-usd-composer scale deploy/usd-composer-kit deploy/usd-composer-web --replicas=0
# 2. 把 systemd 版拉回來
sudo systemctl enable --now usd-composer-streaming usd-composer-webviewer
```

---

## 七、現況與後續

- ✅ **kit + web viewer 全託管於 k8s**（namespace `aif-usd-composer`，自癒 + 開機自起）。kit 在 GPU3 + 正式 port 49200/49500/8112；web 在 8082。
- 🔒 systemd 兩個 unit 已 stop+disable，保留作 rollback；確認長期穩定後可 `rm /etc/systemd/system/usd-composer-*.service` 完全退役。
- 🟡 **可攜性（Tier B，未做）**：kit 仍 hostPath 掛 build 產物 + 90GB 資料集，綁定本節點；web 也 hostPath 掛 web-viewer-sample。要搬到別台需比照 `aif-dt` 的 layered build 把 kit + extensions 烤進自包含 image + 資料改 NFS PVC（web viewer 則改 `npm run build` 出 dist 烤進 image / 用 nginx 服務）。屬獨立後續工作。

### 遷移歷程摘要
manual nerdctl → systemd（解重開機消失，過渡）→ **k8s Deployment（kit + web，最終）**。詳見 git log。

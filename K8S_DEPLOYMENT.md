# USD Composer Streaming — Kubernetes 部署與維運（權威文件）

> **狀態（2026-06-16）**：USD Composer streaming kit 已從「手動 nerdctl 容器 + systemd」遷移為 **Kubernetes 託管**，namespace `aif-usd-composer`。kit 由 k8s Deployment 管理，**重開機自動啟動、crash 自動重啟**。
>
> 本文是 k8s 版的單一真相。手動/systemd 時期的文件見 [`deployment-guide.md`](deployment-guide.md)（仍適用於 web viewer + 緊急 rollback）。

---

## 一、系統流程與架構

```
[Browser]  http://192.168.5.100:8082
    │
    ▼
[web-viewer-sample]  vite dev server, port 8082         ← 仍由 systemd 管理（usd-composer-webviewer.service）
    │   WebRTC signaling  TCP 49200
    │   WebRTC media (RTP) UDP 49500
    ▼
[usd-composer-kit pod]  namespace aif-usd-composer        ← k8s Deployment（本次遷移重點）
    │   hostNetwork=true（直接綁主機 49200/49500/8112）
    │   command = host build 的 kit 執行檔
    │   app = my_company.my_usd_composer_streaming.kit
    ▼
[NVIDIA GPU 3]  via runtimeClassName: nvidia
    UUID GPU-1e01282d-1e27-4ea3-7e1f-584762ed1ad7
```

**同一台 server 上並存的其他 kit 服務（互不干擾，各據一張 GPU）：**

| 服務 | Namespace / 管理 | signaling | media(UDP) | HTTP | GPU |
| --- | --- | --- | --- | --- | --- |
| **usd-composer-kit** | **k8s `aif-usd-composer`** | **49200** | **49500** | **8112** | **GPU3** |
| dsx-stack-kit-0 | k8s `dsx-factory`（NVIDIA） | 49100 | 47998 | 8012 | 別張 |
| aif-dt-stack-kit-0 | k8s `aif-dt-factory` | 49300 | 47999 | 8212 | GPU2 |
| web viewer | systemd（本機 vite） | — | — | — (8082) | — |

> Port 規劃刻意錯開，三套 streaming kit + web viewer 可同時運作。

---

## 二、完整專案路徑

### Git repo
| Repo | 位置 | 內容 |
| --- | --- | --- |
| `joecpw/kit-app-deployment` | 本機 `…/DSX-BP-remote/kit-app-deployment/`；server `/home/ubuntu/DSX-BP/kit-app-deployment/` | k8s manifest、systemd unit、啟動腳本、本文件 |

### k8s manifest（本 repo `k8s/`）
| 檔案 | 用途 |
| --- | --- |
| `k8s/namespace.yaml` | namespace `aif-usd-composer` |
| `k8s/kit-deployment.yaml` | kit Deployment（單一真相，含 image/GPU/port/mount/probe）|

### Server 上的執行檔與資產（hostPath 掛進 pod）
| 路徑 | 內容 | 大小 |
| --- | --- | --- |
| `/home/ubuntu/DSX-BP/kit-app-template/_build/linux-x86_64/release/kit/kit` | kit 執行檔（pod 的 `command`） | — |
| `/home/ubuntu/DSX-BP/kit-app-template/source/apps/my_company.my_usd_composer_streaming.kit` | streaming app 設定 | — |
| `/home/ubuntu/DSX-BP/kit-cae/_build/linux-x86_64/release/{exts,apps}` | kit-cae 擴充（CAE/CFD）| — |
| `/home/ubuntu/.local/share/ov` | extscache 實體資料（symlink 目標）| ~16 GB |
| `/home/ubuntu/.cache/packman` | packman 套件快取（pod 內 ro）| — |
| `/mnt/data/dsx-content` | NVIDIA 大型資料集（DSX_BP/Datacenter_NVD/GB300…）；pod 內同時掛 `/mnt/data/dsx-content` 與 `/data/dsx-content` | ~90 GB |
| `/home/ubuntu/dsx-content` | 客製/在地內容（AIF_DT 等）| 小 |
| `/home/ubuntu/DSX-BP/web-viewer-sample` | web viewer（vite）| — |

> 擁有者皆 `ubuntu:ubuntu`（uid 1000）→ pod 以 `runAsUser: 1000` 讀寫。

### Image
`cr.myelintek.com/dsx/dsx-kit:2.0.6` — 已存在於 containerd `k8s.io` namespace（`dsx-factory` 也用同一 image），故 `imagePullPolicy: IfNotPresent` 直接命中本地、不需 registry pull。

---

## 三、k8s 物件規格重點

`usd-composer-kit` Deployment（namespace `aif-usd-composer`，replicas 1，`strategy: Recreate`）：

- **hostNetwork**: `true` + `dnsPolicy: ClusterFirstWithHostNet`（WebRTC SDK 才能廣播正確主機 IP）。
- **GPU**: `runtimeClassName: nvidia` + env `NVIDIA_VISIBLE_DEVICES=GPU-1e01282d…` + `NVIDIA_DRIVER_CAPABILITIES=all`。**不使用 `nvidia.com/gpu` resource request**——避開 device-plugin 幽靈 UUID CrashLoop 與雙重注入（kit 落兩張卡）的問題。
- **command/args 覆寫**：image 預設 entrypoint 會自動跑 DSX 自家 app，故用 `command` 指向 host build 的 kit 執行檔（等同 nerdctl `--entrypoint`），`args` 帶 `.kit` 路徑、4 條 `--ext-folder`、`--no-window`、`--portable-root`、3 個 port 覆寫。
- **securityContext**: `runAsUser/Group 1000`、`fsGroup 1000`、`runAsNonRoot`、`capabilities drop [ALL]`、`seccompProfile RuntimeDefault`、`allowPrivilegeEscalation false`、`readOnlyRootFilesystem false`。
- **probes**: liveness/readiness/startup 皆 `tcpSocket: signaling(49200)`；startup `failureThreshold 80 × 15s ≈ 20 分鐘`（涵蓋首次 RTX shader compile）。
- **resources**: requests cpu2/mem16Gi；limits cpu8/mem64Gi。
- **mounts**：見上表 6 條 hostPath（`dsx-content` 一個 volume 掛兩個路徑）。

---

## 四、啟動與開機行為

- **重開機**：kubelet 自動拉起 `usd-composer-kit` pod（**無需人工**）。web viewer 由 systemd（`enabled`）自動拉起。→ **兩者都 reboot-safe**。
- **crash**：Deployment 控制器自動重建 pod（已實測 `delete pod` → 72s 內回 1/1 + RTX ready）。
- **舊 systemd kit**：`usd-composer-streaming.service` 已 **stop + disable**，開機不再啟動、不搶 49200。unit 檔保留作 rollback。

---

## 五、維運 Runbook

```bash
# --- 狀態 ---
kubectl -n aif-usd-composer get pods -o wide
ss -tlnp | grep -e :49200 -e :8112 -e :8082          # 49200/8112=kit, 8082=web viewer
nvidia-smi --query-compute-apps=gpu_uuid,process_name --format=csv,noheader | grep -i kit

# --- log ---
kubectl -n aif-usd-composer logs deploy/usd-composer-kit -f
kubectl -n aif-usd-composer logs deploy/usd-composer-kit --tail=400 | grep -i ready | grep -i rtx

# --- 重啟 / 套用變更 ---
kubectl -n aif-usd-composer rollout restart deploy/usd-composer-kit
# 改 port / ext-folder / GPU 後：編輯 k8s/kit-deployment.yaml 再
kubectl apply -f /home/ubuntu/DSX-BP/kit-app-deployment/k8s/kit-deployment.yaml

# --- 換 GPU（pin 的卡壞了或要換）---
# 編輯 kit-deployment.yaml 的 NVIDIA_VISIBLE_DEVICES 為新的真實 UUID（用 nvidia-smi 查），再 apply
nvidia-smi --query-gpu=index,uuid,memory.free --format=csv,noheader

# --- web viewer（systemd）---
sudo systemctl status|restart usd-composer-webviewer
sudo journalctl -u usd-composer-webviewer -f

# --- 進 pod 檢查掛載 ---
kubectl -n aif-usd-composer exec deploy/usd-composer-kit -- ls /data/dsx-content
```

**驗證「正常」的訊號**：pod `1/1 Running` + `ss` 看到 49200 由 `kit` 持有 + log 出現 `RTX ready` + 瀏覽器 `http://192.168.5.100:8082`（Server 192.168.5.100 / Port 49200）能串流。

---

## 六、Rollback（回到 systemd 版）

k8s 版若出問題，systemd 版是現成安全網（unit 檔仍在）：

```bash
# 1. 讓出 49200/49500/8112
kubectl -n aif-usd-composer scale deploy/usd-composer-kit --replicas=0
# 2. 把 systemd kit 拉回來
sudo systemctl enable --now usd-composer-streaming
```

---

## 七、現況與後續

- ✅ **kit 已全託管於 k8s**，正式 port 49200/49500/8112，GPU3，自癒 + 開機自起。
- 🟡 **web viewer 仍在 systemd**（`usd-composer-webviewer.service`，port 8082，已 enabled、reboot-safe）。可選後續：比照 `aif-dt` 的 web-deployment 把它也收進 k8s，達成「全 k8s」。目前留 systemd 已滿足 reboot-safe，風險最低。
- 🟡 **可攜性（Tier B）**：目前仍 hostPath 掛 build 產物 + 90GB 資料集，綁定本節點。若要搬到別台，需比照 `aif-dt` 的 layered build 把 kit + extensions 烤進自包含 image + 資料改 NFS PVC。屬獨立後續工作。
- 🔒 systemd kit unit 保留作 rollback；確認長期穩定後可移除（`rm /etc/systemd/system/usd-composer-streaming.service`）達成完全退役。

### 遷移歷程摘要
manual nerdctl → systemd（解重開機消失，過渡）→ **k8s Deployment（本文件，最終）**。詳細遷移計劃與驗證 gate 見 git log 與 `deployment-guide.md`。

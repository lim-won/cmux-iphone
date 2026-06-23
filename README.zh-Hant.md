<h1 align="center"><strong>Cmux iPhone</strong></h1>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.zh-Hans.md">简体中文</a> · <strong>繁體中文</strong>
</p>

<p align="center">
  <a href="https://github.com/lim-won/cmux-iphone/actions/workflows/ci.yml"><img src="https://github.com/lim-won/cmux-iphone/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/github/v/release/lim-won/cmux-iphone" alt="Release"/>
</p>

<p align="center">
  在 iPhone（以及 Apple Watch）上檢視並控制你的 <strong>Claude Code</strong>、<strong>Codex</strong> 與 <strong>cmux</strong> 工作階段。<br/>
  即時檢視終端機輸出、傳送提示詞；在 iPhone 上核准權限請求，並在 Apple Watch 上監看它們 —— 透過區域網路或 Tailscale。
</p>

https://github.com/user-attachments/assets/5f478c28-2086-4696-9d76-e43dda853201

---

## 運作原理（兩個部分）

```
   iPhone / Watch  ──HTTP+SSE──►  cmux-iphone 橋接 (Node)  ──hooks──►  Claude Code
   (SwiftUI App)   ◄────────────  執行於你的 Mac           ──RPC───►  cmux 鏡像
                                                           ──log───►  Codex
```

- **橋接（Mac）：** 一個小型 Node 伺服器（`cmux-iphone`），接收 Claude Code 的
  hook 事件、鏡像即時的 cmux 工作區、監看 Codex，並透過 HTTP + Server-Sent Events
  向手機提供服務。透過 Bonjour 在區域網路中被探索到。
- **App（iPhone + Watch）：** 一個 SwiftUI App，與橋接配對，顯示即時的
  工作階段/終端機輸出，並回應權限提示。

一切都執行在**你自己的裝置上** —— 無雲端、無帳號、無需託管伺服器。
橋接預設僅監聽 loopback（需明確透過 Tailscale/區域網路公開）；配對碼 + 每裝置權杖構成驗證邊界。
**請透過 Tailscale 或可信任的區域網路使用 —— 它並非為直面公開網際網路而設計**
（參見 [`SECURITY.md`](SECURITY.md)）。

> **cmux 是選用的。** 安裝 cmux 後可取得即時工作區/終端機鏡像；
> 即使沒有它，橋接仍可串流以 hook 為基礎的 Claude/Codex 工作階段。

---

## 環境需求

| 元件 | 最低版本 |
|-----------|---------|
| macOS | 13+ |
| Node.js | 18+ |
| Xcode | 16+（用於建置 App） |
| iOS / watchOS | 17 / 10 |
| Claude Code | 較新版本 |
| cmux | 選用，**0.63.2+**（使用 cmux 的 `mobile.*` RPC） |
| Tailscale | 選用（遠端存取） |

---

## 安裝 —— Mac 橋接

### Homebrew（建議）

```bash
brew install lim-won/tap/cmux-iphone
cmux-iphone setup
```

`brew upgrade cmux-iphone` 可更新它；更新後請重新執行一次 `cmux-iphone setup`，
讓 LaunchAgent / cmux 工作區重新指向新版本。

### 從原始碼安裝

```bash
git clone https://github.com/lim-won/cmux-iphone && cd cmux-iphone/skill/bridge
npm ci                        # 可重現安裝（若無 lockfile 則用 `npm install`）
npm link                      # 選用：把 `cmux-iphone` 加入你的 PATH
cmux-iphone setup             # 或：node bin/cmux-iphone.js setup
```

`cmux-iphone setup` 是**冪等的**（可安全地重複執行）。它會：

1. 檢查 macOS + Node 18+，偵測 Claude/Codex/cmux/Tailscale，
2. 寫入 `config.json` 並產生密鑰（`0600`，重複執行時絕不輪替），
3. **備份** `~/.claude/settings.json` 並合併 Cmux iPhone 的 hooks（受限範圍 ——
   絕不碰觸其他工具的 hooks），
4. 選擇一種執行方式 —— 當 cmux 存在時使用 **in-cmux**（讓即時鏡像生效），
   否則使用 **LaunchAgent**，
5. 對橋接做健康檢查，並印出你的區域網路/Tailscale 位址 + 配對碼。

> **為什麼有兩種執行方式？** `launchd` 程序無法存取 cmux 控制通訊端（已驗證）。
> 因此當 cmux 存在時，橋接執行於 cmux 工作區*內部*；
> 否則它以 LaunchAgent 執行，僅提供 hook/手機/Codex 工作階段。

### 使用 cmux 鏡像

要使用即時 cmux 鏡像，執行 setup 時 **cmux 必須正在執行且其控制通訊端可達**
（如果它使用通訊端密碼，請先設定好）。然後：

```bash
cmux-iphone setup --cmux     # 若 cmux RPC 不可達則快速失敗（而非安裝到一半）
cmux-iphone doctor           # 確認：cmux RPC = mobile.workspace.list OK
```

如果 cmux 已安裝但其通訊端不可達，setup 會停止並提示你 ——
它不會默默啟動一個無法鏡像的橋接。要完全略過 cmux、僅執行
hook/手機/Codex 工作階段：`cmux-iphone setup --launchd`。

用 CLI 管理它：

| 指令 | 作用 |
|---|---|
| `cmux-iphone setup` | 安裝 / 修復（冪等） |
| `cmux-iphone doctor` | 唯讀診斷 —— **把它貼到 GitHub issue 裡** |
| `cmux-iphone status` | 橋接狀態、區域網路/Tailscale 位址、cmux、已配對裝置 |
| `cmux-iphone pair` | 顯示配對碼 · `--list` · `--revoke <id>` |
| `cmux-iphone logs` | 追蹤 LaunchAgent 日誌（in-cmux 橋接請開啟 **Agent Bridge** 工作區） |
| `cmux-iphone restart` | 重新啟動橋接 |
| `cmux-iphone uninstall` | 移除 hooks + 服務（`--purge` 還會刪除資料） |

---

## 安裝 —— iPhone / Watch App（自行建置）

**沒有 App Store / TestFlight 建置版** —— Cmux iPhone 以原始碼形式散布，
你用自己的免費 Apple ID 來建置。（TestFlight 需要付費的 Apple Developer
Program；若專案日後加入，未來可能提供公開二進位版本。）

**1. 設定你的 bundle id**（一條指令 —— 不需 XcodeGen；iPhone id、
Watch id、以及 Watch 的伴侶 id 都由它衍生）：

```bash
./scripts/configure-ios.sh com.yourname.cmuxiphone
open ios/CmuxiPhone/CmuxiPhone.xcodeproj
```

**2. 把你的 Apple ID 加到 Xcode：** Xcode → Settings → Accounts → **+** → Apple ID
（免費帳號即可）。

**3. 在兩個 target 上都設定 Team：** 選取專案 → 對 **CmuxiPhone** 與
**CmuxiPhoneWatch**，Signing & Capabilities → *Automatically manage signing* →
**Team = 你的 Personal Team**。（bundle id 已在第 1 步設好。）

**4. 在 iPhone 上啟用開發者模式（iOS 16+）：** Settings → Privacy &
Security → **Developer Mode** → 開啟 → 重新啟動。（若要部署到 Watch，
在 Watch 上做同樣操作：Watch App / watchOS Settings → Privacy & Security。）

**5. 執行：** 接上你的 iPhone（已與 Watch 配對），選擇 **CmuxiPhone**
scheme + 你的 iPhone 作為目標 → **Run**（⌘R）。對於 Watch App，選擇
**CmuxiPhoneWatch** scheme 與已配對的 Watch 目標（若直接安裝到 watch 失敗，
則透過 iPhone 部署）。

**6. 信任開發者憑證：** 在 iPhone 上，Settings → General → VPN & Device
Management → 點選你的開發者描述檔 → **Trust**。

> **免費帳號的限制：** App 在建置後約 **7 天**過期（從 Xcode 重新執行以重新整理）、
> **無推播通知**（僅本機通知）、最多 3 台裝置。SideStore/AltStore 可無線
> 自動重新整理 *iPhone* App。
>
> 維護者：專案由 `project.yml` 透過 `xcodegen` 產生 —— 僅在你變更專案
> 結構時才需要；一般使用者使用上面的指令稿即可。

### 配對

1. 開啟 App → 輸入**配對碼**（見下文）+ Mac 的位址
   （`cmux-iphone status` 會顯示區域網路與 Tailscale 位址）。
2. 同一 Wi-Fi 下 → 橋接還會被自動探索（Bonjour），因此你可以省去
   輸入位址。跨網路時，請使用 **Tailscale 位址**，這樣無論你在
   辦公室還是在外，同一份配對都有效。

每台裝置都會取得**自己的權杖**；可用
`cmux-iphone pair --revoke <id>` 撤銷其中任一個（參見 `cmux-iphone pair --list`）。

#### 我從哪裡取得配對碼？

你不必是開發者 —— 最多兩條指令：

- **安裝時，** `cmux-iphone setup` 會在結尾印出你的配對碼（與位址）。它會
  **為每台 Mac 產生一個穩定的配對碼**並儲存 —— 它**不會**一直變動，所以你可以重複使用。
- **之後任何時候，** 執行 `cmux-iphone pair` 即可再次顯示它。

```text
$ cmux-iphone pair
Pairing code: 000000
Enter this code in the Cmux iPhone app on your iPhone.
```

> **自訂你的配對碼（選用）：** 在橋接的環境中設定 `CMUX_IPHONE_PAIR_CODE=123456`
> 來固定一個好記的配對碼。配對碼是配對的關卡（有速率限制 —— 每 5 分鐘 5 次 ——
> 且每台裝置仍取得自己的權杖），所以請保密。建議在可信任的區域網路或 Tailscale 上使用；
> 不要把橋接直接公開到公開網際網路。

> **輪替式配對碼（選用）：** 比起固定碼，更想要會輪替的碼？執行
> `cmux-iphone setup --rotating` —— 每次重新啟動都產生一個新的 6 位碼（24 小時 TTL，
> 一旦有裝置配對即清除），而非預設的每 Mac 穩定碼。

> **Watch 核准（beta）：** Watch 目前*顯示*核准，但你需要在 iPhone 上回應它們。

---

## 透過 Tailscale 遠端存取

橋接使用純 HTTP，是為你的區域網路或私人
[Tailscale](https://tailscale.com) tailnet 而設計的 —— **絕非公開網際網路**。Tailscale
讓你的 iPhone 可以從任何地方存取你的 Mac，就好像它們在同一個 Wi-Fi 上。

**1. 在兩台裝置上安裝 Tailscale，使用同一帳號。**

```bash
brew install --cask tailscale     # Mac（或下載 App），然後登入
```

在 iPhone 上，從 App Store 安裝 **Tailscale** 並用**同一**帳號登入。
現在兩台裝置共享一個私人 tailnet。

**2. 找到你 Mac 的 Tailscale 位址。**

```bash
cmux-iphone status
# Tailscale: http://100.x.y.z:7860
```

`100.x.y.z` 是你 Mac 的 tailnet IP。啟用 **MagicDNS**（Tailscale 管理
主控台）後，你可以改用 Mac 的主機名稱（例如 `your-mac`）。

**3. 用該位址配對手機。** Bonjour 自動探索僅在同一 Wi-Fi 上有效，且**不跨越
tailnet**，所以遠端存取時請手動輸入位址：在 App 中點 **Enter IP manually**，
輸入 `100.x.y.z`（或 MagicDNS 主機名稱）+ 你的配對碼（`cmux-iphone pair`）。
之後這份配對在 Wi-Fi、行動網路，或你的 tailnet 所及之處都有效 —— 無需重新配對。

**4. 公開橋接（它預設僅 loopback）。** 為了安全，橋接開箱即繫結
`127.0.0.1`，所以全新安裝絕不會被你網路上的其他人透過明文 HTTP 存取 ——
而你的手機此時也還無法存取它。選擇如何公開它：

```bash
cmux-iphone setup --bind 100.x.y.z     # Tailscale IP —— 加密，建議
cmux-iphone setup --lan                # 整個區域網路 —— 明文，僅限可信任網路
```

兩者都會把 `bindAddress` 持久化到 `config.json` 並重新啟動橋接。（`HOST` 環境變數
只影響你手動啟動的橋接 —— 受管的 launchd/cmux 服務不會繼承它，所以對於已安裝的
橋接，請使用 `setup --bind` 或編輯 `config.json`。）

重新執行 `cmux-iphone status` 以確認繫結的位址，並讓 Mac 保持喚醒以便遠端使用：
`sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1`。

> **在外有多台 Mac？** 參見 [`REMOTE-SETUP.md`](REMOTE-SETUP.md)，了解如何為每台
> Mac 命名（`office-mac-1`、…）以及在 App 中切換它們。

---

## 疑難排解

先執行 **`cmux-iphone doctor`** —— 它會印出一份 PASS/WARN/FAIL 報告（不含
密鑰），非常適合貼到 issue 裡。

- **iPhone「Connection failed」：** 執行 `cmux-iphone status` 取得橋接的
  **實際位址 + 連接埠**（它可能繫結到 7860–7869 中的另一個連接埠，或一個非 loopback
  介面），然後在那裡探測 `/health` —— 例如 `curl http://<addr>:<port>/health`
  （注意：`/status` 需要驗證）。橋接 + 手機必須共享區域網路（或 Tailscale）。
- **沒有 cmux 工作區：** cmux 只在橋接執行於 cmux *內部*時才鏡像
  （`cmux-iphone status` 會顯示執行方式）。沒有 cmux 時你仍能取得 hook 工作階段。
- **Watch/手機找不到橋接（Bonjour）：** 依序檢查 —— App 的 iOS
  **本機網路**權限；兩台裝置在**同一網路**；路由器的 **AP / 用戶端隔離**已關閉；
  **mDNS 未被封鎖**；然後退而手動輸入 **IP**（來自 `cmux-iphone status`）。
- **權限提示不出現：** 確認 `~/.claude/settings.json` 中的 hooks，
  以及已有裝置配對（`cmux-iphone pair --list`）。

---

## 運作原理（細節）

### 事件流（Mac → 手機）
Claude Code 執行一個工具 → 一個 `PostToolUse`/`PreToolUse` hook 向橋接 POST →
橋接推送一個 SSE 事件 → App 算繪它。

### 權限流（Mac → 手機 → Mac）
Claude 遇到一個權限提示 → `PermissionRequest` hook **阻擋** → 橋接推送一個
`permission-request` SSE 事件 → 手機顯示選項 → 你的選擇被 POST 回去 →
橋接把決定回傳給 Claude。
（對於 codex exec 核准，橋接會把答案鍵入*固定的* cmux 終端機，
並以螢幕雜湊作為保護 —— 若螢幕已變化則拒絕。）

已安裝的 hooks（loopback 監聽器，受密鑰保護）：`PostToolUse`、`PreToolUse`、
`PermissionRequest`（阻擋式，最長 10 分鐘）、`SessionStart`、`SessionEnd`、
`Stop`、錯誤事件。

---

## 安全

橋接預設監聽 `127.0.0.1:<port>`（僅 loopback）；把它公開給你的手機是一個
明確的選擇加入，透過 `bindAddress` / `HOST` 環境變數 / `setup --lan`
（優先選 Tailscale IP —— 加密）。攜帶外部 `Host` 標頭的請求會被拒絕
（DNS 重新繫結防護）。驗證為配對碼 + 每裝置權杖；hook 監聽器僅 loopback 且受密鑰保護。
密鑰以 `0600` 存放於儲存庫之外。建議在可信任的區域網路或 Tailscale 上使用 ——
不要把橋接直接公開到公開網際網路。完整模型 + 漏洞回報方式見
[`SECURITY.md`](SECURITY.md)。

## 授權

MIT —— 參見 [`LICENSE`](LICENSE)。

Cmux iPhone 是 [shobhit99/claude-watch](https://github.com/shobhit99/claude-watch)
（MIT）的一個 fork；原作者著作權得以保留。App 隨附**中性圖示** —— 不綑綁任何
Claude/Anthropic 或 OpenAI/Codex 的 logo 素材；「Claude」與「Codex」分別是
Anthropic 與 OpenAI 的商標，此處僅作為文字標籤使用。這是一個獨立的社群工具，
與 Anthropic 或 OpenAI 無關聯、亦未獲其背書。完整署名見 [`NOTICE.md`](NOTICE.md)。

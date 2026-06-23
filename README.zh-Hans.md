<h1 align="center"><strong>Cmux iPhone</strong></h1>

<p align="center">
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <strong>简体中文</strong> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

<p align="center">
  <a href="https://github.com/lim-won/cmux-iphone/actions/workflows/ci.yml"><img src="https://github.com/lim-won/cmux-iphone/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"/>
  <img src="https://img.shields.io/github/v/release/lim-won/cmux-iphone" alt="Release"/>
</p>

<p align="center">
  在 iPhone（以及 Apple Watch）上查看并控制你的 <strong>Claude Code</strong>、<strong>Codex</strong> 和 <strong>cmux</strong> 会话。<br/>
  实时查看终端输出、发送提示词；在 iPhone 上批准权限请求，并在 Apple Watch 上监控它们 —— 通过局域网或 Tailscale。
</p>

https://github.com/user-attachments/assets/5f478c28-2086-4696-9d76-e43dda853201

---

## 工作原理（两个部分）

```
   iPhone / Watch  ──HTTP+SSE──►  cmux-iphone 桥接 (Node)  ──hooks──►  Claude Code
   (SwiftUI 应用)  ◄────────────  运行于你的 Mac           ──RPC───►  cmux 镜像
                                                           ──log───►  Codex
```

- **桥接（Mac）：** 一个小型 Node 服务（`cmux-iphone`），接收 Claude Code 的
  hook 事件、镜像实时的 cmux 工作区、监视 Codex，并通过 HTTP + Server-Sent Events
  向手机提供服务。通过 Bonjour 在局域网中被发现。
- **应用（iPhone + Watch）：** 一个 SwiftUI 应用，与桥接配对，显示实时的
  会话/终端输出，并回应权限提示。

一切都运行在**你自己的设备上** —— 无云端、无账号、无需托管服务器。
桥接默认仅监听 loopback（需显式通过 Tailscale/局域网暴露）；配对码 + 每设备令牌构成鉴权边界。
**请通过 Tailscale 或可信局域网使用 —— 它不是为直面公网而设计的**
（参见 [`SECURITY.md`](SECURITY.md)）。

> **cmux 是可选的。** 安装 cmux 后可获得实时工作区/终端镜像；
> 即使没有它，桥接仍可流式传输基于 hook 的 Claude/Codex 会话。

---

## 环境要求

| 组件 | 最低版本 |
|-----------|---------|
| macOS | 13+ |
| Node.js | 18+ |
| Xcode | 16+（用于构建应用） |
| iOS / watchOS | 17 / 10 |
| Claude Code | 较新版本 |
| cmux | 可选，**0.63.2+**（使用 cmux 的 `mobile.*` RPC） |
| Tailscale | 可选（远程访问） |

---

## 安装 —— Mac 桥接

### Homebrew（推荐）

```bash
brew install lim-won/tap/cmux-iphone
cmux-iphone setup
```

`brew upgrade cmux-iphone` 可更新它；更新后请重新运行一次 `cmux-iphone setup`，
让 LaunchAgent / cmux 工作区重新指向新版本。

### 从源码安装

```bash
git clone https://github.com/lim-won/cmux-iphone && cd cmux-iphone/skill/bridge
npm ci                        # 可复现安装（若无 lockfile 则用 `npm install`）
npm link                      # 可选：把 `cmux-iphone` 加入你的 PATH
cmux-iphone setup             # 或：node bin/cmux-iphone.js setup
```

`cmux-iphone setup` 是**幂等的**（可安全地重复运行）。它会：

1. 检查 macOS + Node 18+，检测 Claude/Codex/cmux/Tailscale，
2. 写入 `config.json` 并生成密钥（`0600`，重复运行时绝不轮换），
3. **备份** `~/.claude/settings.json` 并合并 Cmux iPhone 的 hooks（受限作用域 ——
   绝不触碰其他工具的 hooks），
4. 选择一个运行方式 —— 当 cmux 存在时使用 **in-cmux**（让实时镜像生效），
   否则使用 **LaunchAgent**，
5. 对桥接做健康检查，并打印你的局域网/Tailscale 地址 + 配对码。

> **为什么有两种运行方式？** `launchd` 进程无法访问 cmux 控制套接字（已验证）。
> 因此当 cmux 存在时，桥接运行在 cmux 工作区*内部*；
> 否则它作为 LaunchAgent 运行，仅提供 hook/手机/Codex 会话。

### 使用 cmux 镜像

要使用实时 cmux 镜像，运行 setup 时 **cmux 必须正在运行且其控制套接字可达**
（如果它使用套接字密码，请先配置好）。然后：

```bash
cmux-iphone setup --cmux     # 若 cmux RPC 不可达则快速失败（而非半途安装）
cmux-iphone doctor           # 确认：cmux RPC = mobile.workspace.list OK
```

如果 cmux 已安装但其套接字不可达，setup 会停止并提示你 ——
它不会悄悄启动一个无法镜像的桥接。要完全跳过 cmux、仅运行
hook/手机/Codex 会话：`cmux-iphone setup --launchd`。

用 CLI 管理它：

| 命令 | 作用 |
|---|---|
| `cmux-iphone setup` | 安装 / 修复（幂等） |
| `cmux-iphone doctor` | 只读诊断 —— **把它粘贴到 GitHub issue 里** |
| `cmux-iphone status` | 桥接状态、局域网/Tailscale 地址、cmux、已配对设备 |
| `cmux-iphone pair` | 显示配对码 · `--list` · `--revoke <id>` |
| `cmux-iphone logs` | 跟踪 LaunchAgent 日志（in-cmux 桥接请打开 **Agent Bridge** 工作区） |
| `cmux-iphone restart` | 重启桥接 |
| `cmux-iphone uninstall` | 移除 hooks + 服务（`--purge` 还会删除数据） |

---

## 安装 —— iPhone / Watch 应用（自行构建）

**没有 App Store / TestFlight 构建版** —— Cmux iPhone 以源码形式分发，
你用自己的免费 Apple ID 来构建。（TestFlight 需要付费的 Apple Developer
Program；若项目日后加入，可能会提供公开二进制版本。）

**1. 设置你的 bundle id**（一条命令 —— 无需 XcodeGen；iPhone id、
Watch id、以及 Watch 的伴侣 id 都由它派生）：

```bash
./scripts/configure-ios.sh com.yourname.cmuxiphone
open ios/CmuxiPhone/CmuxiPhone.xcodeproj
```

**2. 把你的 Apple ID 加到 Xcode：** Xcode → Settings → Accounts → **+** → Apple ID
（免费账号即可）。

**3. 在两个 target 上都设置 Team：** 选中项目 → 对 **CmuxiPhone** 和
**CmuxiPhoneWatch**，Signing & Capabilities → *Automatically manage signing* →
**Team = 你的 Personal Team**。（bundle id 已在第 1 步设好。）

**4. 在 iPhone 上启用开发者模式（iOS 16+）：** Settings → Privacy &
Security → **Developer Mode** → 打开 → 重启。（若要部署到 Watch，
在 Watch 上做同样操作：Watch 应用 / watchOS Settings → Privacy & Security。）

**5. 运行：** 插上你的 iPhone（已与 Watch 配对），选择 **CmuxiPhone**
scheme + 你的 iPhone 作为目标 → **Run**（⌘R）。对于 Watch 应用，选择
**CmuxiPhoneWatch** scheme 与已配对的 Watch 目标（若直接安装到 watch 失败，
则通过 iPhone 部署）。

**6. 信任开发者证书：** 在 iPhone 上，Settings → General → VPN & Device
Management → 点击你的开发者描述文件 → **Trust**。

> **免费账号的限制：** 应用在构建后约 **7 天**过期（从 Xcode 重新运行以刷新）、
> **无推送通知**（仅本地通知）、最多 3 台设备。SideStore/AltStore 可无线
> 自动刷新 *iPhone* 应用。
>
> 维护者：项目由 `project.yml` 通过 `xcodegen` 生成 —— 仅在你更改项目
> 结构时才需要；终端用户使用上面的脚本即可。

### 配对

1. 打开应用 → 输入**配对码**（见下文）+ Mac 的地址
   （`cmux-iphone status` 会显示局域网和 Tailscale 地址）。
2. 同一 Wi-Fi 下 → 桥接还会被自动发现（Bonjour），因此你可以省去
   输入地址。跨网络时，请使用 **Tailscale 地址**，这样无论你在
   办公室还是在外，同一份配对都有效。

每台设备都会获得**自己的令牌**；可用
`cmux-iphone pair --revoke <id>` 撤销其中任意一个（参见 `cmux-iphone pair --list`）。

#### 我从哪里获取配对码？

你不必是开发者 —— 最多两条命令：

- **安装时，** `cmux-iphone setup` 会在结尾打印你的配对码（和地址）。它会
  **为每台 Mac 生成一个稳定的配对码**并保存 —— 它**不会**不停变化，所以你可以复用。
- **之后任何时候，** 运行 `cmux-iphone pair` 即可再次显示它。

```text
$ cmux-iphone pair
Pairing code: 000000
Enter this code in the Cmux iPhone app on your iPhone.
```

> **自定义你的配对码（可选）：** 在桥接的环境中设置 `CMUX_IPHONE_PAIR_CODE=123456`
> 来固定一个好记的配对码。配对码是配对的关口（有速率限制 —— 每 5 分钟 5 次 ——
> 且每台设备仍获得自己的令牌），所以请保密。建议在可信局域网或 Tailscale 上使用；
> 不要把桥接直接暴露到公网。

> **轮换式配对码（可选）：** 比起固定码，更想要会轮换的码？运行
> `cmux-iphone setup --rotating` —— 每次重启都生成一个新的 6 位码（24 小时 TTL，
> 一旦有设备配对即清除），而不是默认的每 Mac 稳定码。

> **Watch 审批（beta）：** Watch 目前*显示*审批，但你需要在 iPhone 上回应它们。

---

## 通过 Tailscale 远程访问

桥接使用纯 HTTP，是为你的局域网或私有
[Tailscale](https://tailscale.com) tailnet 而设计的 —— **绝非公网**。Tailscale
让你的 iPhone 可以从任何地方访问你的 Mac，就好像它们在同一个 Wi-Fi 上。

**1. 在两台设备上安装 Tailscale，使用同一账号。**

```bash
brew install --cask tailscale     # Mac（或下载应用），然后登录
```

在 iPhone 上，从 App Store 安装 **Tailscale** 并用**同一**账号登录。
现在两台设备共享一个私有 tailnet。

**2. 找到你 Mac 的 Tailscale 地址。**

```bash
cmux-iphone status
# Tailscale: http://100.x.y.z:7860
```

`100.x.y.z` 是你 Mac 的 tailnet IP。启用 **MagicDNS**（Tailscale 管理
控制台）后，你可以改用 Mac 的主机名（例如 `your-mac`）。

**3. 用该地址配对手机。** Bonjour 自动发现仅在同一 Wi-Fi 上有效，且**不跨越
tailnet**，所以远程访问时请手动输入地址：在应用中点 **Enter IP manually**，
输入 `100.x.y.z`（或 MagicDNS 主机名）+ 你的配对码（`cmux-iphone pair`）。
之后这份配对在 Wi-Fi、蜂窝网络，或你的 tailnet 所及之处都有效 —— 无需重新配对。

**4. 暴露桥接（它默认仅 loopback）。** 出于安全，桥接开箱即绑定
`127.0.0.1`，所以全新安装绝不会被你网络上的其他人通过明文 HTTP 访问 ——
而你的手机此时也还无法访问它。选择如何暴露它：

```bash
cmux-iphone setup --bind 100.x.y.z     # Tailscale IP —— 加密，推荐
cmux-iphone setup --lan                # 整个局域网 —— 明文，仅限可信网络
```

两者都会把 `bindAddress` 持久化到 `config.json` 并重启桥接。（`HOST` 环境变量
只影响你手动启动的桥接 —— 受管的 launchd/cmux 服务不会继承它，所以对于已安装的
桥接，请使用 `setup --bind` 或编辑 `config.json`。）

重新运行 `cmux-iphone status` 以确认绑定的地址，并让 Mac 保持唤醒以便远程使用：
`sudo pmset -a sleep 0 && sudo pmset -a disablesleep 1`。

> **在外有多台 Mac？** 参见 [`REMOTE-SETUP.md`](REMOTE-SETUP.md)，了解如何为每台
> Mac 命名（`office-mac-1`、…）以及在应用中切换它们。

---

## 故障排查

先运行 **`cmux-iphone doctor`** —— 它会打印一份 PASS/WARN/FAIL 报告（不含
密钥），非常适合粘贴到 issue 里。

- **iPhone "Connection failed"：** 运行 `cmux-iphone status` 获取桥接的
  **实际地址 + 端口**（它可能绑定到 7860–7869 中的另一个端口，或一个非 loopback
  接口），然后在那里探测 `/health` —— 例如 `curl http://<addr>:<port>/health`
  （注意：`/status` 需要鉴权）。桥接 + 手机必须共享局域网（或 Tailscale）。
- **没有 cmux 工作区：** cmux 只在桥接运行于 cmux *内部*时才镜像
  （`cmux-iphone status` 会显示运行方式）。没有 cmux 时你仍能获得 hook 会话。
- **Watch/手机找不到桥接（Bonjour）：** 依次检查 —— 应用的 iOS
  **本地网络**权限；两台设备在**同一网络**；路由器的 **AP / 客户端隔离**已关闭；
  **mDNS 未被屏蔽**；然后退而手动输入 **IP**（来自 `cmux-iphone status`）。
- **权限提示不出现：** 确认 `~/.claude/settings.json` 中的 hooks，
  以及已有设备配对（`cmux-iphone pair --list`）。

---

## 工作原理（细节）

### 事件流（Mac → 手机）
Claude Code 运行一个工具 → 一个 `PostToolUse`/`PreToolUse` hook 向桥接 POST →
桥接推送一个 SSE 事件 → 应用渲染它。

### 权限流（Mac → 手机 → Mac）
Claude 遇到一个权限提示 → `PermissionRequest` hook **阻塞** → 桥接推送一个
`permission-request` SSE 事件 → 手机显示选项 → 你的选择被 POST 回去 →
桥接把决定返回给 Claude。
（对于 codex exec 审批，桥接会把答案键入*固定的* cmux 终端，
并以屏幕哈希作为保护 —— 若屏幕已变化则拒绝。）

已安装的 hooks（loopback 监听器，受密钥保护）：`PostToolUse`、`PreToolUse`、
`PermissionRequest`（阻塞式，最长 10 分钟）、`SessionStart`、`SessionEnd`、
`Stop`、错误事件。

---

## 安全

桥接默认监听 `127.0.0.1:<port>`（仅 loopback）；把它暴露给你的手机是一个
显式的选择加入，通过 `bindAddress` / `HOST` 环境变量 / `setup --lan`
（优先选 Tailscale IP —— 加密）。携带外部 `Host` 头的请求会被拒绝
（DNS 重绑定防护）。鉴权为配对码 + 每设备令牌；hook 监听器仅 loopback 且受密钥保护。
密钥以 `0600` 存放于仓库之外。建议在可信局域网或 Tailscale 上使用 ——
不要把桥接直接暴露到公网。完整模型 + 漏洞报告方式见
[`SECURITY.md`](SECURITY.md)。

## 许可证

MIT —— 参见 [`LICENSE`](LICENSE)。

Cmux iPhone 是 [shobhit99/claude-watch](https://github.com/shobhit99/claude-watch)
（MIT）的一个 fork；原作者版权得以保留。应用附带**中性图标** —— 不捆绑任何
Claude/Anthropic 或 OpenAI/Codex 的 logo 素材；"Claude" 与 "Codex" 分别是
Anthropic 与 OpenAI 的商标，此处仅作为文本标签使用。这是一个独立的社区工具，
与 Anthropic 或 OpenAI 无关联、亦未获其背书。完整署名见 [`NOTICE.md`](NOTICE.md)。

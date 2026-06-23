# Claude 多账号工具

> English：[README.md](README.md)

一台机器上同时用多个 Claude 账号——每个跑在自己独立的 VS Code 窗口里，并行、互不影响，免去反复登出登入。适合不同项目用不同账号（工作 / 外包 / 开源 / 个人）。

两个互补的工具：

| 工具 | 作用 | 什么时候用 |
|------|------|-----------|
| **环境启动台** | 每个「环境」= 独立 `CLAUDE_CONFIG_DIR`（各自登录态）+ 独立 VS Code `--user-data-dir`。可同时开多个，各用各号。 | 想多个账号**同时并行** |
| **单窗口切号** | 原地切换「默认」登录态（mac 在钥匙串 / Windows 在文件）。一个窗口，换着登。 | 想**一个**窗口、换着用不同账号 |

## 原理

Claude Code 的登录态是跟着 `CLAUDE_CONFIG_DIR` 走的。指向一个全新目录，就是一套干净独立的登录。给每个环境配独立的 config 目录 + 独立的 VS Code 用户数据目录（逼出独立进程，环境变量才真正隔离得开），各账号就互不覆盖。

**凭据存储因系统而异，这点很关键：**

- **macOS**：OAuth 令牌存在**登录钥匙串**里（`Claude Code-credentials`），**不是文件**。
- **Windows / Linux**：令牌是文件 `~/.claude/.credentials.json`。

两个工具都已分别适配。

## 前置条件

- **macOS**：装了 VS Code（`code` 命令会自动探测）。其余全用系统自带的 `osascript`（弹窗）、`plutil`、`security`——**零安装**。
- **Windows**：PowerShell + VS Code。

## 使用 —— macOS

```sh
chmod +x claude-env-launcher.command claude-switch.command   # 仅首次
```

然后双击：

- **`claude-env-launcher.command`** —— 新建 / 打开环境
  - *新建环境* → 起名 → 选默认项目（可跳过）→ 绑定账号：
    - **现场登录** —— 开窗后 `/login` 一次（**推荐，最安全**）
    - **用当前登录的号** —— 把当前默认账号直接灌入
    - **从账号档灌入** —— 复用已存快照
  - `●` = 已登录，`○` = 未登录
  - *保存当前账号为账号档* —— 把当前登录快照下来，供以后复用
- **`claude-switch.command`** —— 原地切换默认账号
  - 切换会改写钥匙串，需**重启 claude / 新开 VS Code 窗口**才生效；已开着的会话不受影响。macOS 可能弹一次「允许访问」，点允许即可。

若 macOS 拦截（「Apple 无法验证…」），那只是 Gatekeeper 对下载文件的隔离标记，**不是病毒**。解除：`xattr -d com.apple.quarantine claude-env-launcher.command`

## 使用 —— Windows

双击桌面快捷方式或 `launch.vbs`。`ClaudeEnvLauncher.ps1` 是启动台，`claude-switch.ps1` 是原地切号。整个文件夹可绿色携带（路径自动探测）。

## 合规性

本工具**只用官方支持的机制**（`CLAUDE_CONFIG_DIR`、系统钥匙串、`code` 命令、标准 OAuth `/login`），不破解、不绕过、不规避任何东西。

**你的用法是否合规，取决于一件事：每个账号都必须是你合法拥有或被授权使用、且各自独立付费/订阅的。** 这样用（自己的付费号、做自己的事），性质等同于浏览器开多个 Profile——没问题。

**不可以**用它来叠加免费额度、用多个号绕过单订阅的用量上限、或把一个号共享/转卖给多人。请以 Anthropic 当前的 [使用政策](https://www.anthropic.com/legal/aup) 和服务条款为准。

## 安全 —— 务必读

账号登录令牌是**敏感数据**，`envs/`、`profiles/`、`backups/` 这几个目录要当密码看待：

- **加密账号档（推荐）。** 保存账号档时可设口令加密，令牌存成 `credentials.json.enc`（AES-256-CBC + PBKDF2-HMAC-SHA256 20 万次迭代，openssl `Salted__` 格式，**macOS 与 Windows 互通可互解**）。此时磁盘上**不留明文令牌**，灌入/切换时再输口令。**口令丢了无法恢复，务必记牢。**
- **正在使用的环境**（`envs/<名>/.credentials.json`）始终是明文——这点**无法避免**：`CLAUDE_CONFIG_DIR` 读的是凭据**文件**、不走钥匙串，是多账号隔离机制的固有代价（Win/mac 都一样）。加密保护的是**账号档快照**，不是运行中的环境。
- **磁盘上仅本人可读。** macOS 下脚本设 `umask 077`（新建文件/目录为 600/700）；Windows 下则把凭据文件/目录（`envs/`、`profiles/`、`backups/` 及 `~/.claude/.credentials.json`）的 NTFS ACL 收紧到**仅当前用户**——去除继承，其它账户（含管理员）一律无权访问。
- `envs/`、`profiles/`、`backups/` 已被 **git 忽略**——永远不要提交。
- **不要**同步到 iCloud / OneDrive / 坚果云等网盘，**不要**把文件夹拷给别人或别的机器。
- 想尽量少留副本：优先**现场登录**，要存账号档就**加密**存。
- 令牌泄漏 = 账号被接管。万一泄漏，重新 `/login` 一次即可让旧令牌失效。

## 文件清单

| 文件 | 作用 |
|------|------|
| `claude-env-launcher.command` | macOS 环境启动台 |
| `claude-switch.command` | macOS 单窗口切号 |
| `ClaudeEnvLauncher.ps1` | Windows 环境启动台 |
| `claude-switch.ps1` | Windows 单窗口切号 |
| `launch.vbs` | Windows 静默启动器 |
| `envs/<名>/` | 每个环境的配置 + 令牌（**敏感**，已 git 忽略） |
| `profiles/<名>/` | 已存账号快照（**敏感**，已 git 忽略） |

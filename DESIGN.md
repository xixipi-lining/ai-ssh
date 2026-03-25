# 🚀 AI-SSH: 极客级无缝 AI 命令行助手

## 1. 项目背景与需求痛点

在服务器运维和本地开发中，频繁记忆复杂的 Shell 命令是一大痛点。现有 AI CLI 工具（如 `gemini-cli`、`claude-code`）存在以下致命缺陷：

1. **远程不安全与零碎配置**：在远程服务器残留 API Key，换机器需重新登录。
2. **上下文盲区**：AI 不知道当前的操作系统类型、所在目录和环境变量，生成的命令经常"水土不服"。
3. **输入转义地狱**：需要用引号包裹自然语言，遇到特殊字符极易报错。
4. **底层协议墙**：依赖 `sshd_config` 的特定转发配置，遇到严格的安全策略直接歇菜。

**🎯 核心目标**：
打造一个**本地直调、远程透明伴生**的 AI 终端劫持工具。按下魔法快捷键，自动结合**系统/目录/剪贴板上下文**，将自然语言"原位替换"为精准命令。**无痕、绝对安全、智能降级**。

---

## 2. 核心设计理念 (Architecture Philosophy)

- **Ephemeral Bridge (阅后即焚)**：本地守护进程不再常驻。仅在执行 `aissh` 时后台静默拉起，SSH 断开时自动销毁，保持系统绝对干净。
- **Zero-Footprint (远程零侵入)**：不往远程机器写入任何永久文件。脚本与配置通过环境变量和管道注入内存。
- **Graceful Degradation (优雅降级避坑)**：
  - **避开 `StreamLocalBindUnlink` 坑**：动态生成带有时间戳+PID 的随机 Socket 路径（`/tmp/aissh-<timestamp>-<pid>.sock`），彻底解决 Socket 文件残留导致的绑定失败。
  - **避开 `AllowStreamLocalForwarding` 坑**：自动同时建立 Socket 和 TCP 双隧道，远程 Hook 智能检测可用通道并自动降级，无需手动配置。
- **Context-Aware (全景上下文感知)**：自动抓取 `$OS`, `$PWD`, `$PATH`，甚至可结合剪贴板报错日志，实现精准对症下药。
- **Pluggable AI Engine (可插拔引擎)**：内置适配器支持 `gemini`、`kimi`、`claude` 等常见工具，可通过配置扩展任意 CLI 工具。

---

## 3. 整体架构图与数据流 (Workflow)

```text
[ 本地物理机 (Local Machine) ]                     [ 远程服务器 (Remote Server) ]

 ╭─────────────────────────────────╮
 │ 【配置与底座】 ~/.ai-ssh/config   │
 │ AI_TOOL="kimi"                  │
 │ VERBOSE=false                   │
 ╰─────────────────────────────────╯
                 ▲
  [本地直连]      │[远程模式: aissh 伴生拉起]
  (绕过网络)      │                  │
 ╭───────────────┴─╮      ╭──────────┴─────────────╮
 │ 1. Local Hook   │      │ 2. Ephemeral Bridge    │ (解析 JSON，拼装 Prompt 调用底层 AI_TOOL)
 │ (本地环境劫持)    │      │ (随 aissh 启动的微服务) │
 ╰────────┬────────╯      ╰──────────┬─────────────╯
          │                          ▲
          │                 ┌────────┴─────────[-R 双隧道自动建立] ──────┐
          │                 │ 通道A: 随机 Socket (/tmp/aissh-xxx.sock) │
          │                 │ 通道B: 随机 TCP 端口 (127.0.0.1:PORT)     │
          │                 └────────▲──────────────────────────────────┘
          │                          │ (智能检测: 优先 Socket，降级 TCP)
          └─(收集 OS/PWD/ENV)        │
                     双热键触发: ╭────┴───────────────╮
[Ctrl+G] 仅当前行自然语言          │ 3. Remote Hook     │ (远程终端内存级劫持)
[Ctrl+B] 当前行 + 剪贴板内容       ╰────────────────────╯

 ╭──────────────────────────────────────────────────────────╮
 │ 4. AI-SSH Wrapper (核心启动引擎)                            │
 │ 拦截 ssh -> 动态生成隧道地址 -> 拉起 Bridge -> 注入 Remote Hook │
 ╰──────────────────────────────────────────────────────────╯
```

---

## 4. 核心组件拆解与规范

### 组件 1: 配置文件 (`~/.ai-ssh/config`)

全局控制中心，允许极客自由定制底座：

```ini
AI_TOOL="kimi"             # 内置适配器: gemini, kimi, claude, claude-code
VERBOSE=false              # 开启后在 ~/.ai-ssh/*.log 记录请求日志

# ─── 自定义工具适配（仅当 AI_TOOL 不在内置列表时生效）─
# AI_ARGS="--print --prompt"   # 自定义 CLI 参数
# AI_PARSE_RE=""               # 自定义输出提取正则
```

### 组件 2: 核心启动器 (`aissh` 命令 / Bash 脚本)

负责生命周期管理与隧道搭建：

1. **生成动态通信地址**：
   - Socket 路径：`/tmp/aissh-$(date +%s)-$$.sock`（时间戳 + PID 保证唯一）。
   - TCP 端口：从动态端口范围 `49152-65535` 随机分配。
2. **伴生启动 Bridge**：执行 `nohup python3 bridge.py <socket_path> --tcp-port <port> &`，并记录 PID。
3. **建立双隧道连接**：
   - `ssh -R <remote_sock>:<local_sock>` — Socket 隧道（优先）。
   - `ssh -R 127.0.0.1:<remote_port>:127.0.0.1:<local_port>` — TCP 隧道（降级）。
   - 使用 `ExitOnForwardFailure=no`，Socket 隧道失败不影响 SSH 连接。
4. **环境变量注入**：将动态 Socket 路径和 TCP 端口通过 `$AI_SSH_REMOTE_SOCK` 和 `$AI_SSH_TCP_PORT` 传给远程。
5. **清理 (Trap)**：通过 `trap '_stop_bridge' EXIT INT TERM` 确保 SSH 退出时 Bridge 一起阵亡。

### 组件 3: Ephemeral Bridge (本地伴生微服务 / Python)

轻量级无状态 HTTP Server，同时监听 Unix Socket 和 TCP 端口（双通道，通过 `threading` 并行）：

1. 接收 JSON Payload：`{"user_input": "查看端口", "clipboard_data": "", "os_info": "Linux", "pwd": "/var", "env_vars": "PATH=..."}`。
2. 通过**适配器层**拼装命令并调用配置的 AI 工具（`subprocess`）。
3. 返回纯净的 Shell 命令：`{"command": "ss -tlnp"}`。
4. `VERBOSE=true` 时写日志到 `~/.ai-ssh/bridge.log`。

**内置适配器**：

| 工具 | 调用方式 | 输出处理 |
|------|----------|----------|
| `gemini` | `gemini "prompt"` | 直接取 stdout |
| `kimi` | `kimi --quiet --prompt "prompt"` | 直接取 stdout（`--quiet` = 仅最终文本） |
| `claude` / `claude-code` | `claude --print --prompt "prompt"` | 直接取 stdout |
| 自定义 | `tool $AI_ARGS "prompt"` | 可选 `AI_PARSE_RE` 正则提取 |

### 组件 4: Shell Hook (按键劫持前端 / Zsh & Bash)

**一套代码，本地与远程共用**（远程通过内存注入精简版）：

1. **上下文侦测**：自动获取 `uname -a`，当前 `$PWD`，部分 `$PATH`。
2. **目标路由**（智能降级）：
   - 若不存在 `$AI_SSH_REMOTE_SOCK`，判断为**本地环境**，通过适配器直接调用本地 AI 工具。
   - 若在远程环境，优先检测 Socket 文件 `$AI_SSH_REMOTE_SOCK` 是否存在：
     - 存在 → 使用 `curl --unix-socket` 发送 JSON。
     - 不存在或失败 → 降级为 `curl http://127.0.0.1:$AI_SSH_TCP_PORT` 发送 JSON。
3. **双快捷键**：
   - `Ctrl+G`：读取当前命令行输入区文字。
   - `Ctrl+B`：读取当前命令行 + 系统剪贴板（`pbpaste`/`xclip`/`xsel`/tmux buffer）。
4. **原位替换**：清空输入区，将返回的命令写入光标处，等待用户回车确认。
5. **即时反馈**：按下热键后立即显示"正在思考..."提示（Zsh 通过 `BUFFER` + `zle -R` 强制刷新），完成后自动清除。

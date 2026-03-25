# 🚀 AI-SSH — 极客级无缝 AI 命令行助手

在终端输入自然语言，按下快捷键，自动替换为精准的 Shell 命令。  
本地直调 + 远程透明映射，零安装、零配置、凭据绝对安全。

## ✨ 功能

- **`Ctrl+G`** — 将当前行自然语言替换为 Shell 命令
- **`Ctrl+B`** — 同上 + 自动附带剪贴板内容（报错日志等）
- **本地模式** — 直接调用本地 AI 引擎，无中间件
- **远程模式** — `aissh user@server` 自动建立隧道，远程终端同样支持热键
- **智能降级** — Socket 隧道被禁时自动 fallback 到 TCP 端口转发
- **多引擎适配** — 内置支持 `gemini`、`kimi`、`claude`，可配置扩展任意 CLI 工具

## 📦 安装

```bash
git clone <repo-url> && cd aissh-v2
bash install.sh
```

安装脚本会自动：
1. 创建 `~/.ai-ssh/` 目录并复制所有组件
2. 在 `.zshrc` / `.bashrc` 中注入 Hook
3. 将 `aissh` 命令链接到 `~/.local/bin/`

## ⚙️ 配置

编辑 `~/.ai-ssh/config`：

```ini
AI_TOOL="kimi"      # 内置适配器: gemini, kimi, claude, claude-code
VERBOSE=false       # 开启调试日志

# 自定义工具（当 AI_TOOL 不在内置列表时）:
# AI_ARGS="--print --prompt"   # 自定义 CLI 参数
# AI_PARSE_RE=""               # 自定义输出提取正则
```

## 🖥️ 使用

### 本地模式

```bash
# 打开新终端，输入自然语言
$ 列出当前目录下最大的5个文件    # 然后按 Ctrl+G
$ ls -lS | head -5              # ← 自动替换

# 带剪贴板（先复制报错信息，再输入描述）
$ 帮我修复这个报错              # 然后按 Ctrl+B
```

### 远程模式

```bash
$ aissh root@myserver           # 自动启动 Bridge + 隧道
root@myserver:~$ 查看磁盘使用   # Ctrl+G 同样生效
root@myserver:~$ exit           # Bridge 自动清理
```

## 🏗️ 架构

```
~/.ai-ssh/
├── config          # 全局配置
├── hook.sh         # Shell 热键劫持 (Zsh/Bash)
├── bridge.py       # 伴生微服务 (Socket + TCP 双监听)
└── aissh           # SSH 包装器 (生命周期管理)
```

| 组件 | 定位 | 技术 |
|------|------|------|
| `hook.sh` | 快捷键劫持 + 上下文采集 + AI 适配器 | Zsh `zle` / Bash `bind -x` |
| `bridge.py` | 伴生微服务，Socket + TCP 双通道 | Python `http.server` + `threading` |
| `aissh` | SSH 包装，双隧道 + Bridge 生命周期 | Bash + `trap` |

## 📋 依赖

- Python 3（Bridge + JSON 编码）
- curl（远程模式 Hook 发送请求）
- 一个 AI CLI 工具（内置支持 `gemini`、`kimi`、`claude`）

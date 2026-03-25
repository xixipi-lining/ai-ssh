# 🚀 AI-SSH：极简无痕的 AI 命令行助手

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

在终端输入自然语言，按下快捷键，直接原地替换为精准的 Shell 命令。
支持本地直调与 SSH 远程无缝映射。**零安装、零配置、凭证绝对安全。**

---

## 🤔 为什么写这个工具？

日常开发和运维中，我们总会频繁遗忘一些复杂的 Shell 参数（比如 `tar`、`awk` 或者长串的 `docker` 命令）。现在市面上有很多优秀的 AI CLI 工具（如 `gemini-cli`, `claude-code`），它们在本地用起来很棒，但**一旦到了 SSH 远程服务器上，体验就会大打折扣**：

1. 🔑 **API Key 遗留隐患**：每次连上一台新服务器，都要重新配置一次 AI 工具的环境变量。如果把个人的付费 API Key 遗留在不受信任的远程机器上，隐患无穷。
2. 🌍 **上下文缺失**：普通的问答工具不知道你当前连的是 Ubuntu 还是 Alpine，也不知道你在哪个目录下。它生成的命令经常“水土不服”。
3. 💬 **繁琐的引号转义**：想把一段带满花括号和反斜杠的报错日志扔给 AI？在命令行里处理各种引号嵌套和转义，足以让人失去耐心。

**AI-SSH 的设计哲学很简单：不造大模型的轮子，只做最极致的连接。**

它站在现有优秀 CLI 工具的肩膀上，通过底层的「按键劫持」与「SSH 动态隧道」，把**你本地机器的 AI 算力**，安全且无痕地“投送”到任意远程终端。用完即走，绝不给服务器留下一片垃圾。

## ✨ 核心特性

- ⌨️ **原位替换 (`Ctrl+G`)**：在命令行输入自然语言，按下快捷键，直接替换为可执行命令。
- 📋 **带剪贴板求助 (`Ctrl+B`)**：触发时自动读取本地系统剪贴板（如刚复制的 Error Log），结合自然语言一起发给 AI。
- 🛡️ **绝对安全的远程模式**：使用 `aissh` 登录远程服务器，自动建立 Socket/TCP 隧道。AI API 请求全程在**本地物理机**完成，远程机器仅接收最终生成的命令。
- 🧠 **全景上下文感知**：自动抓取当前的 `$OS`、`$PWD` 等环境变量喂给模型，生成的命令更精准。
- 🔌 **高扩展性底座**：不绑定具体大模型，内置适配 `gemini`, `kimi`, `claude`，也可通过配置接入任意支持 CLI 调用的工具。

## 📦 快速安装

```bash
git clone https://github.com/xixipi-lining/aissh.git
cd aissh
bash install.sh
```

> **安装脚本会做什么？**
>
> 1. 在 `~/.ai-ssh/` 存放组件代码。
> 2. 自动检测并在 `~/.zshrc` 或 `~/.bashrc` 中注入快捷键 Hook。
> 3. 将 `aissh` 启动器链接到你的环境变量 PATH 中。

## ⚙️ 配置与依赖

**前置依赖**：本项目专注“连接映射”，真正的 AI 处理交由第三方工具。请确保你的**本地机器**已安装 Python 3、`curl`，以及至少一款 AI CLI 工具（如 `gemini-cli`）。

编辑 `~/.ai-ssh/config`，告诉 AI-SSH 你想用哪个引擎：

```ini
AI_TOOL="kimi"      # 支持: gemini, kimi, claude, claude-code
VERBOSE=false       # 设置为 true 可在 ~/.ai-ssh/bridge.log 查看请求日志

# 如果你想用非内置的自定义 CLI 工具：
# AI_ARGS="--print --prompt"   # 它的调用参数
# AI_PARSE_RE=""               # 它的输出提取正则（可选）
```

## 🖥️ 使用指南

### 场景一：本地开发 (Local)

打开终端，像平时一样打字：

```bash
$ 找出当前目录下超过 500M 的文件，打包后删除它们   # 输入完不要回车，直接按 Ctrl+G
$ find . -type f -size +500M -exec tar -czvf large_files.tar.gz {} + -delete  # ⬅️ 瞬间替换
```

_如果你刚复制了一段报错日志，输入“帮我修复这个问题”，然后按 **`Ctrl+B`**。_

### 场景二：远程运维 (SSH)

使用 `aissh` 替代普通的 `ssh` 命令（支持所有原生 ssh 参数）：

```bash
$ aissh user@192.168.1.100 -p 2222
```

登录成功后，你在远程服务器上的体验**与本地完全一致**！

```bash
user@remote:~$ 查看 nginx 占用哪个端口    # 按 Ctrl+G
user@remote:~$ sudo netstat -tulnp | grep nginx
user@remote:~$ exit                       # 退出时，本地后台伴生服务自动销毁
```

## 🏗️ 架构概览

AI-SSH 由几个极度轻量、松耦合的脚本组成，保持了 Unix 的简单哲学：

```text
~/.ai-ssh/
├── config          # 全局配置中心
├── hook.sh         # PTY 快捷键劫持与上下文采集 (Zsh/Bash)
├── bridge.py       # 本地微服务 (负责调用 AI_TOOL，支持 Socket/TCP)
├── prompt.tmpl     # XML 结构化的提示词模板
└── aissh           # 核心启动器 (管理 SSH 隧道与 Bridge 生命周期)
```

**工作流简述**：当在远程触发快捷键时，`hook.sh` 会将带有 OS 和目录信息的 JSON 打包，通过 `curl` 顺着 SSH 反向隧道发送给本地的 `bridge.py`，再由本地完成大模型请求后将纯文本命令沿隧道返回。

## 📄 许可证

本项目基于 [MIT License](LICENSE) 开源。欢迎提 PR 或 Issue 分享你适配的全新 CLI 工具！

#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  AI-SSH 一键安装脚本
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.ai-ssh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[ai-ssh]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN ]${NC} $*"; }

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  🚀 AI-SSH 安装程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─── 1. 创建安装目录 ─────────────────────────────────────
info "创建安装目录: ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
ok "安装目录就绪"

# ─── 2. 复制文件 ─────────────────────────────────────────
info "安装核心组件..."

cp "${SCRIPT_DIR}/bridge.py"  "${INSTALL_DIR}/bridge.py"
ok "Bridge 微服务 -> ${INSTALL_DIR}/bridge.py"

cp "${SCRIPT_DIR}/hook.sh"    "${INSTALL_DIR}/hook.sh"
ok "Shell Hook    -> ${INSTALL_DIR}/hook.sh"

cp "${SCRIPT_DIR}/aissh"      "${INSTALL_DIR}/aissh"
chmod +x "${INSTALL_DIR}/aissh"
ok "SSH Wrapper   -> ${INSTALL_DIR}/aissh"

# ─── 3. 配置文件（不覆盖已有配置）────────────────────────
if [[ ! -f "${INSTALL_DIR}/config" ]]; then
    cp "${SCRIPT_DIR}/config.example" "${INSTALL_DIR}/config"
    ok "配置文件      -> ${INSTALL_DIR}/config"
else
    warn "配置文件已存在，跳过 (${INSTALL_DIR}/config)"
fi

# ─── 4. 创建 aissh 符号链接到 PATH 中 ───────────────────
LOCAL_BIN="${HOME}/.local/bin"
mkdir -p "$LOCAL_BIN"

if [[ -L "${LOCAL_BIN}/aissh" ]] || [[ -f "${LOCAL_BIN}/aissh" ]]; then
    rm -f "${LOCAL_BIN}/aissh"
fi
ln -sf "${INSTALL_DIR}/aissh" "${LOCAL_BIN}/aissh"
ok "命令链接      -> ${LOCAL_BIN}/aissh"

# ─── 5. 注入 Shell Hook 到 rc 文件 ──────────────────────
HOOK_LINE="# AI-SSH Hook"
HOOK_SOURCE="source \"${INSTALL_DIR}/hook.sh\""

_inject_hook() {
    local rc_file="$1"
    if [[ -f "$rc_file" ]]; then
        if ! grep -qF "$HOOK_LINE" "$rc_file"; then
            echo "" >> "$rc_file"
            echo "$HOOK_LINE" >> "$rc_file"
            echo "$HOOK_SOURCE" >> "$rc_file"
            ok "Hook 已注入    -> ${rc_file}"
        else
            warn "Hook 已存在于 ${rc_file}，跳过"
        fi
    fi
}

# 检测当前 shell 并注入
if [[ -f "${HOME}/.zshrc" ]]; then
    _inject_hook "${HOME}/.zshrc"
fi

if [[ -f "${HOME}/.bashrc" ]]; then
    _inject_hook "${HOME}/.bashrc"
fi

# 如果两个 rc 文件都不存在，创建当前 shell 的
if [[ ! -f "${HOME}/.zshrc" ]] && [[ ! -f "${HOME}/.bashrc" ]]; then
    local_rc="${HOME}/.$(basename "${SHELL}")rc"
    touch "$local_rc"
    _inject_hook "$local_rc"
fi

# ─── 6. 检查依赖 ────────────────────────────────────────
echo ""
info "检查依赖..."

_check_dep() {
    if command -v "$1" &>/dev/null; then
        ok "$1 ✓"
    else
        warn "$1 未找到 — $2"
    fi
}

_check_dep "python3" "Bridge 需要 Python 3"
_check_dep "curl"    "远程 hook 需要 curl"

# 检查 AI 工具
if [[ -f "${INSTALL_DIR}/config" ]]; then
    # shellcheck disable=SC1090
    source "${INSTALL_DIR}/config"
    _check_dep "${AI_TOOL:-gemini}" "请安装配置的 AI 工具或修改 ${INSTALL_DIR}/config"
fi

# ─── 7. 检查 PATH ───────────────────────────────────────
if [[ ":${PATH}:" != *":${LOCAL_BIN}:"* ]]; then
    warn "${LOCAL_BIN} 不在 PATH 中"
    echo -e "    请添加以下内容到你的 shell rc 文件:"
    echo -e "    ${CYAN}export PATH=\"\${HOME}/.local/bin:\${PATH}\"${NC}"
fi

# ─── 完成 ────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✅ AI-SSH 安装完成！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "使用方法:"
echo -e "  ${CYAN}本地模式:${NC} 打开新终端，输入自然语言，按 Ctrl+G"
echo -e "  ${CYAN}远程模式:${NC} aissh user@server"
echo ""
echo "配置文件: ${INSTALL_DIR}/config"
echo ""

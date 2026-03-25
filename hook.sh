#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  AI-SSH Shell Hook — 快捷键劫持与上下文采集
#  支持 Zsh (zle) 和 Bash (bind -x) 双热键绑定
#  Ctrl+G: 仅当前行 + 环境上下文
#  Ctrl+B: 当前行 + 环境上下文 + 剪贴板内容
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

AI_SSH_CONFIG_DIR="${HOME}/.ai-ssh"
AI_SSH_CONFIG="${AI_SSH_CONFIG_DIR}/config"

# ─── 加载配置 ─────────────────────────────────────────────
_aissh_load_config() {
    AI_TOOL="gemini"
    VERBOSE="false"
    if [[ -f "$AI_SSH_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$AI_SSH_CONFIG"
    fi

    # 缓存提示词模板 (仅读取一次)
    if [[ -z "${_AISSH_PROMPT_TEMPLATE:-}" ]]; then
        local tmpl_file="${AI_SSH_CONFIG_DIR}/prompt.tmpl"
        if [[ -f "$tmpl_file" ]]; then
            _AISSH_PROMPT_TEMPLATE=$(cat "$tmpl_file")
        else
            # 默认模板
            _AISSH_PROMPT_TEMPLATE="{{os_info}}
{{pwd_info}}
{{env_info}}
{{clipboard_data}}
User request: {{user_input}}
Respond with ONLY the shell command, no explanation, no markdown fences."
        fi
    fi
}

# ─── 日志函数 ─────────────────────────────────────────────
_aissh_log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${AI_SSH_CONFIG_DIR}/hook.log"
    fi
}

# ─── 获取系统剪贴板内容 ───────────────────────────────────
_aissh_get_clipboard() {
    if command -v pbpaste &>/dev/null; then
        pbpaste 2>/dev/null
    elif command -v xclip &>/dev/null; then
        xclip -selection clipboard -o 2>/dev/null
    elif command -v xsel &>/dev/null; then
        xsel --clipboard --output 2>/dev/null
    elif [[ -n "${TMUX:-}" ]]; then
        tmux save-buffer - 2>/dev/null
    else
        echo ""
    fi
}

# ─── 收集上下文信息 ───────────────────────────────────────
_aissh_collect_context() {
    local os_info pwd_info env_info
    os_info="$(uname -a 2>/dev/null)"
    pwd_info="$(pwd)"
    env_info="PATH=${PATH}"
    echo "${os_info}|||${pwd_info}|||${env_info}"
}

# ─── AI 工具适配器：调用 + 解析输出 ──────────────────────
# 不同 AI CLI 工具有不同的调用参数和输出格式
# 这里统一适配，返回纯净的命令文本
_aissh_invoke_tool() {
    local tool="$1"
    local prompt="$2"
    local raw_output=""

    case "$tool" in
        kimi)
            raw_output=$("$tool" --quiet --prompt "$prompt" 2>/dev/null)
            echo "$raw_output"
            ;;
        claude|claude-code)
            raw_output=$("$tool" --print --prompt "$prompt" 2>/dev/null)
            echo "$raw_output"
            ;;
        gemini)
            raw_output=$("$tool" --prompt "$prompt" 2>/dev/null)
            echo "$raw_output"
            ;;
        *)
            if [[ -n "${AI_ARGS:-}" ]]; then
                # shellcheck disable=SC2086
                raw_output=$("$tool" $AI_ARGS "$prompt" 2>/dev/null)
            else
                raw_output=$("$tool" "$prompt" 2>/dev/null)
            fi
            if [[ -n "${AI_PARSE_CMD:-}" ]]; then
                echo "$raw_output" | eval "$AI_PARSE_CMD" 2>/dev/null
            else
                echo "$raw_output"
            fi
            ;;
    esac
}

# ─── 核心：调用 AI 引擎获取命令 ──────────────────────────
#  $1 = user_input (当前行内容)
#  $2 = clipboard_data (可选，剪贴板内容)
#  $3 = fetch_clipboard (可选，true/false, 远程模式下是否请求本地剪贴板)
_aissh_call_ai() {
    local user_input="$1"
    local clipboard_data="${2:-}"
    local fetch_clipboard="${3:-false}"

    _aissh_load_config

    # 收集上下文
    local ctx
    ctx="$(_aissh_collect_context)"
    local os_info pwd_info env_info
    os_info="${ctx%%|||*}"
    local rest="${ctx#*|||}"
    pwd_info="${rest%%|||*}"
    env_info="${rest#*|||}"

    _aissh_log "INPUT: ${user_input}"
    _aissh_log "CLIPBOARD (len): ${#clipboard_data}"
    _aissh_log "FETCH_CLIPBOARD: ${fetch_clipboard}"
    _aissh_log "OS: ${os_info}, PWD: ${pwd_info}"

    local result=""

    if [[ -n "${AI_SSH_REMOTE_SOCK:-}" ]]; then
        # ╌╌╌ 远程模式：通过 Unix Socket 发送到本地 Bridge ╌╌╌
        # 优雅方案：直接作为参数传给 Python，Shell 自动处理转义，不污染环境变量
        local json_payload
        json_payload=$(python3 -c 'import json, sys; print(json.dumps({
            "user_input": sys.argv[1],
            "os_info": sys.argv[2],
            "pwd": sys.argv[3],
            "env_vars": sys.argv[4],
            "clipboard_data": sys.argv[5],
            "fetch_clipboard": sys.argv[6].lower() == "true"
        }))' "$user_input" "$os_info" "$pwd_info" "$env_info" "$clipboard_data" "$fetch_clipboard")

        _aissh_log "JSON -> ${AI_SSH_REMOTE_SOCK}"
        result=$(curl -s --unix-socket "${AI_SSH_REMOTE_SOCK}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            "http://localhost/generate" | \
            python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("command",""))' 2>/dev/null)
    else
        # ╌╌╌ 本地模式：使用模板构建 Prompt ╌╌╌
        local prompt="${_AISSH_PROMPT_TEMPLATE}"
        
        # 简单字符串替换
        local os_str=""
        [[ -n "$os_info" ]] && os_str="System: ${os_info}"
        local pwd_str=""
        [[ -n "$pwd_info" ]] && pwd_str="Current directory: ${pwd_info}"
        local env_str=""
        [[ -n "$env_info" ]] && env_str="Environment: ${env_info}"
        local cb_str=""
        [[ -n "$clipboard_data" ]] && cb_str="Clipboard/Error log:\n${clipboard_data}"

        prompt="${prompt//\{\{os_info\}\}/$os_str}"
        prompt="${prompt//\{\{pwd_info\}\}/$pwd_str}"
        prompt="${prompt//\{\{env_info\}\}/$env_str}"
        prompt="${prompt//\{\{clipboard_data\}\}/$cb_str}"
        prompt="${prompt//\{\{user_input\}\}/$user_input}"

        _aissh_log "Calling ${AI_TOOL} locally (via adapter with template)"
        result=$(_aissh_invoke_tool "$AI_TOOL" "$prompt")
    fi

    # 清理结果：去除首尾空白、可能的 markdown 代码块标记
    result=$(echo "$result" | sed 's/^```[a-z]*//;s/^```//;s/```$//' | sed '/^$/d' | head -n 1)
    result=$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    _aissh_log "RESULT: ${result}"
    echo "$result"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Zsh 绑定 (zle widgets)
#  修复：使用 zle -R 立即刷新提示，完成后清除消息
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [[ -n "${ZSH_VERSION:-}" ]]; then

    # Ctrl+G: Generate — 仅当前行
    _aissh_generate_widget() {
        local user_input="$BUFFER"
        if [[ -z "$user_input" ]]; then
            zle -M "[ai-ssh] 请先输入自然语言描述"
            return
        fi
        # 先显示提示，立即刷新屏幕
        zle -R "[ai-ssh] 正在思考..."
        local cmd
        cmd="$(_aissh_call_ai "$user_input")"
        if [[ -n "$cmd" ]]; then
            BUFFER="# ${user_input}
${cmd}"
            CURSOR=${#BUFFER}
        else
            zle -M "[ai-ssh] 未能获取命令"
        fi
        zle reset-prompt
    }
    zle -N _aissh_generate_widget
    bindkey '^G' _aissh_generate_widget

    # Ctrl+B: Buffer — 当前行 + 剪贴板
    _aissh_buffer_widget() {
        local user_input="$BUFFER"
        if [[ -z "$user_input" ]]; then
            zle -M "[ai-ssh] 请先输入自然语言描述"
            return
        fi
        zle -R "[ai-ssh] 正在思考（含剪贴板）..."
        
        local clipboard=""
        local fetch_local="false"
        if [[ -n "${AI_SSH_REMOTE_SOCK:-}" ]]; then
            # 远程模式下，让 Bridge 获取本地剪贴板
            fetch_local="true"
        else
            # 本地模式，直接获取
            clipboard="$(_aissh_get_clipboard)"
        fi

        local cmd
        cmd="$(_aissh_call_ai "$user_input" "$clipboard" "$fetch_local")"
        if [[ -n "$cmd" ]]; then
            BUFFER="# ${user_input}
${cmd}"
            CURSOR=${#BUFFER}
        else
            zle -M "[ai-ssh] 未能获取命令"
        fi
        zle reset-prompt
    }
    zle -N _aissh_buffer_widget
    bindkey '^B' _aissh_buffer_widget

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Bash 绑定 (bind -x)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
elif [[ -n "${BASH_VERSION:-}" ]]; then

    # Ctrl+G: Generate — 仅当前行
    _aissh_generate_bash() {
        local user_input="${READLINE_LINE}"
        if [[ -z "$user_input" ]]; then
            echo "[ai-ssh] 请先输入自然语言描述"
            return
        fi
        echo -ne "\r\033[K[ai-ssh] 正在思考..."
        local cmd
        cmd="$(_aissh_call_ai "$user_input")"
        echo -ne "\r\033[K"
        if [[ -n "$cmd" ]]; then
            READLINE_LINE="# ${user_input}
${cmd}"
            READLINE_POINT=${#READLINE_LINE}
        fi
    }
    bind -x '"\C-g": _aissh_generate_bash'

    # Ctrl+B: Buffer — 当前行 + 剪贴板
    _aissh_buffer_bash() {
        local user_input="${READLINE_LINE}"
        if [[ -z "$user_input" ]]; then
            echo "[ai-ssh] 请先输入自然语言描述"
            return
        fi
        echo -ne "\r\033[K[ai-ssh] 正在思考（含剪贴板）..."
        
        local clipboard=""
        local fetch_local="false"
        if [[ -n "${AI_SSH_REMOTE_SOCK:-}" ]]; then
            fetch_local="true"
        else
            clipboard="$(_aissh_get_clipboard)"
        fi

        local cmd
        cmd="$(_aissh_call_ai "$user_input" "$clipboard" "$fetch_local")"
        echo -ne "\r\033[K"
        if [[ -n "$cmd" ]]; then
            READLINE_LINE="# ${user_input}
${cmd}"
            READLINE_POINT=${#READLINE_LINE}
        fi
    }
    bind -x '"\C-b": _aissh_buffer_bash'

fi

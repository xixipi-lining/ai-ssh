#!/usr/bin/env python3
"""
AI-SSH Ephemeral Bridge — 极简伴生微服务
短生命周期 Unix Socket HTTP Server，接收远程 JSON 请求，调用本地 AI 引擎返回结果。
"""

import http.server
import json
import os
import socket
import subprocess
import sys
import datetime
import threading

# ─── 配置 ─────────────────────────────────────────────────
CONFIG_DIR = os.path.expanduser("~/.ai-ssh")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config")
PROMPT_TEMPLATE_FILE = os.path.join(CONFIG_DIR, "prompt.tmpl")
SOCKET_PATH = os.path.join(CONFIG_DIR, "agent.sock")
LOG_FILE = os.path.join(CONFIG_DIR, "bridge.log")

# ─── 全局缓存 ──────────────────────────────────────────────
PROMPT_TEMPLATE_CACHE = None

def load_config():
    """从 ~/.ai-ssh/config 加载配置"""
    config = {"AI_TOOL": "gemini", "VERBOSE": "false"}
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, _, val = line.partition("=")
                    config[key.strip()] = val.strip().strip('"').strip("'")
    return config

def load_prompt_template():
    """加载并缓存提示词模板，避免多次读取磁盘"""
    global PROMPT_TEMPLATE_CACHE
    if PROMPT_TEMPLATE_CACHE is not None:
        return PROMPT_TEMPLATE_CACHE

    default_template = (
        "{{os_info}}\n"
        "{{pwd_info}}\n"
        "{{env_info}}\n"
        "{{clipboard_data}}\n"
        "User request: {{user_input}}\n"
        "Respond with ONLY the shell command, no explanation, no markdown fences."
    )

    if os.path.exists(PROMPT_TEMPLATE_FILE):
        try:
            with open(PROMPT_TEMPLATE_FILE, "r") as f:
                PROMPT_TEMPLATE_CACHE = f.read().strip()
                log(f"Prompt template loaded from {PROMPT_TEMPLATE_FILE}")
        except Exception as e:
            log(f"Error reading prompt template: {e}")
            PROMPT_TEMPLATE_CACHE = default_template
    else:
        # 尝试从当前脚本所在目录加载 (开发模式)
        dev_tmpl = os.path.join(os.path.dirname(__file__), "prompt.tmpl")
        if os.path.exists(dev_tmpl):
            try:
                with open(dev_tmpl, "r") as f:
                    PROMPT_TEMPLATE_CACHE = f.read().strip()
            except:
                PROMPT_TEMPLATE_CACHE = default_template
        else:
            PROMPT_TEMPLATE_CACHE = default_template

    return PROMPT_TEMPLATE_CACHE

CONFIG = load_config()

def log(msg):
    """VERBOSE 模式日志"""
    if CONFIG.get("VERBOSE", "false").lower() == "true":
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_FILE, "a") as f:
            f.write(f"[{ts}] {msg}\n")

def get_local_clipboard():
    """获取本地机器的剪贴板内容 (macOS 使用 pbpaste, Linux 使用 xclip/xsel)"""
    try:
        if sys.platform == "darwin":
            return subprocess.check_output(["pbpaste"], text=True, stderr=subprocess.DEVNULL)
        elif sys.platform == "linux":
            try:
                return subprocess.check_output(["xclip", "-selection", "clipboard", "-o"], text=True, stderr=subprocess.DEVNULL)
            except:
                try:
                    return subprocess.check_output(["xsel", "--clipboard", "--output"], text=True, stderr=subprocess.DEVNULL)
                except:
                    return ""
        return ""
    except Exception as e:
        log(f"Error getting local clipboard: {e}")
        return ""

def build_prompt(payload):
    """使用模板组装提示词"""
    tmpl = load_prompt_template()

    # 准备替换字典
    os_info = f"System: {payload.get('os_info', '')}" if payload.get("os_info") else ""
    pwd_info = f"Current directory: {payload.get('pwd', '')}" if payload.get("pwd") else ""
    env_info = f"Environment: {payload.get('env_vars', '')}" if payload.get("env_vars") else ""
    clipboard_data = f"Clipboard/Error log:\n{payload.get('clipboard_data', '')}" if payload.get("clipboard_data") else ""
    user_input = payload.get("user_input", "")

    # 执行替换
    prompt = tmpl.replace("{{os_info}}", os_info) \
                 .replace("{{pwd_info}}", pwd_info) \
                 .replace("{{env_info}}", env_info) \
                 .replace("{{clipboard_data}}", clipboard_data) \
                 .replace("{{user_input}}", user_input)

    # 移除由于空变量导致的连续换行
    import re
    prompt = re.sub(r'\n{3,}', '\n\n', prompt).strip()
    return prompt

def call_ai(prompt):
    """通过适配器调用配置的 AI 引擎"""
    tool = CONFIG.get("AI_TOOL", "gemini")

    # ─── 内置适配器注册表 ────────────────────────────────
    # 每个适配器定义: cmd_args(额外命令行参数), parse(输出解析函数)
    ADAPTERS = {
        "gemini": {
            "cmd": lambda t, p: [t, "--prompt", p],
            "parse": lambda out: out.strip(),
        },
        "kimi": {
            "cmd": lambda t, p: [t, "--quiet", "--prompt", p],
            "parse": lambda out: out.strip(),
        },
        "claude": {
            "cmd": lambda t, p: [t, "--print", "--prompt", p],
            "parse": lambda out: out.strip(),
        },
        "claude-code": {
            "cmd": lambda t, p: [t, "--print", "--prompt", p],
            "parse": lambda out: out.strip(),
        },
    }

    adapter = ADAPTERS.get(tool)

    try:
        if adapter:
            cmd = adapter["cmd"](tool, prompt)
            parse_fn = adapter["parse"]
        else:
            # 通用降级: 支持 config 中的 AI_ARGS 自定义参数
            custom_args = CONFIG.get("AI_ARGS", "").split()
            cmd = [tool] + custom_args + [prompt] if custom_args else [tool, prompt]
            parse_fn = _make_custom_parser()

        log(f"CMD: {cmd}")
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=120
        )
        output = result.stdout.strip()
        if not output:
            output = result.stderr.strip()

        return parse_fn(output)

    except FileNotFoundError:
        return f"Error: AI tool '{tool}' not found. Please install it or update ~/.ai-ssh/config"
    except subprocess.TimeoutExpired:
        return "Error: AI tool timed out after 120 seconds"
    except Exception as e:
        return f"Error: {e}"

def _make_custom_parser():
    """根据 config 中的 AI_PARSE_RE 创建自定义解析器"""
    pattern = CONFIG.get("AI_PARSE_RE", "")
    if pattern:
        import re
        def parser(output):
            matches = re.findall(pattern, output, re.DOTALL)
            return matches[-1].strip() if matches else output.strip()
        return parser
    return lambda out: out.strip()

class BridgeHandler(http.server.BaseHTTPRequestHandler):
    """处理来自远程 Hook 的 HTTP 请求"""

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        log(f"REQ  <- {body}")

        try:
            payload = json.loads(body)
            # 💡 核心修复：如果请求要求获取本地剪贴板，则在本地 Bridge 中抓取
            if payload.get("fetch_clipboard") is True:
                log("Fetching local clipboard for remote request...")
                payload["clipboard_data"] = get_local_clipboard()
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"invalid json"}')
            return

        prompt = build_prompt(payload)
        log(f"PROMPT: {prompt}")

        answer = call_ai(prompt)
        log(f"RESP -> {answer}")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"command": answer}).encode("utf-8"))

    def log_message(self, fmt, *args):
        """静默 HTTP 日志，仅 VERBOSE 时输出"""
        if CONFIG.get("VERBOSE", "false").lower() == "true":
            log(f"HTTP: {fmt % args}")

class UnixSocketServer(http.server.HTTPServer):
    """Unix Domain Socket HTTP Server"""
    address_family = socket.AF_UNIX

    def server_bind(self):
        # 清理残留 socket 文件
        if os.path.exists(self.server_address):
            os.unlink(self.server_address)
        super().server_bind()

def main():
    sock_path = None
    tcp_port = None

    # 解析参数: bridge.py [socket_path] [--tcp-port PORT]
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--tcp-port" and i + 1 < len(args):
            tcp_port = int(args[i + 1])
            i += 2
        else:
            sock_path = args[i]
            i += 1

    sock_path = sock_path or SOCKET_PATH

    # 确保配置目录存在
    os.makedirs(CONFIG_DIR, exist_ok=True)

    servers = []

    # ─── Unix Socket Server ──────────────────────────────
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    unix_server = UnixSocketServer(sock_path, BridgeHandler)
    os.chmod(sock_path, 0o600)
    servers.append(("unix", unix_server))
    log(f"Bridge started on {sock_path} (AI_TOOL={CONFIG.get('AI_TOOL')})")
    print(f"[ai-ssh bridge] Listening on {sock_path}", file=sys.stderr)

    # ─── TCP Server (可选，用于 AllowStreamLocalForwarding=no 降级) ──
    if tcp_port:
        tcp_server = http.server.HTTPServer(("127.0.0.1", tcp_port), BridgeHandler)
        servers.append(("tcp", tcp_server))
        log(f"Bridge TCP fallback on 127.0.0.1:{tcp_port}")
        print(f"[ai-ssh bridge] TCP fallback on 127.0.0.1:{tcp_port}", file=sys.stderr)

    # 每个 server 在独立线程运行
    threads = []
    for name, srv in servers:
        t = threading.Thread(target=srv.serve_forever, daemon=True)
        t.start()
        threads.append((name, srv, t))

    try:
        # 主线程阻塞等待
        for _, _, t in threads:
            t.join()
    except KeyboardInterrupt:
        pass
    finally:
        for name, srv, _ in threads:
            srv.shutdown()
            srv.server_close()
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        log("Bridge stopped")

if __name__ == "__main__":
    main()

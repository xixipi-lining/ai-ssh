# AI-SSH (aissh) Project Context

This project provides an AI-powered command-line companion that allows users to generate shell commands from natural language directly in their terminal, supporting both local and remote (SSH) environments.

## Project Overview

AI-SSH bridges the gap between local AI capabilities and remote server management. It works by running a "Bridge" service on your local machine and injecting "Hooks" into your shell sessions.

### Key Technologies
- **Bash/Zsh**: Shell scripting for the main wrapper and terminal hooks.
- **Python 3**: Implements the background bridge service.
- **SSH**: Uses reverse port forwarding (`-R`) to tunnel requests from remote servers back to the local bridge.
- **AI Providers**: Supports OpenAI-compatible APIs and CLI tools like `gemini-cli`, `claude-code`, etc.

### Architecture
1.  **`aissh` (Wrapper)**: A bash script that replaces the standard `ssh` command. It starts the local bridge, establishes the SSH tunnel, and injects the hook into the remote session.
2.  **`bridge.py` (Bridge Service)**: A lightweight Python HTTP server that receives JSON requests (context + user input), calls the configured AI provider, and returns the generated shell command.
3.  **`hook.sh` (Shell Hook)**: Injected into the local or remote shell. It binds `Ctrl+G` and `Ctrl+B` to capture the current command line and system context.
4.  **Reverse Tunnel**: Maps a remote Unix Socket or TCP port to the local bridge, ensuring security (no API keys on the remote server) and "zero-footprint" on the remote host.

## Building and Running

### Installation
The project provides an installation script that sets up the environment in `~/.ai-ssh/`.

```bash
bash install.sh
```

This script:
- Copies core components to `~/.ai-ssh/`.
- Creates a symbolic link for `aissh` in `~/.local/bin/`.
- Injects `source ~/.ai-ssh/hook.sh` into `~/.zshrc` or `~/.bashrc`.

### Configuration
Configuration is stored in `~/.ai-ssh/config`. Users can choose between "API Direct" mode (OpenAI) or "Client Proxy" mode (using local CLI tools).

Example `~/.ai-ssh/config`:
```ini
AI_TOOL="openai"
OPENAI_API_KEY="sk-..."
OPENAI_MODEL="gpt-4o"
```

### Usage
- **Local**: Type natural language in the terminal and press `Ctrl+G`.
- **Remote**: Connect to a server using `aissh user@host` and use `Ctrl+G` / `Ctrl+B` as if you were local.
- **Local Prompt Mode**: Press `Ctrl+G` on an empty command line to trigger a local native input dialog (zero network latency for typing).

## Development Conventions

### Coding Style
- **Shell Scripts**: Use `set -euo pipefail` for robustness. Use `shellcheck` for linting.
- **Python**: Use standard library modules where possible (e.g., `http.server`, `urllib.request`) to minimize dependencies.
- **Architecture**: Maintain the separation between the transport layer (`aissh`), the logic layer (`bridge.py`), and the UI layer (`hook.sh`).

### Key Files
- `aissh`: Entry point for SSH sessions. Manages lifecycle of the bridge and tunnel.
- `bridge.py`: The "brains" that talks to AI providers.
- `hook.sh`: The terminal UI logic (hotkey bindings, context collection).
- `prompt.tmpl`: Customizable AI prompt template.
- `install.sh`: Setup script.

### Testing
Currently, the project relies on manual testing. Future development should consider adding unit tests for `bridge.py` and integration tests for the tunneling mechanism.

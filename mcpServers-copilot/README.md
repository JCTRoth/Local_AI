# MCP Servers for VS Code Copilot

One-shot configuration for Chrome DevTools, Docker MCP Toolkit, Google MCP Toolbox, Kubernetes, and Microsoft Learn MCP servers.

## Quick Start

```bash
# Preview what the installer will do
./mcpServers-copilot/install.sh --dry-run

# Run the installer from the workspace root
chmod +x ./mcpServers-copilot/install.sh
./mcpServers-copilot/install.sh

# Edit your database config if you plan to use Google Toolbox
nano tools.yaml
```

The installer copies the tracked kit files from `mcpServers-copilot/` into the workspace root:

- `.vscode/mcp.json`
- `tools.yaml`

If a root `tools.yaml` already exists, the installer keeps it in place so your credentials are not overwritten.

## Copilot instructions

VS Code only loads workspace Copilot instructions from supported root locations such as `.github/copilot-instructions.md` or `.vscode/copilot-instructions.md`.

For this workspace, the shared MCP usage rules live in `.github/copilot-instructions.md` at the repository root, not inside `mcpServers-copilot/`.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Cross-platform installer for MCP client prerequisites |
| `mcp.json` | VS Code MCP server definitions copied to `.vscode/mcp.json` |
| `tools.yaml` | Google Toolbox database connection template copied to the workspace root |

## What This Script Installs

- Node.js 20+ for `npx`-based MCP servers
- VS Code and the GitHub Copilot extensions
- Workspace config files copied from this folder

## What This Script Does Not Install

- Docker Desktop or Docker Engine
- Kubernetes or `kubectl`
- Chrome or Chromium
- Databases

Instead, it checks whether Docker, `kubectl`, Chrome, and kubeconfig exist and prints warnings with manual follow-up steps if anything is missing.

## Post-Install

1. Open VS Code and switch Copilot Chat to Agent mode.
2. Start the servers from `.vscode/mcp.json`.
3. Update `tools.yaml` with your database connection if you need Google Toolbox.

## Server Details

| Server | Type | Prerequisite | Install Method |
|--------|------|--------------|----------------|
| Chrome DevTools | stdio | Chrome or Chromium running | `npx` |
| Docker MCP | stdio | Docker support on the machine | `docker` |
| Google Toolbox | stdio | Database connection | `npx` |
| Kubernetes | stdio | `kubectl` and kubeconfig | `npx` |
| Microsoft Learn | http | None | Remote |

## Security Note

- The root `tools.yaml` can contain database credentials. This repo ignores `/tools.yaml` so generated credentials do not get committed.
- The Kubernetes MCP server uses your local `~/.kube/config`. Keep RBAC scoped appropriately.
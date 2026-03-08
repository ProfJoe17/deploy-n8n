# deploy-n8n

> A single-file Bash deployment manager for [n8n](https://n8n.io) that spins up n8n **plus** its external Python/JS task-runner sidecar via Docker Compose — with version management, automated backups, live log tailing, and more.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Options](#options)
- [update vs upgrade](#update-vs-upgrade)
- [Examples](#examples)
- [Architecture](#architecture)
- [File Layout](#file-layout)
- [Automated Upgrades (Cron)](#automated-upgrades-cron)
- [Ollama / Local AI Integration](#ollama--local-ai-integration)
- [Backup & Restore](#backup--restore)
- [Environment Variables](#environment-variables)
- [FAQ](#faq)
- [Contributing](#contributing)
- [License](#license)

---

## Features

| Capability | Detail |
|---|---|
| **One-command deploy** | `./deploy-n8n.sh start` handles everything end-to-end |
| **External task runners** | Spins up `n8nio/runners` sidecar automatically, pinned to the same version as n8n |
| **Interactive version picker** | `update` fetches the 10 latest n8n releases from Docker Hub and lets you choose |
| **One-click upgrade** | `upgrade` finds the newest release and redeploys — ideal for cron |
| **Downgrade support** | Select any older release via `update` with explicit confirmation |
| **Automated backups** | `backup` snapshots the Docker volume to a `.tar.gz` archive; keeps the 10 most recent |
| **Interactive restore** | `restore` shows a numbered list of your backups to choose from |
| **Concurrency lock** | PID-file locking prevents overlapping deployments |
| **Persistent config** | Port, timezone, container name, etc. are saved and reloaded automatically |
| **Health checks** | Both containers include Docker health checks; `start -d` waits for healthy |
| **Ollama-ready** | `host.docker.internal` is mapped to the host gateway so n8n can reach a local Ollama instance |
| **Basic auth** | Optional HTTP basic authentication with `-b` |
| **CI/CD friendly** | `-f` skips all confirmation prompts; `upgrade -f -r` is fully non-interactive |

---

## Requirements

| Dependency | Notes |
|---|---|
| **Docker Engine** ≥ 20.10 | [Install guide](https://docs.docker.com/engine/install/) |
| **Docker Compose plugin** v2 | Bundled with Docker Desktop; `docker compose version` to verify |
| **Bash** ≥ 4.0 | Pre-installed on most Linux distros; macOS users may need `brew install bash` |
| **openssl** | Used to generate the runner auth token; almost always pre-installed |
| **curl** or **wget** | Required for `update` / `upgrade` version fetching |
| **python3** *(optional)* | Used for robust JSON parsing and semver comparison; falls back to grep/sort |

> **macOS note:** The default `/bin/bash` on macOS is version 3. Install a modern Bash with `brew install bash` and run the script explicitly with `/usr/local/bin/bash deploy-n8n.sh`.

---

## Quick Start

```bash
# 1. Download
curl -fsSL https://raw.githubusercontent.com/ProfJoe17/deploy-n8n/main/deploy-n8n.sh \
  -o deploy-n8n.sh

# 2. Make executable
chmod +x deploy-n8n.sh

# 3. Deploy (foreground — Ctrl+C to stop)
./deploy-n8n.sh start

# — or — deploy in the background with auto-restart on reboot
./deploy-n8n.sh start -d -r
```

Open **http://localhost:5678** in your browser to access the n8n UI.

---

## Commands

```
./deploy-n8n.sh [COMMAND] [OPTIONS]
```

| Command | Description |
|---|---|
| `start` | Deploy and start n8n *(default when no command given)* |
| `stop` | Stop and remove all running containers |
| `restart` | Restart containers without recreating them |
| `status` | Show container health, version, volume size, and backup count |
| `logs [service] [lines]` | Live-tail container logs (`n8n` or `n8n-runners`; default: both) |
| `update` | Interactive picker — choose from the 10 latest n8n releases |
| `upgrade` | One-click upgrade to the latest stable release |
| `backup` | Snapshot the n8n data volume to a compressed archive |
| `restore [archive]` | Restore from a backup (interactive picker or explicit path) |
| `reset` | **Destructive** — wipe all n8n data (workflows, credentials, executions) |
| `uninstall` | **Destructive** — remove everything: containers, images, volume, and config |
| `help` | Show the full built-in help |

---

## Options

| Flag | Description | Default |
|---|---|---|
| `-s` | Skip version/update check — use cached version, start instantly | off |
| `-u` | Auto-pull latest image without prompts | off |
| `-d` | Detached / background mode | off |
| `-r` | Auto-restart containers on system reboot (`unless-stopped` policy) | off |
| `-f` | Force — skip all confirmation prompts (CI/CD safe) | off |
| `-b` | Enable HTTP basic authentication (prompts for credentials) | off |
| `-n NAME` | Container name | `n8n` |
| `-p PORT` | Host port to expose | `5678` |
| `-t TIMEZONE` | Container timezone (e.g. `America/New_York`) | system timezone |
| `-e FILE` | Path to an extra `.env` file injected into the container | — |
| `-w URL` | Webhook base URL (e.g. `https://n8n.example.com`) | — |
| `-l LEVEL` | Log level: `error` \| `warn` \| `info` \| `debug` | `info` |
| `-h` | Show help | — |

---

## update vs upgrade

Both commands manage the n8n version, but they serve different purposes:

### `update` — Interactive version picker

```
./deploy-n8n.sh update
```

Fetches the **10 most recent stable releases** from Docker Hub and displays them in a numbered list. The currently installed version is highlighted with `▶` in green, and releases newer than what you have are marked with `↑` in cyan.

```
  Available n8n versions  (current: 1.95.3)
  ─────────────────────────────────────────────
     1)  1.98.2        ↑ ← latest
     2)  1.97.1        ↑
     3)  1.96.0        ↑
▶   4)  1.95.3          ← installed
     5)  1.94.1
     6)  1.93.0
     ...

  Enter number to install (or q to quit):
```

- Supports **downgrades** (with explicit `yes` confirmation)
- Always **creates a backup** before applying any change
- Use `-f` to skip all confirmation prompts

### `upgrade` — Non-interactive fast-path

```
./deploy-n8n.sh upgrade
```

Fetches only the **single latest release**, compares it to what you have, and upgrades if newer. If you're already on the latest, it exits cleanly — perfect for cron jobs.

```bash
# Cron: check for upgrades every Sunday at 3 AM, fully automated
0 3 * * 0  /path/to/deploy-n8n.sh upgrade -f -r >> /var/log/n8n-upgrade.log 2>&1
```

---

## Examples

```bash
# Quick local start (foreground)
./deploy-n8n.sh start

# Background, survive reboots
./deploy-n8n.sh start -d -r

# Custom port and container name
./deploy-n8n.sh start -d -p 8080 -n my-n8n

# Production: webhook URL + env file + auto-restart
./deploy-n8n.sh start -d -r -w https://n8n.example.com -e ~/n8n.env

# Fast daily restart — skip version check, use cached version
./deploy-n8n.sh start -s -d

# Enable basic auth (interactive credential prompt)
./deploy-n8n.sh start -d -b

# Interactive version picker
./deploy-n8n.sh update

# One-click upgrade (with confirmation)
./deploy-n8n.sh upgrade

# Fully automated upgrade for cron (no prompts, auto-restart)
./deploy-n8n.sh upgrade -f -r

# Tail logs from all containers
./deploy-n8n.sh logs

# Tail only the main n8n container (last 200 lines)
./deploy-n8n.sh logs n8n 200

# Show status (version, health, volume size, backup count)
./deploy-n8n.sh status

# Create a backup
./deploy-n8n.sh backup

# Interactive restore picker
./deploy-n8n.sh restore

# Restore from a specific file
./deploy-n8n.sh restore ~/.n8n-deploy/backups/n8n_backup_20250101_120000.tar.gz

# Wipe data for a clean slate
./deploy-n8n.sh reset

# Fully remove n8n (containers, images, volume, config)
./deploy-n8n.sh uninstall
```

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Docker network: n8n-net             │
│                                                      │
│  ┌──────────────────────┐   ┌──────────────────────┐ │
│  │      n8n             │   │    n8n-runners        │ │
│  │  (n8nio/n8n:x.y.z)  │◄──│ (n8nio/runners:x.y.z)│ │
│  │                      │   │                       │ │
│  │  Port 5678 → host    │   │  Task broker client   │ │
│  │  Port 5679 (lo only) │   │  Python + JS runner   │ │
│  └──────────────────────┘   └──────────────────────┘ │
│           │                           │               │
│           └──────── n8n_data ─────────┘               │
│                  (Docker volume)                      │
└─────────────────────────────────────────────────────┘
           │
           ▼
  host.docker.internal:11434  ←  Ollama (on host)
```

**Key design decisions:**

- **Version pinning:** Both `n8nio/n8n` and `n8nio/runners` are always pulled and deployed at the **same version**. n8n requires this — mixing versions causes the task broker handshake to fail.
- **Task broker isolation:** Port `5679` (the task broker) is bound to `127.0.0.1` on the host. The runners container reaches it via the internal Docker network (`http://n8n:5679`), never through the host interface.
- **Shared volume:** Both containers mount `n8n_data` so the runners can access the same credentials and workflow data as the main process.
- **Health checks:** Both services define Docker health checks. The `start -d` command waits up to 120 seconds for n8n to become healthy before returning.

---

## File Layout

```
~/.n8n-deploy/
├── docker-compose.yml    # Auto-generated on every start/update/upgrade
├── .config               # Persisted settings (port, name, timezone, cached version)
├── .runner_token         # Shared HMAC token (chmod 600, never committed)
├── .lock                 # PID lock (auto-removed on exit)
└── backups/
    ├── n8n_backup_20250301_120000.tar.gz
    ├── n8n_backup_20250308_030000.tar.gz
    └── ...                # Up to 10 most recent kept automatically
```

> **Note:** `docker-compose.yml` is regenerated on every `start`, `update`, and `upgrade`. If you need permanent custom overrides, use a `.env` file passed with `-e`, or create a `docker-compose.override.yml` in the same directory (Docker Compose merges it automatically).

---

## Automated Upgrades (Cron)

Add to your crontab (`crontab -e`):

```cron
# Check for n8n updates every Sunday at 3:00 AM
0 3 * * 0  /path/to/deploy-n8n.sh upgrade -f -r >> /var/log/n8n-upgrade.log 2>&1
```

- `-f` skips all confirmation prompts
- `-r` ensures containers restart automatically after a reboot
- If n8n is already on the latest version, the command exits cleanly with no changes

---

## Ollama / Local AI Integration

Both the `n8n` and `n8n-runners` containers have `host.docker.internal` mapped to the host gateway via `extra_hosts`. This means you can run [Ollama](https://ollama.ai) on your machine and connect to it from inside n8n without any extra network configuration.

In the n8n **Ollama credential**, set the base URL to:

```
http://host.docker.internal:11434
```

No API key is required for a local Ollama instance.

---

## Backup & Restore

### Creating a backup

```bash
./deploy-n8n.sh backup
```

Creates a timestamped `.tar.gz` archive of the `n8n_data` Docker volume in `~/.n8n-deploy/backups/`. The 10 most recent backups are kept; older ones are pruned automatically.

### Restoring from a backup

**Interactive picker** (recommended):
```bash
./deploy-n8n.sh restore
```

**Direct path:**
```bash
./deploy-n8n.sh restore ~/.n8n-deploy/backups/n8n_backup_20250101_120000.tar.gz
```

Restore stops the running containers, wipes the volume, extracts the archive, then exits — run `./deploy-n8n.sh start` afterwards to bring n8n back up.

### Manual restore (without this script)

The archives are plain `tar.gz` files. You can restore manually:

```bash
docker run --rm \
  -v n8n_data:/data \
  -v /path/to/backups:/backup:ro \
  alpine tar -xzf /backup/n8n_backup_TIMESTAMP.tar.gz -C /data
```

---

## Environment Variables

| Variable | Description |
|---|---|
| `N8N_DEPLOY_DIR` | Override the default deploy directory (default: `~/.n8n-deploy`) |

You can also pass additional n8n environment variables via an `.env` file using the `-e` flag. See the [n8n environment variables reference](https://docs.n8n.io/hosting/configuration/environment-variables/) for all available options.

---

## FAQ

**Q: Why does the script manage both `n8nio/n8n` and `n8nio/runners`?**

Since n8n 1.x, Python and JavaScript code nodes run in an **external task runner** process for security isolation. The runners image must match the n8n version exactly. This script detects and pins both to the same version automatically.

**Q: Can I run multiple n8n instances on the same machine?**

Yes. Use `-n` and `-p` to give each instance a unique container name and port:

```bash
./deploy-n8n.sh start -n n8n-prod -p 5678 -d -r
./deploy-n8n.sh start -n n8n-dev  -p 5679 -d
```

You'll also want to set `N8N_DEPLOY_DIR` to a different path for each instance so their configs don't collide:

```bash
N8N_DEPLOY_DIR=~/.n8n-prod ./deploy-n8n.sh start -n n8n-prod -p 5678 -d -r
N8N_DEPLOY_DIR=~/.n8n-dev  ./deploy-n8n.sh start -n n8n-dev  -p 5680 -d
```

**Q: How do I pass custom environment variables to n8n?**

Create a `.env` file and pass it with `-e`:

```bash
# ~/n8n.env
N8N_ENCRYPTION_KEY=my-secret-key
N8N_EMAIL_MODE=smtp
N8N_SMTP_HOST=smtp.example.com
```

```bash
./deploy-n8n.sh start -d -r -e ~/n8n.env
```

**Q: The `-s` flag doesn't seem to skip the version check.**

`-s` requires a previously cached version. On the very first run, or after `uninstall`, there is no cache — the script falls through to detection automatically. On subsequent runs, `-s` will use the cached value and start instantly.

**Q: I get "docker compose: command not found".**

This script requires Docker Compose **v2** (the plugin version). Install it via:

```bash
# Ubuntu/Debian
sudo apt-get install docker-compose-plugin

# Or update Docker Desktop to a recent version
```

**Q: Can I use this on macOS?**

Yes, with Docker Desktop for Mac. Note that macOS ships with Bash 3 — you may need to install Bash 4+ via Homebrew and invoke the script explicitly:

```bash
brew install bash
/opt/homebrew/bin/bash deploy-n8n.sh start -d
```

---

## Contributing

Issues and pull requests are welcome. Please open an issue first to discuss significant changes.

When submitting a PR:
- Test against both Linux and macOS
- Run `shellcheck deploy-n8n.sh` and address any warnings
- Keep the script self-contained (no extra files required to run)

---

## License

[MIT](LICENSE) © ProfJoe17

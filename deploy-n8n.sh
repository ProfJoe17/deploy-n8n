#!/bin/bash
# =============================================================================
#  deploy-n8n.sh — n8n deployment manager
#  Manages n8n + external Python/JS task runners via Docker Compose
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ─── Script metadata ──────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"

# ─── Defaults ─────────────────────────────────────────────────────────────────
DEPLOY_DIR="${N8N_DEPLOY_DIR:-$HOME/.n8n-deploy}"
CONTAINER_NAME="n8n"
VOLUME_NAME="n8n_data"
HOST_PORT=5678
TIMEZONE="$(cat /etc/timezone 2>/dev/null || echo 'UTC')"
AUTO_UPDATE=false
SKIP_UPDATE=false
DETACHED=false
AUTO_RESTART=false
FORCE=false
BASIC_AUTH=false
BASIC_AUTH_USER=""
BASIC_AUTH_PASS=""
ENV_FILE=""
WEBHOOK_URL=""
BACKUP_DIR="${DEPLOY_DIR}/backups"
LOG_LEVEL="info"

# ─── Derived paths ────────────────────────────────────────────────────────────
compose_file()  { echo "${DEPLOY_DIR}/docker-compose.yml"; }
token_file()    { echo "${DEPLOY_DIR}/.runner_token"; }
config_file()   { echo "${DEPLOY_DIR}/.config"; }
lock_file()     { echo "${DEPLOY_DIR}/.lock"; }

# ─── Colours ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED=$'\033[0;31m';   GREEN=$'\033[0;32m';  YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m';  BOLD=$'\033[1m';      DIM=$'\033[2m';  NC=$'\033[0m'
  MAGENTA=$'\033[0;35m'; BLUE=$'\033[0;34m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; NC=''
  MAGENTA=''; BLUE=''
fi

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✔]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[✖]${NC}    $*" >&2; }
die()     { error "$*"; exit 1; }
step()    { echo -e "\n${BOLD}▶  $*${NC}"; }
dim()     { echo -e "${DIM}$*${NC}"; }

# ─── Trap & cleanup ───────────────────────────────────────────────────────────
_TMPDIR=""
cleanup() {
  local code=$?
  [ -n "$_TMPDIR" ] && rm -rf "$_TMPDIR"
  rm -f "$(lock_file)" 2>/dev/null || true
  [ $code -ne 0 ] && [ $code -ne 130 ] && error "Script exited with error (code $code)."
  exit $code
}
trap cleanup EXIT
trap 'echo ""; die "Interrupted."' INT TERM

# ─── Locking (prevent concurrent runs) ───────────────────────────────────────
acquire_lock() {
  local lock; lock="$(lock_file)"
  mkdir -p "$DEPLOY_DIR"
  if [ -f "$lock" ]; then
    local pid; pid=$(cat "$lock" 2>/dev/null || echo "?")
    if kill -0 "$pid" 2>/dev/null; then
      die "Another instance is running (PID $pid). Use -f to override."
    fi
    warn "Stale lock found — removing."
    rm -f "$lock"
  fi
  echo $$ > "$lock"
}

# ─── Prerequisite checks ──────────────────────────────────────────────────────
check_prerequisites() {
  local missing=()
  command -v docker  &>/dev/null || missing+=("docker")
  command -v openssl &>/dev/null || missing+=("openssl")

  if ! docker compose version &>/dev/null; then
    missing+=("docker-compose-plugin (v2)")
  fi

  if [ ${#missing[@]} -ne 0 ]; then
    error "Missing required tools: ${missing[*]}"
    echo  "  Install guide: https://docs.docker.com/engine/install/"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Start it with: sudo systemctl start docker"
  fi
}

# ─── Persist / load config ────────────────────────────────────────────────────
save_config() {
  mkdir -p "$DEPLOY_DIR"
  cat > "$(config_file)" <<EOF
CONTAINER_NAME=${CONTAINER_NAME}
VOLUME_NAME=${VOLUME_NAME}
HOST_PORT=${HOST_PORT}
TIMEZONE=${TIMEZONE}
AUTO_RESTART=${AUTO_RESTART}
BACKUP_DIR=${BACKUP_DIR}
LOG_LEVEL=${LOG_LEVEL}
N8N_CACHED_VERSION=${N8N_CACHED_VERSION:-}
EOF
}

load_config() {
  local cfg; cfg="$(config_file)"
  # shellcheck source=/dev/null
  [ -f "$cfg" ] && source "$cfg" || true
}

# ─── Version detection ────────────────────────────────────────────────────────
# Strategy (fastest → slowest):
#   1. -s flag: return cached version immediately, no network at all
#   2. docker inspect label: reads OCI label from local image (instant, no container)
#   3. docker run fallback: spawns a container to read package.json (slow, last resort)
# Result is always cached to .config for future runs.
N8N_CACHED_VERSION=""   # populated by load_config

detect_n8n_version() {
  # ── 1. Skip mode: trust the cache ──────────────────────────────────────────
  if [ "$SKIP_UPDATE" = true ]; then
    if [ -n "$N8N_CACHED_VERSION" ]; then
      info "Skipping update check — using cached version ${GREEN}${N8N_CACHED_VERSION}${NC}  (remove -s to check for updates)"
      echo "$N8N_CACHED_VERSION"
      return
    else
      warn "-s given but no cached version found; falling through to detection."
    fi
  fi

  # ── 2. Fast path: read OCI label from already-pulled image ─────────────────
  local ver
  ver=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    docker.n8n.io/n8nio/n8n:latest 2>/dev/null || true)

  # ── 3. Slow fallback: spin up a container and read package.json ─────────────
  if [ -z "$ver" ]; then
    info "Image label not available — running version probe (one-time, ~5s)..."
    docker pull docker.n8n.io/n8nio/n8n:latest &>/dev/null || true
    ver=$(docker run --rm --entrypoint="" \
      docker.n8n.io/n8nio/n8n:latest \
      node -e "process.stdout.write(require('/usr/local/lib/node_modules/n8n/package.json').version)" \
      2>/dev/null) || true
  fi

  [ -z "$ver" ] && die "Could not determine n8n version. Check Docker / network connectivity."

  # Cache for next run
  N8N_CACHED_VERSION="$ver"
  echo "$ver"
}

# ─── HTTP helper (curl or wget) ───────────────────────────────────────────────
# Usage: http_get <url>
# Returns the response body on stdout; returns 1 on failure.
http_get() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl -sf --connect-timeout 10 --max-time 20 "$url" 2>/dev/null
  elif command -v wget &>/dev/null; then
    wget -qO- --timeout=20 "$url" 2>/dev/null
  else
    return 1
  fi
}

# ─── Semver comparison ────────────────────────────────────────────────────────
# version_gt A B  →  returns 0 (true) if A > B, 1 otherwise.
# Uses sort -V (GNU coreutils); falls back to python3 if unavailable.
version_gt() {
  local a="$1" b="$2"
  if [ "$a" = "$b" ]; then return 1; fi

  if sort --version-sort /dev/null &>/dev/null; then
    # GNU sort available
    local highest
    highest=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)
    [ "$highest" = "$a" ]
  elif command -v python3 &>/dev/null; then
    python3 - "$a" "$b" <<'EOF'
import sys
def semver(v):
    try: return tuple(int(x) for x in v.split('.'))
    except: return (0, 0, 0)
sys.exit(0 if semver(sys.argv[1]) > semver(sys.argv[2]) else 1)
EOF
  else
    # Last resort: lexicographic (imperfect but usually fine for n8n's linear versioning)
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort | tail -n1)" = "$a" ]
  fi
}

# ─── Fetch version list from Docker Hub ───────────────────────────────────────
# Queries the Docker Hub tags API, filters for semver tags (x.y.z), and
# returns up to N versions (default 10), most-recent first.
#
# Usage: fetch_n8n_versions [count]
# Output: newline-delimited list of version strings, e.g.
#   1.98.2
#   1.97.1
#   ...
fetch_n8n_versions() {
  local count="${1:-10}"
  # We request a larger page to have enough semver candidates after filtering
  # out rolling tags (latest, nightly, next, ai, etc.)
  local api_url="https://hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=100&ordering=last_updated"

  local raw
  raw=$(http_get "$api_url") || {
    warn "Could not reach Docker Hub API. Check network connectivity."
    return 1
  }

  # Parse with python3 (preferred — reliable JSON parsing)
  if command -v python3 &>/dev/null; then
    python3 - "$count" <<EOF
import json, sys, re
count = int(sys.argv[1])
try:
    data = json.loads("""${raw}""")
except Exception:
    # Fallback: try stdin approach
    import os
    data = json.loads(os.environ.get('_RAW','{}'))

semver_re = re.compile(r'^\d+\.\d+\.\d+$')
tags = [t['name'] for t in data.get('results', []) if semver_re.fullmatch(t['name'])]
print('\n'.join(tags[:count]))
EOF
  else
    # Pure-bash fallback using grep
    echo "$raw" \
      | grep -oE '"name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
      | head -n "$count"
  fi
}

# ─── Get the currently deployed n8n version ───────────────────────────────────
# Checks (in order): running container label → cached config value → "unknown"
get_current_deployed_version() {
  # 1. Running container label
  local ver
  ver=$(docker inspect --format \
    '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    "${CONTAINER_NAME}" 2>/dev/null | tr -d '[:space:]') || true

  # 2. Cached config value
  if [ -z "$ver" ] && [ -n "${N8N_CACHED_VERSION:-}" ]; then
    ver="$N8N_CACHED_VERSION"
  fi

  # 3. Parse from running image tag in compose file
  if [ -z "$ver" ] && [ -f "$(compose_file)" ]; then
    ver=$(grep -m1 'image:.*n8nio/n8n' "$(compose_file)" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || true
  fi

  echo "${ver:-unknown}"
}

# ─── Interactive version picker ───────────────────────────────────────────────
# Displays a numbered list of up to 10 recent versions.
# Highlights the currently installed version.
# Returns the selected version string in the global SELECTED_VERSION variable.
#
# Usage:  pick_n8n_version [count]
# Sets:   SELECTED_VERSION
SELECTED_VERSION=""

pick_n8n_version() {
  local count="${1:-10}"
  local current; current=$(get_current_deployed_version)

  step "Fetching latest n8n releases from Docker Hub..."
  local versions_raw
  versions_raw=$(fetch_n8n_versions "$count") || die "Unable to retrieve version list."

  # Load into array
  local versions=()
  while IFS= read -r v; do
    [ -n "$v" ] && versions+=("$v")
  done <<< "$versions_raw"

  [ ${#versions[@]} -eq 0 ] && die "No versions returned from Docker Hub."

  echo ""
  echo -e "${BOLD}  Available n8n versions${NC}  (${DIM}current: ${YELLOW}${current}${NC}${DIM})${NC}"
  echo -e "  ${DIM}─────────────────────────────────────────────${NC}"

  local i=1
  for v in "${versions[@]}"; do
    local marker="   "
    local label=""
    local colour="${NC}"

    if [ "$v" = "${versions[0]}" ]; then
      label="${DIM} ← latest${NC}"
    fi

    if [ "$v" = "$current" ]; then
      marker="${GREEN}▶  ${NC}"
      label="${GREEN} ← installed${NC}"
      colour="${GREEN}"
    fi

    # Is this version newer than current?
    local upgrade_marker=""
    if [ "$current" != "unknown" ] && version_gt "$v" "$current" && [ "$v" != "$current" ]; then
      upgrade_marker=" ${CYAN}↑${NC}"
    fi

    printf "  %s%2d)  ${colour}%-12s${NC}%b%b\n" \
      "$marker" "$i" "$v" "$upgrade_marker" "$label"
    i=$((i+1))
  done

  echo ""
  echo -e "  ${DIM}${CYAN}↑${NC}${DIM} = newer than installed  ${GREEN}▶${NC}${DIM} = currently installed${NC}"
  echo ""
  read -rp "  Enter number to install (or q to quit): " sel

  [[ "$sel" =~ ^[Qq]$ ]] && { info "Cancelled."; exit 0; }

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#versions[@]} ]; then
    die "Invalid selection: ${sel}"
  fi

  SELECTED_VERSION="${versions[$((sel-1))]}"
  echo ""
  info "Selected: ${BOLD}n8n v${SELECTED_VERSION}${NC}"
}

# ─── Apply a chosen version (shared by update + upgrade) ─────────────────────
# Usage: apply_n8n_version <version>
apply_n8n_version() {
  local ver="$1"
  local n8n_image="docker.n8n.io/n8nio/n8n:${ver}"
  local runners_image="docker.io/n8nio/runners:${ver}"
  local current; current=$(get_current_deployed_version)

  if [ "$ver" = "$current" ]; then
    info "Version ${GREEN}${ver}${NC} is already deployed. No changes needed."
    info "Use ${BOLD}restart${NC} to force a fresh container start."
    return 0
  fi

  if version_gt "$current" "$ver" && [ "$current" != "unknown" ]; then
    warn "You are downgrading from ${YELLOW}${current}${NC} → ${RED}${ver}${NC}."
    if [ "$FORCE" != true ]; then
      read -rp "$(echo -e "  Downgrade confirmed? (yes/N): ")" confirm
      [[ "$confirm" == "yes" ]] || { info "Cancelled."; exit 0; }
    fi
  fi

  info "Creating pre-install backup..."
  cmd_backup

  pull_images "$n8n_image" "$runners_image"

  local auth_token; auth_token=$(ensure_runner_token)
  local restart_policy="no"
  [ "$AUTO_RESTART" = true ] && restart_policy="unless-stopped"

  write_compose "$n8n_image" "$runners_image" "$auth_token" "$restart_policy"

  info "Recreating containers with n8n v${ver}..."
  docker compose -f "$(compose_file)" up -d --force-recreate

  N8N_CACHED_VERSION="$ver"
  save_config

  success "Operation complete → n8n ${GREEN}v${ver}${NC}"

  local direction=""
  if [ "$current" != "unknown" ]; then
    if version_gt "$ver" "$current"; then
      direction=" (upgraded from v${current})"
    else
      direction=" (downgraded from v${current})"
    fi
  fi
  dim "  ${direction}"
}

# ─── Auth token ───────────────────────────────────────────────────────────────
ensure_runner_token() {
  local tok_file; tok_file="$(token_file)"
  if [ -f "$tok_file" ]; then
    cat "$tok_file"
  else
    local tok; tok=$(openssl rand -hex 32)
    mkdir -p "$DEPLOY_DIR"
    echo "$tok" > "$tok_file"
    chmod 600 "$tok_file"
    info "Generated new runner auth token → ${tok_file}"
    echo "$tok"
  fi
}

# ─── Write docker-compose.yml ─────────────────────────────────────────────────
write_compose() {
  local n8n_image="$1"
  local runners_image="$2"
  local auth_token="$3"
  local restart_policy="$4"

  local env_block=""
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    env_block="    env_file:
      - $(realpath "$ENV_FILE")"
  fi

  local basic_auth_block=""
  if [ "$BASIC_AUTH" = true ] && [ -n "$BASIC_AUTH_USER" ]; then
    basic_auth_block="      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${BASIC_AUTH_PASS}"
  fi

  local webhook_block=""
  if [ -n "$WEBHOOK_URL" ]; then
    webhook_block="      - WEBHOOK_URL=${WEBHOOK_URL}"
  fi

  mkdir -p "$DEPLOY_DIR"
  cat > "$(compose_file)" <<EOF
# Auto-generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Edit manually with care — it will be overwritten on next deploy.

networks:
  n8n-net:
    driver: bridge

volumes:
  ${VOLUME_NAME}:

services:

  # ── Main n8n application ───────────────────────────────────────────────────
  n8n:
    image: ${n8n_image}
    container_name: ${CONTAINER_NAME}
    restart: ${restart_policy}
    ports:
      - "${HOST_PORT}:5678"
      - "127.0.0.1:5679:5679"     # Task broker (loopback only)
    environment:
      - GENERIC_TIMEZONE=${TIMEZONE}
      - N8N_LOG_LEVEL=${LOG_LEVEL}
      - N8N_RUNNERS_ENABLED=true
      - N8N_RUNNERS_MODE=external
      - N8N_RUNNERS_BROKER_LISTEN_ADDRESS=0.0.0.0
      - N8N_RUNNERS_AUTH_TOKEN=${auth_token}
${basic_auth_block}
${webhook_block}
    volumes:
      - ${VOLUME_NAME}:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"   # reach host Ollama at host.docker.internal:11434
    networks:
      - n8n-net
    depends_on:
      - n8n-runners
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
${env_block}

  # ── External task runners (Python + JS) ────────────────────────────────────
  n8n-runners:
    image: ${runners_image}
    container_name: ${CONTAINER_NAME}-runners
    restart: ${restart_policy}
    environment:
      - N8N_RUNNERS_TASK_BROKER_URI=http://${CONTAINER_NAME}:5679
      - N8N_RUNNERS_AUTH_TOKEN=${auth_token}
    volumes:
      - ${VOLUME_NAME}:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"   # reach host Ollama at host.docker.internal:11434
    networks:
      - n8n-net
    healthcheck:
      test: ["CMD", "pgrep", "-f", "task-runner"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
EOF
  success "docker-compose.yml written → $(compose_file)"
}

# ─── Pull images ──────────────────────────────────────────────────────────────
pull_images() {
  local n8n_image="$1" runners_image="$2"
  info "Pulling n8n image     → ${n8n_image}"
  docker pull "$n8n_image"    || die "Failed to pull n8n image."
  info "Pulling runners image → ${runners_image}"
  docker pull "$runners_image" || die "Failed to pull runners image. Check: https://hub.docker.com/r/n8nio/runners/tags"
  success "All images up to date."
}

# ─── Wait for healthy ─────────────────────────────────────────────────────────
wait_healthy() {
  local name="$1" timeout="${2:-120}"
  info "Waiting for ${name} to become healthy (up to ${timeout}s)..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local s
    s=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "none")
    case "$s" in
      healthy)   echo ""; success "${name} is healthy."; return 0 ;;
      unhealthy) echo ""; error "${name} is unhealthy."; docker logs --tail 30 "$name"; return 1 ;;
    esac
    sleep 5; elapsed=$((elapsed+5))
    echo -n "."
  done
  echo ""
  warn "Timed out waiting for ${name}. Check logs with: ${SCRIPT_NAME} logs"
  return 1
}

# ─── COMMAND: backup ──────────────────────────────────────────────────────────
cmd_backup() {
  step "Backing up n8n data"
  check_prerequisites

  local ts; ts=$(date '+%Y%m%d_%H%M%S')
  local archive="${BACKUP_DIR}/n8n_backup_${ts}.tar.gz"
  mkdir -p "$BACKUP_DIR"

  info "Volume  : ${VOLUME_NAME}"
  info "Archive : ${archive}"

  docker run --rm \
    -v "${VOLUME_NAME}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar -czf "/backup/n8n_backup_${ts}.tar.gz" -C /data . \
    || die "Backup failed."

  local size; size=$(du -sh "$archive" | cut -f1)
  success "Backup complete → ${archive} (${size})"

  # Prune — keep 10 most recent
  local count; count=$(ls -1 "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null | wc -l)
  if [ "$count" -gt 10 ]; then
    info "Pruning old backups (keeping 10 most recent)..."
    ls -1t "${BACKUP_DIR}"/n8n_backup_*.tar.gz | tail -n +11 | xargs rm -f
  fi
}

# ─── COMMAND: restore ─────────────────────────────────────────────────────────
cmd_restore() {
  local archive="$1"
  step "Restoring n8n data"
  check_prerequisites

  if [ -z "$archive" ]; then
    echo ""
    info "Available backups:"
    local backups=()
    mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null || true)
    if [ ${#backups[@]} -eq 0 ]; then
      die "No backups found in ${BACKUP_DIR}"
    fi
    local i=1
    for b in "${backups[@]}"; do
      local sz; sz=$(du -sh "$b" | cut -f1)
      printf "  %2d)  %s  [%s]\n" $i "$(basename "$b")" "$sz"
      i=$((i+1))
    done
    echo ""
    read -rp "Enter number to restore (or q to quit): " sel
    [[ "$sel" =~ ^[Qq]$ ]] && exit 0
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le ${#backups[@]} ] \
      || die "Invalid selection."
    archive="${backups[$((sel-1))]}"
  fi

  [ -f "$archive" ] || die "Archive not found: ${archive}"

  warn "This will OVERWRITE all data in volume '${VOLUME_NAME}'."
  if [ "$FORCE" != true ]; then
    read -rp "Are you sure? (yes/N): " confirm
    [[ "$confirm" == "yes" ]] || { info "Restore cancelled."; exit 0; }
  fi

  if [ -f "$(compose_file)" ]; then
    info "Stopping running containers..."
    docker compose -f "$(compose_file)" down 2>/dev/null || true
  fi

  info "Restoring from: ${archive}"
  docker run --rm \
    -v "${VOLUME_NAME}:/data" \
    -v "$(dirname "$(realpath "$archive")"):/backup:ro" \
    alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar -xzf '/backup/$(basename "$archive")' -C /data" \
    || die "Restore failed."

  success "Restore complete. Run '${SCRIPT_NAME} start' to bring n8n back up."
}

# ─── COMMAND: logs ────────────────────────────────────────────────────────────
cmd_logs() {
  local service="${1:-}"
  local lines="${2:-100}"
  local cf; cf="$(compose_file)"
  [ -f "$cf" ] || die "No deployment found. Run '${SCRIPT_NAME} start' first."

  if [ -n "$service" ]; then
    exec docker compose -f "$cf" logs --tail "$lines" -f "$service"
  else
    exec docker compose -f "$cf" logs --tail "$lines" -f
  fi
}

# ─── COMMAND: status ─────────────────────────────────────────────────────────
cmd_status() {
  local cf; cf="$(compose_file)"
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  n8n Deployment Status${NC}"
  echo -e "${BOLD}════════════════════════════════════════════${NC}"

  if [ ! -f "$cf" ]; then
    warn "No deployment config found at $(compose_file)"
    return
  fi

  docker compose -f "$cf" ps 2>/dev/null || warn "Could not query containers."

  echo ""
  info "Compose file : $(compose_file)"
  info "Volume       : ${VOLUME_NAME}"
  info "UI           : http://localhost:${HOST_PORT}"

  local cur_ver; cur_ver=$(get_current_deployed_version)
  info "n8n version  : ${GREEN}${cur_ver}${NC}"

  local vol_size
  vol_size=$(docker run --rm -v "${VOLUME_NAME}:/data:ro" alpine du -sh /data 2>/dev/null | cut -f1 || echo "unknown")
  info "Volume size  : ${vol_size}"

  local nb; nb=$(ls -1 "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null | wc -l || echo 0)
  info "Backups      : ${nb} (in ${BACKUP_DIR})"
  echo ""
}

# ─── COMMAND: stop ────────────────────────────────────────────────────────────
cmd_stop() {
  step "Stopping n8n"
  local cf; cf="$(compose_file)"
  [ -f "$cf" ] || { warn "No deployment config found."; return; }
  docker compose -f "$cf" down && success "All containers stopped." || error "Stop failed."
}

# ─── COMMAND: restart ─────────────────────────────────────────────────────────
cmd_restart() {
  step "Restarting n8n"
  local cf; cf="$(compose_file)"
  [ -f "$cf" ] || die "No deployment config found. Run '${SCRIPT_NAME} start' first."
  docker compose -f "$cf" restart && success "Restarted." || error "Restart failed."
}

# ─── COMMAND: update ──────────────────────────────────────────────────────────
#
#  Presents an interactive picker of the latest 10 n8n releases from Docker Hub.
#  The currently installed version is highlighted. Versions newer than the
#  currently installed one are marked with ↑. The user selects a version
#  (which may be newer, the same, or older — downgrade is supported with a
#  warning and explicit confirmation). A backup is created automatically before
#  any change is applied.
#
#  Flags:
#    -f   Skip confirmation prompts (non-interactive / CI use)
#    -r   Enable auto-restart policy in the updated compose file
# ─────────────────────────────────────────────────────────────────────────────
cmd_update() {
  step "n8n — interactive version update"
  check_prerequisites
  acquire_lock

  pick_n8n_version 10
  apply_n8n_version "$SELECTED_VERSION"
}

# ─── COMMAND: upgrade ─────────────────────────────────────────────────────────
#
#  Non-interactive fast-path: fetches the single latest stable release from
#  Docker Hub and installs it if it is newer than what is currently deployed.
#
#  Behaviour:
#    • Already on latest  → reports current version, exits cleanly.
#    • Newer available    → shows current → latest diff, confirms (unless -f),
#                           backs up, pulls, and redeploys.
#
#  This is intentionally distinct from 'update':
#    • upgrade = "just take me to the latest, no version picker needed"
#    • update  = "show me 10 versions and let me choose"
#
#  Flags:
#    -f   Skip confirmation prompt (non-interactive / cron-safe)
#    -r   Enable auto-restart in compose file after upgrade
# ─────────────────────────────────────────────────────────────────────────────
cmd_upgrade() {
  step "n8n — upgrade to latest"
  check_prerequisites
  acquire_lock

  local current; current=$(get_current_deployed_version)
  info "Installed version : ${YELLOW}${current}${NC}"

  info "Fetching latest release from Docker Hub..."
  local latest
  latest=$(fetch_n8n_versions 1) || die "Could not retrieve latest version from Docker Hub."
  [ -z "$latest" ] && die "Docker Hub returned an empty version list."

  info "Latest available  : ${GREEN}${latest}${NC}"
  echo ""

  if [ "$current" = "$latest" ]; then
    success "You are already on the latest version (${GREEN}${latest}${NC}). Nothing to do."
    return 0
  fi

  if ! version_gt "$latest" "$current" && [ "$current" != "unknown" ]; then
    warn "The latest published tag (${latest}) is not newer than your installed version (${current})."
    warn "This can happen if Docker Hub indexing is lagged. No changes applied."
    return 0
  fi

  echo -e "  ${BOLD}Upgrade plan:${NC}"
  echo -e "  ${DIM}  current  :${NC}  ${YELLOW}v${current}${NC}"
  echo -e "  ${DIM}  target   :${NC}  ${GREEN}v${latest}${NC}  ${CYAN}↑ upgrade${NC}"
  echo ""

  if [ "$FORCE" != true ]; then
    read -rp "  Proceed with upgrade? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Upgrade cancelled."; exit 0; }
  fi

  apply_n8n_version "$latest"
}

# ─── COMMAND: reset ───────────────────────────────────────────────────────────
cmd_reset() {
  step "Resetting n8n (wipe all data)"
  warn "This will PERMANENTLY delete all n8n workflows, credentials, and executions."
  if [ "$FORCE" != true ]; then
    read -rp "Type 'DELETE' to confirm: " confirm
    [ "$confirm" = "DELETE" ] || { info "Reset cancelled."; exit 0; }
  fi

  local cf; cf="$(compose_file)"
  if [ -f "$cf" ]; then
    info "Stopping containers..."
    docker compose -f "$cf" down 2>/dev/null || true
  fi

  info "Removing volume ${VOLUME_NAME}..."
  docker volume rm "$VOLUME_NAME" 2>/dev/null || warn "Volume not found (already removed?)."

  success "Reset complete. Run '${SCRIPT_NAME} start' for a fresh instance."
}

# ─── COMMAND: uninstall ───────────────────────────────────────────────────────
cmd_uninstall() {
  step "Uninstalling n8n"
  warn "This removes all containers, images, the data volume, and all deploy config."
  if [ "$FORCE" != true ]; then
    read -rp "Type 'UNINSTALL' to confirm: " confirm
    [ "$confirm" = "UNINSTALL" ] || { info "Uninstall cancelled."; exit 0; }
  fi

  local cf; cf="$(compose_file)"
  if [ -f "$cf" ]; then
    docker compose -f "$cf" down --rmi all 2>/dev/null || true
  fi

  docker volume rm "$VOLUME_NAME" 2>/dev/null || true
  rm -rf "$DEPLOY_DIR"
  success "n8n fully uninstalled."
}

# ─── COMMAND: start ───────────────────────────────────────────────────────────
cmd_start() {
  step "Starting n8n"
  check_prerequisites
  load_config
  acquire_lock

  # Detect version — fast by default, skip entirely with -s
  if [ "$SKIP_UPDATE" = true ]; then
    info "Detecting n8n version (skip-update mode)..."
  else
    info "Detecting n8n version..."
    # Pull :latest only when auto-update requested OR no local image exists
    if [ "$AUTO_UPDATE" = true ] || \
       [ -z "$(docker images -q docker.n8n.io/n8nio/n8n:latest 2>/dev/null)" ]; then
      info "Pulling latest n8n image..."
      docker pull docker.n8n.io/n8nio/n8n:latest &>/dev/null
    fi
  fi
  local ver; ver=$(detect_n8n_version)
  info "n8n version: ${GREEN}${ver}${NC}"

  local n8n_image="docker.n8n.io/n8nio/n8n:${ver}"
  local runners_image="docker.io/n8nio/runners:${ver}"

  # Pull / update images
  local cached_n8n; cached_n8n=$(docker images -q "$n8n_image" 2>/dev/null || true)
  local cached_runners; cached_runners=$(docker images -q "$runners_image" 2>/dev/null || true)

  if [ "$AUTO_UPDATE" = true ] || [ -z "$cached_n8n" ] || [ -z "$cached_runners" ]; then
    pull_images "$n8n_image" "$runners_image"
  else
    info "Checking for image updates (silent pull)..."
    local old_digest; old_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$n8n_image" 2>/dev/null || true)
    docker pull "$n8n_image" &>/dev/null
    local new_digest; new_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$n8n_image" 2>/dev/null || true)

    if [ "$old_digest" != "$new_digest" ] && [ -n "$old_digest" ]; then
      read -rp "$(echo -e "${YELLOW}Update available.${NC} Pull updated images now? (y/N): ")" choice
      if [[ "$choice" =~ ^[Yy]$ ]]; then
        pull_images "$n8n_image" "$runners_image"
      else
        warn "Keeping existing local images."
      fi
    else
      success "Images are already up to date."
    fi
  fi

  # Auth token
  local auth_token; auth_token=$(ensure_runner_token)

  # Restart policy
  local restart_policy="no"
  [ "$AUTO_RESTART" = true ] && restart_policy="unless-stopped"

  # Basic auth prompt
  if [ "$BASIC_AUTH" = true ] && [ -z "$BASIC_AUTH_USER" ]; then
    read -rp "Basic auth username: " BASIC_AUTH_USER
    read -rsp "Basic auth password: " BASIC_AUTH_PASS
    echo ""
  fi

  # Write compose + persist config (including cached version)
  write_compose "$n8n_image" "$runners_image" "$auth_token" "$restart_policy"
  N8N_CACHED_VERSION="$ver"
  save_config

  # Handle name conflicts
  if docker ps -aq -f "name=^/${CONTAINER_NAME}$" | grep -q .; then
    if [ "$FORCE" = true ] || [ "$AUTO_UPDATE" = true ]; then
      info "Removing existing container '${CONTAINER_NAME}'..."
      docker compose -f "$(compose_file)" down 2>/dev/null || docker rm -f "$CONTAINER_NAME" 2>/dev/null
    else
      warn "Container '${CONTAINER_NAME}' already exists."
      select choice in "Stop and Replace" "Cancel"; do
        case $choice in
          "Stop and Replace") docker compose -f "$(compose_file)" down 2>/dev/null || docker rm -f "$CONTAINER_NAME"; break ;;
          "Cancel") exit 0 ;;
        esac
      done
    fi
  fi

  # Ensure volume
  docker volume inspect "$VOLUME_NAME" &>/dev/null || {
    info "Creating volume: ${VOLUME_NAME}"
    docker volume create "$VOLUME_NAME"
  }

  # Launch
  info "Launching n8n v${ver} on port ${HOST_PORT}..."

  if [ "$DETACHED" = true ]; then
    docker compose -f "$(compose_file)" up -d
    echo ""
    success "n8n is running in the background."
    echo ""
    echo -e "  ${BOLD}UI:${NC}      http://localhost:${HOST_PORT}"
    echo -e "  ${BOLD}Logs:${NC}    ${SCRIPT_NAME} logs"
    echo -e "  ${BOLD}Status:${NC}  ${SCRIPT_NAME} status"
    echo -e "  ${BOLD}Stop:${NC}    ${SCRIPT_NAME} stop"
    echo -e "  ${BOLD}Backup:${NC}  ${SCRIPT_NAME} backup"
    echo ""
    wait_healthy "$CONTAINER_NAME" 120 || true
  else
    info "Running in foreground — press Ctrl+C to stop."
    docker compose -f "$(compose_file)" up
  fi
}

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${NC} — n8n deployment manager

${BOLD}SYNOPSIS${NC}
  ${SCRIPT_NAME} [COMMAND] [OPTIONS]

${BOLD}COMMANDS${NC}
  start         Deploy and start n8n (default when no command given)
  stop          Stop and remove all running containers
  restart       Restart all containers without recreating them
  status        Show container status, volume usage, and deployment info
  logs          Stream container logs (live tail)
  update        Interactive version picker — choose from the 10 latest releases
  upgrade       One-click upgrade to the latest stable release (non-interactive)
  backup        Snapshot the n8n data volume to a compressed archive
  restore       Restore data from a backup archive (interactive picker)
  reset         Wipe all n8n data — workflows, credentials, executions
  uninstall     Remove everything: containers, images, volume, and config
  help          Show this help message

${BOLD}UPDATE vs UPGRADE${NC}
  ${BOLD}update${NC}
    Presents a numbered list of the 10 most recent stable n8n releases
    fetched live from Docker Hub. Your currently installed version is
    highlighted (${GREEN}▶${NC}), and versions newer than yours are marked (${CYAN}↑${NC}).
    You choose the exact version to install — which may be an upgrade,
    a re-install of the same version, or a downgrade (with confirmation).
    A backup is always created automatically before any change.

  ${BOLD}upgrade${NC}
    Fetches only the single latest release. If you are already on it,
    it exits cleanly. Otherwise it shows the current → target diff,
    asks for confirmation (unless -f), backs up, and redeploys. Ideal
    for cron jobs and CI pipelines: ${DIM}${SCRIPT_NAME} upgrade -f -r${NC}

${BOLD}OPTIONS${NC}
  -s            Skip update check — start instantly using cached version
  -u            Auto-update images without prompts (overrides -s)
  -d            Detached / background mode
  -r            Auto-restart containers on system reboot
  -f            Force — skip confirmation prompts (useful for CI/CD)
  -n NAME       Container name              (default: n8n)
  -p PORT       Host port to expose         (default: 5678)
  -t TIMEZONE   Container timezone          (default: system timezone)
  -e FILE       Path to a .env file with extra environment variables
  -w URL        Webhook base URL            (e.g. https://n8n.example.com)
  -b            Enable HTTP basic auth (will prompt for credentials)
  -l LEVEL      Log level: error | warn | info | debug  (default: info)
  -h            Show this help message

${BOLD}EXAMPLES${NC}
  # Quick local start — interactive foreground mode
  ${DIM}${SCRIPT_NAME} start${NC}

  # Fast start — skip update check, use cached version (ideal for daily use)
  ${DIM}${SCRIPT_NAME} start -s -d${NC}

  # Background deployment that survives reboots
  ${DIM}${SCRIPT_NAME} start -d -r${NC}

  # Auto-update, background, custom port and name
  ${DIM}${SCRIPT_NAME} start -u -d -p 8080 -n my-n8n${NC}

  # Production deployment: webhook URL + env file + restart policy
  ${DIM}${SCRIPT_NAME} start -d -r -w https://n8n.example.com -e ~/n8n.env${NC}

  # Enable basic auth (prompts for username/password interactively)
  ${DIM}${SCRIPT_NAME} start -d -b${NC}

  # Interactive version picker — see 10 recent releases, choose one to install
  ${DIM}${SCRIPT_NAME} update${NC}

  # Non-interactive update (CI/CD — picks interactively, but -f skips confirmations)
  ${DIM}${SCRIPT_NAME} update -f${NC}

  # One-click upgrade to the absolute latest (asks for confirmation)
  ${DIM}${SCRIPT_NAME} upgrade${NC}

  # Fully automated upgrade — ideal for cron, no prompts, auto-restart enabled
  ${DIM}${SCRIPT_NAME} upgrade -f -r${NC}

  # Stream logs from both containers
  ${DIM}${SCRIPT_NAME} logs${NC}

  # Stream logs from only the main n8n container
  ${DIM}${SCRIPT_NAME} logs n8n${NC}

  # Show deployment status, volume size, backup count, and installed version
  ${DIM}${SCRIPT_NAME} status${NC}

  # Create a backup snapshot
  ${DIM}${SCRIPT_NAME} backup${NC}

  # Interactive restore picker (choose from saved backups)
  ${DIM}${SCRIPT_NAME} restore${NC}

  # Restore from a specific archive file
  ${DIM}${SCRIPT_NAME} restore ~/.n8n-deploy/backups/n8n_backup_20250101_120000.tar.gz${NC}

  # Wipe all data for a clean slate
  ${DIM}${SCRIPT_NAME} reset${NC}

  # Fully remove n8n — containers, images, volume, config
  ${DIM}${SCRIPT_NAME} uninstall${NC}

${BOLD}ENVIRONMENT VARIABLES${NC}
  N8N_DEPLOY_DIR    Override the default deploy directory
                    (default: ~/.n8n-deploy)

${BOLD}FILES${NC}
  ~/.n8n-deploy/docker-compose.yml   Generated compose file
  ~/.n8n-deploy/.config              Persisted settings across runs
  ~/.n8n-deploy/.runner_token        Shared runner auth token (chmod 600)
  ~/.n8n-deploy/backups/             Backup archives (10 most recent kept)

${BOLD}NOTES${NC}
  • n8n and the runners sidecar MUST be the same version. This script
    detects and pins both images to the same version automatically.
  • The task broker port (5679) is bound to 127.0.0.1 only and is never
    exposed publicly — the runner container reaches it via the internal
    Docker network.
  • Backups are standard tar.gz archives of the Docker volume. You can
    restore them manually with any tool, independent of this script.
  • Settings (port, name, timezone, etc.) are persisted in .config and
    reloaded automatically on subsequent runs.
  • Ollama (host machine): both containers have host.docker.internal
    mapped to the host gateway. In n8n, set the Ollama base URL to
    http://host.docker.internal:11434 — no API key is required.
  • Update speed: first run detects the version via docker inspect (fast)
    or docker run (slow, one-time fallback). Use -s on subsequent starts
    to skip all version/update checks and launch instantly.
  • The 'update' version list requires network access to Docker Hub
    (api.docker.io). curl or wget must be available on the host.
  • Downgrading is supported via 'update' but requires explicit confirmation
    and is not available via 'upgrade' (which only moves forward).

EOF
  exit 0
}

# ─── Parse global options ─────────────────────────────────────────────────────
parse_opts() {
  while getopts "sudfrbn:p:t:e:w:l:h" opt; do
    case "$opt" in
      s) SKIP_UPDATE=true ;;
      u) AUTO_UPDATE=true ;;
      d) DETACHED=true ;;
      r) AUTO_RESTART=true ;;
      f) FORCE=true ;;
      b) BASIC_AUTH=true ;;
      n) CONTAINER_NAME="$OPTARG" ;;
      p) HOST_PORT="$OPTARG" ;;
      t) TIMEZONE="$OPTARG" ;;
      e) ENV_FILE="$OPTARG" ;;
      w) WEBHOOK_URL="$OPTARG" ;;
      l) LOG_LEVEL="$OPTARG" ;;
      h) usage ;;
      *) usage ;;
    esac
  done
}

# ─── Entry point ──────────────────────────────────────────────────────────────
main() {
  local command="${1:-start}"

  case "$command" in
    start|stop|restart|status|update|upgrade|backup|reset|uninstall|help)
      shift 2>/dev/null || true
      parse_opts "$@"
      ;;
    logs)
      shift 2>/dev/null || true
      local log_service="${1:-}"
      local log_lines="${2:-100}"
      load_config
      cmd_logs "$log_service" "$log_lines"
      return
      ;;
    restore)
      shift 2>/dev/null || true
      local restore_file="${1:-}"
      load_config
      # -f may be passed after the subcommand
      [[ "${1:-}" == "-f" ]] && { FORCE=true; shift; }
      cmd_restore "$restore_file"
      return
      ;;
    -*)
      # No subcommand given — treat all args as options to 'start'
      command="start"
      parse_opts "$@"
      ;;
    *)
      error "Unknown command: ${command}"
      usage
      ;;
  esac

  case "$command" in
    start)     cmd_start ;;
    stop)      load_config; cmd_stop ;;
    restart)   load_config; cmd_restart ;;
    status)    load_config; cmd_status ;;
    update)    load_config; cmd_update ;;
    upgrade)   load_config; cmd_upgrade ;;
    backup)    load_config; cmd_backup ;;
    reset)     load_config; cmd_reset ;;
    uninstall) load_config; cmd_uninstall ;;
    help)      usage ;;
  esac
}

main "$@"

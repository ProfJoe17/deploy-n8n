#!/usr/bin/env bash
# =============================================================================
#  deploy-n8n.sh — n8n deployment manager  v1.1.0
#  Manages n8n + external Python/JS task runners via Docker Compose
#
#  Tested on:
#    Linux  — Debian · Ubuntu · Red Hat · Fedora · CentOS · Rocky · AlmaLinux
#             openSUSE · SLES · Arch · Manjaro · Alpine · Void · Gentoo
#             Slackware · NixOS · Solus · Puppy · and most independents
#    macOS  — Ventura 13+ · Sonoma 14+ · Sequoia 15+  (Intel & Apple Silicon)
#
#  Hard requirements:
#    bash ≥ 3.2   docker (with Compose v2 plugin)   openssl
#
#  Soft requirements (needed only for 'update' / 'upgrade' commands):
#    curl  OR  wget        — HTTP calls to Docker Hub API
#    jq  OR  python3/2     — JSON parsing  (grep fallback also available)
#
#  On Alpine Linux (which ships ash/sh, not bash):
#    apk add bash docker docker-cli-compose openssl
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# ─── Script metadata ──────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_NAME="$(basename "$0")"

# ─── Defaults (TIMEZONE resolved after platform-detection functions load) ─────
DEPLOY_DIR="${N8N_DEPLOY_DIR:-$HOME/.n8n-deploy}"
CONTAINER_NAME="n8n"
VOLUME_NAME="n8n_data"
HOST_PORT=5678
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
LOG_LEVEL="info"

# ─── Derived paths ────────────────────────────────────────────────────────────
compose_file()  { echo "${DEPLOY_DIR}/docker-compose.yml"; }
token_file()    { echo "${DEPLOY_DIR}/.runner_token"; }
config_file()   { echo "${DEPLOY_DIR}/.config"; }
lock_file()     { echo "${DEPLOY_DIR}/.lock"; }

# =============================================================================
#  PLATFORM DETECTION
#  All functions here are intentionally dependency-free (pure bash + POSIX
#  tools only) so they can run before prerequisites are checked.
# =============================================================================

# ─── OS identifier ────────────────────────────────────────────────────────────
# Returns a lowercase ID string matching /etc/os-release ID where possible,
# plus "macos" for Darwin hosts.
detect_os() {
  # macOS — OSTYPE is set to "darwin*" by bash itself; uname as belt-and-braces
  case "${OSTYPE:-}" in darwin*) echo "macos"; return ;; esac
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] && { echo "macos"; return; }

  # Modern Linux — /etc/os-release (systemd era, also present on musl/Alpine)
  if [ -f /etc/os-release ]; then
    local id
    id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')
    [ -n "$id" ] && { echo "$id"; return; }
  fi

  # Legacy release files (pre-/etc/os-release era)
  [ -f /etc/alpine-release   ] && { echo "alpine";    return; }
  [ -f /etc/arch-release     ] && { echo "arch";      return; }
  [ -f /etc/gentoo-release   ] && { echo "gentoo";    return; }
  [ -f /etc/slackware-version] && { echo "slackware"; return; }
  [ -f /etc/debian_version   ] && { echo "debian";    return; }
  [ -f /etc/redhat-release   ] && { echo "rhel";      return; }

  echo "linux"  # generic fallback
}

# Returns the broader package-manager family for the current OS.
detect_os_family() {
  local os; os=$(detect_os)
  case "$os" in
    ubuntu|debian|raspbian|linuxmint|pop|kali|elementary|mx|zorin|parrot|tails)
      echo "debian" ;;
    fedora|rhel|centos|rocky|almalinux|ol|scientific|amzn|mageia|clearos)
      echo "redhat" ;;
    opensuse*|suse|sles)
      echo "suse" ;;
    arch|manjaro|endeavouros|artix|garuda|blackarch|cachyos)
      echo "arch" ;;
    alpine)
      echo "alpine" ;;
    void)
      echo "void" ;;
    gentoo)
      echo "gentoo" ;;
    slackware)
      echo "slackware" ;;
    nixos)
      echo "nixos" ;;
    solus)
      echo "solus" ;;
    macos)
      echo "macos" ;;
    *)
      echo "linux" ;;
  esac
}

# ─── OS-aware package install hint ────────────────────────────────────────────
# Usage: pkg_install_hint <generic_name>
# Generic names understood: docker  openssl  curl  wget  jq  python3
pkg_install_hint() {
  local pkg="$1"
  local family; family=$(detect_os_family)

  case "$family" in
    debian)
      case "$pkg" in
        docker)  echo "sudo apt-get install -y docker.io docker-compose-plugin" ;;
        python3) echo "sudo apt-get install -y python3" ;;
        *)       echo "sudo apt-get install -y ${pkg}" ;;
      esac ;;
    redhat)
      local mgr="dnf"; command -v dnf &>/dev/null || mgr="yum"
      case "$pkg" in
        docker)  echo "sudo ${mgr} install -y docker-ce docker-compose-plugin" ;;
        python3) echo "sudo ${mgr} install -y python3" ;;
        *)       echo "sudo ${mgr} install -y ${pkg}" ;;
      esac ;;
    suse)
      case "$pkg" in
        docker)  echo "sudo zypper install -y docker docker-compose" ;;
        *)       echo "sudo zypper install -y ${pkg}" ;;
      esac ;;
    arch)
      case "$pkg" in
        docker)  echo "sudo pacman -S --noconfirm docker docker-compose" ;;
        python3) echo "sudo pacman -S --noconfirm python" ;;
        *)       echo "sudo pacman -S --noconfirm ${pkg}" ;;
      esac ;;
    alpine)
      case "$pkg" in
        docker)  echo "sudo apk add docker docker-cli-compose" ;;
        python3) echo "sudo apk add python3" ;;
        *)       echo "sudo apk add ${pkg}" ;;
      esac ;;
    void)
      case "$pkg" in
        docker)  echo "sudo xbps-install -y docker docker-compose" ;;
        python3) echo "sudo xbps-install -y python3" ;;
        *)       echo "sudo xbps-install -y ${pkg}" ;;
      esac ;;
    gentoo)
      case "$pkg" in
        docker)  echo "sudo emerge app-containers/docker" ;;
        openssl) echo "sudo emerge dev-libs/openssl" ;;
        curl)    echo "sudo emerge net-misc/curl" ;;
        wget)    echo "sudo emerge net-misc/wget" ;;
        jq)      echo "sudo emerge app-misc/jq" ;;
        python3) echo "sudo emerge dev-lang/python" ;;
        *)       echo "sudo emerge ${pkg}" ;;
      esac ;;
    slackware)
      echo "slackpkg install ${pkg}" ;;
    nixos)
      case "$pkg" in
        docker)  echo "# add services.docker.enable = true; to configuration.nix" ;;
        *)       echo "nix-env -iA nixpkgs.${pkg}  # or add to configuration.nix" ;;
      esac ;;
    solus)
      case "$pkg" in
        docker)  echo "sudo eopkg install docker" ;;
        *)       echo "sudo eopkg install ${pkg}" ;;
      esac ;;
    macos)
      case "$pkg" in
        docker)  echo "Download Docker Desktop: https://www.docker.com/products/docker-desktop/" ;;
        *)       echo "brew install ${pkg}" ;;
      esac ;;
    *)
      echo "(install ${pkg} via your distro's package manager)" ;;
  esac
}

# ─── Timezone detection ───────────────────────────────────────────────────────
# Tries five strategies in order, emits the first non-empty result or "UTC".
detect_timezone() {
  local tz=""

  # 1. /etc/timezone — Debian / Ubuntu family
  if [ -z "$tz" ] && [ -f /etc/timezone ]; then
    tz=$(tr -d '[:space:]' < /etc/timezone 2>/dev/null)
  fi

  # 2. /etc/localtime symlink — most Linux distros + macOS
  #    Linux path:  .../zoneinfo/Region/City
  #    macOS path:  /var/db/timezone/zoneinfo/Region/City
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    local lnk
    lnk=$(readlink /etc/localtime 2>/dev/null)
    tz=$(printf '%s' "$lnk" | sed 's|.*/zoneinfo/||; s|^posix/||')
  fi

  # 3. timedatectl — systemd-based distros (Fedora, Arch, Debian ≥9, etc.)
  if [ -z "$tz" ] && command -v timedatectl &>/dev/null; then
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null) \
    || tz=$(timedatectl status 2>/dev/null \
          | grep -E '^\s*(Time zone|Timezone):' \
          | head -1 | sed 's/.*: *//' | awk '{print $1}') \
    || true
  fi

  # 4. systemsetup — macOS (may need sudo on some versions; ignore failures)
  if [ -z "$tz" ] && command -v systemsetup &>/dev/null; then
    tz=$(systemsetup -gettimezone 2>/dev/null \
        | sed 's/.*Time Zone: *//' | tr -d '[:space:]') || true
  fi

  # 5. /etc/sysconfig/clock — older Red Hat / SUSE / Gentoo
  if [ -z "$tz" ] && [ -f /etc/sysconfig/clock ]; then
    tz=$(grep -E '^(TIMEZONE|ZONE)=' /etc/sysconfig/clock 2>/dev/null \
        | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//')
  fi

  printf '%s' "${tz:-UTC}"
}

# ─── Portable realpath ────────────────────────────────────────────────────────
# Resolves to an absolute path.  Tries: GNU realpath → grealpath (macOS brew)
# → python3 → python2 → pure-bash (makes absolute; no symlink resolution).
portable_realpath() {
  local p="$1"
  command -v realpath  &>/dev/null && { realpath  "$p" 2>/dev/null && return 0; } || true
  command -v grealpath &>/dev/null && { grealpath "$p" 2>/dev/null && return 0; } || true
  command -v python3   &>/dev/null && {
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null && return 0
  } || true
  command -v python    &>/dev/null && {
    python  -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p" 2>/dev/null && return 0
  } || true
  # Pure-bash fallback — makes relative paths absolute; no symlink resolution
  [[ "$p" == /* ]] || p="$PWD/$p"
  printf '%s' "$p"
}

# ─── HTTP client abstraction ──────────────────────────────────────────────────
has_http_client() { command -v curl &>/dev/null || command -v wget &>/dev/null; }

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

# ─── Resolve TIMEZONE now that detect_timezone is defined ─────────────────────
TIMEZONE=$(detect_timezone)
BACKUP_DIR="${DEPLOY_DIR}/backups"

# =============================================================================
#  COLOURS
# =============================================================================
if [ -t 1 ]; then
  RED=$'\033[0;31m';     GREEN=$'\033[0;32m';   YELLOW=$'\033[1;33m'
  CYAN=$'\033[0;36m';    BOLD=$'\033[1m';        DIM=$'\033[2m';      NC=$'\033[0m'
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

# =============================================================================
#  TRAP & CLEANUP
# =============================================================================
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

# =============================================================================
#  LOCKING
# =============================================================================
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

# =============================================================================
#  PREREQUISITE CHECKS
# =============================================================================
check_prerequisites() {
  local missing=()
  command -v docker  &>/dev/null || missing+=("docker")
  command -v openssl &>/dev/null || missing+=("openssl")

  if ! docker compose version &>/dev/null 2>&1; then
    missing+=("docker-compose-plugin")
  fi

  if [ ${#missing[@]} -ne 0 ]; then
    error "Missing required tools: ${missing[*]}"
    local m
    for m in "${missing[@]}"; do
      echo "  → Install ${m}: $(pkg_install_hint "$m")"
    done
    echo "  Docker guide: https://docs.docker.com/engine/install/"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    local os; os=$(detect_os)
    local start_cmd
    case "$os" in
      macos)     start_cmd="open -a Docker" ;;
      alpine|gentoo|void|slackware) start_cmd="sudo rc-service docker start  # or: sudo service docker start" ;;
      nixos)     start_cmd="sudo systemctl start docker  # ensure services.docker.enable = true in configuration.nix" ;;
      *)         start_cmd="sudo systemctl start docker" ;;
    esac
    die "Docker daemon is not running. Start it with: ${start_cmd}"
  fi
}

# Soft check used only by update/upgrade commands.
require_http_client() {
  has_http_client && return 0
  error "Neither curl nor wget is available. The '${1:-update}' command requires one."
  echo "  → Install curl : $(pkg_install_hint curl)"
  echo "  → Install wget : $(pkg_install_hint wget)"
  exit 1
}

# =============================================================================
#  PERSIST / LOAD CONFIG
# =============================================================================
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

# =============================================================================
#  VERSION DETECTION  (local image)
#  Strategy: -s flag (cached) → docker inspect label → docker run fallback
# =============================================================================
N8N_CACHED_VERSION=""   # populated by load_config

detect_n8n_version() {
  if [ "$SKIP_UPDATE" = true ]; then
    if [ -n "$N8N_CACHED_VERSION" ]; then
      info "Skipping update check — using cached version ${GREEN}${N8N_CACHED_VERSION}${NC}  (-s)"
      echo "$N8N_CACHED_VERSION"
      return
    else
      warn "-s given but no cached version found; falling through to detection."
    fi
  fi

  local ver
  ver=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    docker.n8n.io/n8nio/n8n:latest 2>/dev/null || true)

  if [ -z "$ver" ]; then
    info "Image label unavailable — running version probe (one-time, ~5 s)..."
    docker pull docker.n8n.io/n8nio/n8n:latest &>/dev/null || true
    ver=$(docker run --rm --entrypoint="" \
      docker.n8n.io/n8nio/n8n:latest \
      node -e "process.stdout.write(require('/usr/local/lib/node_modules/n8n/package.json').version)" \
      2>/dev/null) || true
  fi

  [ -z "$ver" ] && die "Could not determine n8n version. Check Docker / network connectivity."
  N8N_CACHED_VERSION="$ver"
  echo "$ver"
}

# =============================================================================
#  SEMVER COMPARISON
#  version_gt A B  →  exit 0 (true) if A is strictly greater than B
#  Chain: GNU sort -V → gsort -V (macOS Homebrew) → python3 → python2 →
#         pure-bash integer comparison
# =============================================================================
version_gt() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 1

  # Verify sort -V gives correct numeric ordering before trusting it
  # (macOS system sort may silently accept -V but sort lexicographically)
  local _sort_v_ok=false
  if printf '1.10\n1.9\n' | sort -V 2>/dev/null | head -1 | grep -q '^1\.9$'; then
    _sort_v_ok=true
  fi

  if [ "$_sort_v_ok" = true ]; then
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
    return
  fi

  # gsort -V — macOS with Homebrew coreutils
  if command -v gsort &>/dev/null; then
    [ "$(printf '%s\n%s\n' "$a" "$b" | gsort -V | tail -n1)" = "$a" ]
    return
  fi

  # python3
  if command -v python3 &>/dev/null; then
    python3 - "$a" "$b" <<'PYEOF'
import sys
def v(s):
    try: return tuple(int(x) for x in s.split('.'))
    except: return (0, 0, 0)
sys.exit(0 if v(sys.argv[1]) > v(sys.argv[2]) else 1)
PYEOF
    return
  fi

  # python2
  if command -v python &>/dev/null; then
    python - "$a" "$b" <<'PYEOF'
import sys
def v(s):
    try: return tuple(int(x) for x in s.split('.'))
    except: return (0, 0, 0)
sys.exit(0 if v(sys.argv[1]) > v(sys.argv[2]) else 1)
PYEOF
    return
  fi

  # Pure-bash integer comparison — splits on '.' with read -ra
  local -a va vb
  IFS='.' read -ra va <<< "$a"
  IFS='.' read -ra vb <<< "$b"
  local i
  for i in 0 1 2; do
    local na="${va[$i]:-0}" nb="${vb[$i]:-0}"
    (( na > nb )) && return 0
    (( na < nb )) && return 1
  done
  return 1  # equal
}

# =============================================================================
#  DOCKER HUB VERSION LIST
#  fetch_n8n_versions [count=10]
#  Fetches tags from Docker Hub, strips non-semver tags (latest, nightly, etc.),
#  and emits up to <count> version strings, most-recent first.
#
#  JSON parsing chain: jq → python3 (pipe) → python2 (pipe) → grep fallback
# =============================================================================
fetch_n8n_versions() {
  local count="${1:-10}"
  local api_url="https://hub.docker.com/v2/repositories/n8nio/n8n/tags?page_size=100&ordering=last_updated"

  local raw
  raw=$(http_get "$api_url") || {
    warn "Could not reach Docker Hub API. Check network connectivity."
    return 1
  }
  [ -z "$raw" ] && { warn "Docker Hub returned an empty response."; return 1; }

  # jq — most reliable and fastest; widely available on all platforms
  if command -v jq &>/dev/null; then
    printf '%s' "$raw" \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | head -n "$count"
    return
  fi

  # python3 — pipe raw JSON to stdin (avoids shell-expansion injection)
  if command -v python3 &>/dev/null; then
    printf '%s' "$raw" | python3 -c "
import json, sys, re
r = re.compile(r'^[0-9]+\.[0-9]+\.[0-9]+$')
data = json.load(sys.stdin)
count = 0
for t in data.get('results', []):
    if r.match(t.get('name', '')):
        print(t['name'])
        count += 1
        if count >= int(${count}): break
" 2>/dev/null
    return
  fi

  # python2 — same approach
  if command -v python &>/dev/null; then
    printf '%s' "$raw" | python -c "
import json, sys, re
r = re.compile(r'^[0-9]+[.][0-9]+[.][0-9]+$')
data = json.load(sys.stdin)
count = 0
for t in data.get('results', []):
    if r.match(t.get('name', '')):
        sys.stdout.write(t['name'] + '\n')
        count += 1
        if count >= int(${count}): break
" 2>/dev/null
    return
  fi

  # grep-only fallback — works everywhere; less precise but covers 99 % of cases
  printf '%s' "$raw" \
    | grep -oE '"name"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
    | head -n "$count"
}

# =============================================================================
#  GET CURRENTLY DEPLOYED VERSION
#  Checks (in order): running container OCI label → cached config → compose file
# =============================================================================
get_current_deployed_version() {
  local ver=""

  # 1. Running container OCI label
  ver=$(docker inspect --format \
    '{{index .Config.Labels "org.opencontainers.image.version"}}' \
    "${CONTAINER_NAME}" 2>/dev/null | tr -d '[:space:]') || true

  # 2. Cached config value
  [ -z "$ver" ] && [ -n "${N8N_CACHED_VERSION:-}" ] && ver="$N8N_CACHED_VERSION"

  # 3. Compose file image tag
  if [ -z "$ver" ] && [ -f "$(compose_file)" ]; then
    ver=$(grep -m1 'image:.*n8nio/n8n' "$(compose_file)" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || true
  fi

  echo "${ver:-unknown}"
}

# =============================================================================
#  INTERACTIVE VERSION PICKER
#  Displays the 10 most-recent stable n8n releases from Docker Hub.
#  Installed version is highlighted; newer versions are marked with ↑.
#  Result is stored in SELECTED_VERSION.
# =============================================================================
SELECTED_VERSION=""

pick_n8n_version() {
  local count="${1:-10}"
  local current; current=$(get_current_deployed_version)

  step "Fetching latest n8n releases from Docker Hub..."
  local versions_raw
  versions_raw=$(fetch_n8n_versions "$count") || die "Unable to retrieve version list."

  # Load into array — bash 3.2-compatible (no mapfile)
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
    local upgrade_marker=""

    [ "$v" = "${versions[0]}" ] && label="${DIM} ← latest${NC}"

    if [ "$v" = "$current" ]; then
      marker="${GREEN}▶  ${NC}"
      label="${GREEN} ← installed${NC}"
      colour="${GREEN}"
    fi

    if [ "$current" != "unknown" ] && version_gt "$v" "$current"; then
      upgrade_marker=" ${CYAN}↑${NC}"
    fi

    printf "  %b%2d)  ${colour}%-12s${NC}%b%b\n" \
      "$marker" "$i" "$v" "$upgrade_marker" "$label"
    i=$(( i + 1 ))
  done

  echo ""
  echo -e "  ${DIM}${CYAN}↑${NC}${DIM} = newer than installed  ${GREEN}▶${NC}${DIM} = currently installed${NC}"
  echo ""
  read -rp "  Enter number to install (or q to quit): " sel

  [[ "$sel" =~ ^[Qq]$ ]] && { info "Cancelled."; exit 0; }

  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#versions[@]} ]; then
    die "Invalid selection: ${sel}"
  fi

  SELECTED_VERSION="${versions[$(( sel - 1 ))]}"
  echo ""
  info "Selected: ${BOLD}n8n v${SELECTED_VERSION}${NC}"
}

# =============================================================================
#  APPLY A CHOSEN VERSION  (shared by update & upgrade)
#  Handles: no-op detection · downgrade warning · backup · pull · redeploy
# =============================================================================
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
    warn "You are downgrading: ${YELLOW}${current}${NC} → ${RED}${ver}${NC}."
    if [ "$FORCE" != true ]; then
      read -rp "  Confirm downgrade? (yes/N): " confirm
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

  if [ "$current" != "unknown" ]; then
    if version_gt "$ver" "$current"; then
      dim "  (upgraded from v${current})"
    else
      dim "  (downgraded from v${current})"
    fi
  fi
}

# =============================================================================
#  AUTH TOKEN
# =============================================================================
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

# =============================================================================
#  WRITE DOCKER-COMPOSE.YML
# =============================================================================
write_compose() {
  local n8n_image="$1"
  local runners_image="$2"
  local auth_token="$3"
  local restart_policy="$4"

  local env_block=""
  if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
    env_block="    env_file:
      - $(portable_realpath "$ENV_FILE")"
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
      - "host.docker.internal:host-gateway"   # reach host Ollama: host.docker.internal:11434
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
      - "host.docker.internal:host-gateway"
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

# =============================================================================
#  PULL IMAGES
# =============================================================================
pull_images() {
  local n8n_image="$1" runners_image="$2"
  info "Pulling n8n image     → ${n8n_image}"
  docker pull "$n8n_image"     || die "Failed to pull n8n image."
  info "Pulling runners image → ${runners_image}"
  docker pull "$runners_image" || die "Failed to pull runners image. See: https://hub.docker.com/r/n8nio/runners/tags"
  success "All images up to date."
}

# =============================================================================
#  WAIT FOR HEALTHY
# =============================================================================
wait_healthy() {
  local name="$1" timeout="${2:-120}"
  info "Waiting for ${name} to become healthy (up to ${timeout}s)..."
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local s
    s=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "none")
    case "$s" in
      healthy)   echo ""; success "${name} is healthy."; return 0 ;;
      unhealthy) echo ""; error   "${name} is unhealthy."; docker logs --tail 30 "$name"; return 1 ;;
    esac
    sleep 5; elapsed=$(( elapsed + 5 ))
    printf '.'
  done
  echo ""
  warn "Timed out waiting for ${name}. Check logs with: ${SCRIPT_NAME} logs"
  return 1
}

# =============================================================================
#  COMMAND: backup
# =============================================================================
cmd_backup() {
  step "Backing up n8n data"
  check_prerequisites

  local ts; ts=$(date -u '+%Y%m%d_%H%M%S')
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
  local count; count=$(ls -1 "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "${count:-0}" -gt 10 ]; then
    info "Pruning old backups (keeping 10 most recent)..."
    ls -1t "${BACKUP_DIR}"/n8n_backup_*.tar.gz | tail -n +11 | xargs rm -f
  fi
}

# =============================================================================
#  COMMAND: restore
# =============================================================================
cmd_restore() {
  local archive="$1"
  step "Restoring n8n data"
  check_prerequisites

  if [ -z "$archive" ]; then
    echo ""
    info "Available backups:"

    # bash 3.2-compatible array build (no mapfile)
    local backups=()
    while IFS= read -r b; do
      [ -n "$b" ] && backups+=("$b")
    done < <(ls -1t "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null || true)

    if [ ${#backups[@]} -eq 0 ]; then
      die "No backups found in ${BACKUP_DIR}"
    fi

    local i=1
    for b in "${backups[@]}"; do
      local sz; sz=$(du -sh "$b" | cut -f1)
      printf "  %2d)  %s  [%s]\n" "$i" "$(basename "$b")" "$sz"
      i=$(( i + 1 ))
    done
    echo ""
    read -rp "Enter number to restore (or q to quit): " sel
    [[ "$sel" =~ ^[Qq]$ ]] && exit 0
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#backups[@]} ]; then
      die "Invalid selection."
    fi
    archive="${backups[$(( sel - 1 ))]}"
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

  local archive_abs; archive_abs=$(portable_realpath "$archive")
  local archive_dir;  archive_dir=$(dirname "$archive_abs")
  local archive_name; archive_name=$(basename "$archive_abs")

  info "Restoring from: ${archive_abs}"
  docker run --rm \
    -v "${VOLUME_NAME}:/data" \
    -v "${archive_dir}:/backup:ro" \
    alpine sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar -xzf '/backup/${archive_name}' -C /data" \
    || die "Restore failed."

  success "Restore complete. Run '${SCRIPT_NAME} start' to bring n8n back up."
}

# =============================================================================
#  COMMAND: logs
# =============================================================================
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

# =============================================================================
#  COMMAND: status
# =============================================================================
cmd_status() {
  local cf; cf="$(compose_file)"
  local os; os=$(detect_os)
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
  info "Platform     : ${os} ($(uname -m 2>/dev/null || echo unknown))"
  info "Timezone     : ${TIMEZONE}"

  local vol_size
  vol_size=$(docker run --rm -v "${VOLUME_NAME}:/data:ro" alpine du -sh /data 2>/dev/null | cut -f1 || echo "unknown")
  info "Volume size  : ${vol_size}"

  local nb; nb=$(ls -1 "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)
  info "Backups      : ${nb} (in ${BACKUP_DIR})"
  echo ""
}

# =============================================================================
#  COMMAND: stop
# =============================================================================
cmd_stop() {
  step "Stopping n8n"
  local cf; cf="$(compose_file)"
  [ -f "$cf" ] || { warn "No deployment config found."; return; }
  docker compose -f "$cf" down && success "All containers stopped." || error "Stop failed."
}

# =============================================================================
#  COMMAND: restart
# =============================================================================
cmd_restart() {
  step "Restarting n8n"
  local cf; cf="$(compose_file)"
  [ -f "$cf" ] || die "No deployment config found. Run '${SCRIPT_NAME} start' first."
  docker compose -f "$cf" restart && success "Restarted." || error "Restart failed."
}

# =============================================================================
#  COMMAND: update
#  Presents an interactive picker of the 10 most recent stable releases.
#  Installed version highlighted; newer versions marked with ↑.
#  Supports upgrade, re-install, or downgrade (downgrade requires confirmation).
#  Automatic backup before any change.
# =============================================================================
cmd_update() {
  step "n8n — interactive version update"
  check_prerequisites
  require_http_client update
  acquire_lock

  pick_n8n_version 10
  apply_n8n_version "$SELECTED_VERSION"
}

# =============================================================================
#  COMMAND: upgrade
#  Non-interactive fast-path: installs the single latest stable release.
#  • Already on latest → exits cleanly.
#  • Newer available   → shows diff, confirms (unless -f), backs up, redeploys.
#  Ideal for cron:  deploy-n8n.sh upgrade -f -r
# =============================================================================
cmd_upgrade() {
  step "n8n — upgrade to latest"
  check_prerequisites
  require_http_client upgrade
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
    success "Already on the latest version (${GREEN}${latest}${NC}). Nothing to do."
    return 0
  fi

  if ! version_gt "$latest" "$current" && [ "$current" != "unknown" ]; then
    warn "Latest published tag (${latest}) is not newer than installed (${current})."
    warn "Docker Hub indexing may be lagged. No changes applied."
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

# =============================================================================
#  COMMAND: reset
# =============================================================================
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

# =============================================================================
#  COMMAND: uninstall
# =============================================================================
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

# =============================================================================
#  COMMAND: start
# =============================================================================
cmd_start() {
  step "Starting n8n"
  check_prerequisites
  load_config
  acquire_lock

  if [ "$SKIP_UPDATE" = true ]; then
    info "Detecting n8n version (skip-update mode)..."
  else
    info "Detecting n8n version..."
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

  local cached_n8n;     cached_n8n=$(docker images -q "$n8n_image" 2>/dev/null || true)
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

  local auth_token; auth_token=$(ensure_runner_token)

  local restart_policy="no"
  [ "$AUTO_RESTART" = true ] && restart_policy="unless-stopped"

  if [ "$BASIC_AUTH" = true ] && [ -z "$BASIC_AUTH_USER" ]; then
    read -rp  "Basic auth username: " BASIC_AUTH_USER
    read -rsp "Basic auth password: " BASIC_AUTH_PASS
    echo ""
  fi

  write_compose "$n8n_image" "$runners_image" "$auth_token" "$restart_policy"
  N8N_CACHED_VERSION="$ver"
  save_config

  if docker ps -aq -f "name=^/${CONTAINER_NAME}$" | grep -q .; then
    if [ "$FORCE" = true ] || [ "$AUTO_UPDATE" = true ]; then
      info "Removing existing container '${CONTAINER_NAME}'..."
      docker compose -f "$(compose_file)" down 2>/dev/null || docker rm -f "$CONTAINER_NAME" 2>/dev/null
    else
      warn "Container '${CONTAINER_NAME}' already exists."
      select choice in "Stop and Replace" "Cancel"; do
        case $choice in
          "Stop and Replace")
            docker compose -f "$(compose_file)" down 2>/dev/null || docker rm -f "$CONTAINER_NAME"
            break ;;
          "Cancel") exit 0 ;;
        esac
      done
    fi
  fi

  docker volume inspect "$VOLUME_NAME" &>/dev/null || {
    info "Creating volume: ${VOLUME_NAME}"
    docker volume create "$VOLUME_NAME"
  }

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

# =============================================================================
#  USAGE
# =============================================================================
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
    Presents a numbered list of the 10 most-recent stable n8n releases
    fetched live from Docker Hub. Your installed version is highlighted
    (${GREEN}▶${NC}), versions newer than yours are marked (${CYAN}↑${NC}). Choose any version
    to install — upgrade, re-install, or downgrade (with confirmation).
    A backup is created automatically before any change is applied.

  ${BOLD}upgrade${NC}
    Fetches only the single latest release and installs it if it is newer
    than the currently deployed version. Already on latest → exits cleanly.
    Shows a current→target diff, asks for confirmation (unless -f), backs
    up, then redeploys. Ideal for cron: ${DIM}${SCRIPT_NAME} upgrade -f -r${NC}

${BOLD}OPTIONS${NC}
  -s            Skip update check — start instantly using cached version
  -u            Auto-update images without prompts (overrides -s)
  -d            Detached / background mode
  -r            Auto-restart containers on system reboot
  -f            Force — skip confirmation prompts (useful for CI/CD)
  -n NAME       Container name              (default: n8n)
  -p PORT       Host port to expose         (default: 5678)
  -t TIMEZONE   Container timezone          (default: auto-detected)
  -e FILE       Path to a .env file with extra environment variables
  -w URL        Webhook base URL            (e.g. https://n8n.example.com)
  -b            Enable HTTP basic auth (will prompt for credentials)
  -l LEVEL      Log level: error | warn | info | debug  (default: info)
  -h            Show this help message

${BOLD}PLATFORM COMPATIBILITY${NC}
  Linux families:
    Debian/Ubuntu  Fedora/RHEL/Rocky/AlmaLinux  openSUSE/SLES
    Arch/Manjaro   Alpine   Void   Gentoo   Slackware
    NixOS   Solus  Puppy   and most independent distros

  macOS:
    Ventura 13+ · Sonoma 14+ · Sequoia 15+  (Intel + Apple Silicon)

  Hard requirements (must be present on the host):
    bash ≥ 3.2 · docker (Compose v2 plugin) · openssl

  Soft requirements (needed only for 'update' / 'upgrade'):
    curl or wget   — Docker Hub API calls
    jq or python3  — JSON parsing  (grep fallback also works)
    gsort (macOS)  — Accurate semver comparison (brew install coreutils)

  Alpine Linux note:
    Alpine ships ash, not bash. Install bash first:
    ${DIM}apk add bash docker docker-cli-compose openssl${NC}
    Then run the script with: ${DIM}bash ${SCRIPT_NAME} ...${NC}

  NixOS note:
    Ensure services.docker.enable = true in configuration.nix and
    your user is in the docker group before running this script.

  macOS note:
    Docker Desktop must be running before any command is issued.
    For accurate semver comparison: ${DIM}brew install coreutils${NC}

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

  # One-click upgrade to the latest (asks for confirmation)
  ${DIM}${SCRIPT_NAME} upgrade${NC}

  # Fully automated upgrade — ideal for cron, no prompts, auto-restart enabled
  ${DIM}${SCRIPT_NAME} upgrade -f -r${NC}

  # Stream logs from both containers
  ${DIM}${SCRIPT_NAME} logs${NC}

  # Stream logs from only the main n8n container
  ${DIM}${SCRIPT_NAME} logs n8n${NC}

  # Show deployment status, version, platform, and backup count
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
  • Backups are standard tar.gz archives of the Docker volume. They can
    be restored manually with any tool, independent of this script.
  • Settings (port, name, timezone, etc.) are persisted in .config and
    reloaded automatically on subsequent runs.
  • Ollama (host machine): both containers have host.docker.internal
    mapped to the host gateway. In n8n, set the Ollama base URL to
    http://host.docker.internal:11434 — no API key is required.
  • Update speed: first run detects the version via docker inspect (fast)
    or docker run (slow, one-time fallback). Use -s on subsequent starts
    to skip all version/update checks and launch instantly.
  • Timezone is auto-detected via /etc/timezone · /etc/localtime symlink ·
    timedatectl · systemsetup (macOS) · /etc/sysconfig/clock — in that order.
    Override at any time with: ${SCRIPT_NAME} start -t America/New_York
  • realpath is resolved via: GNU realpath → grealpath (macOS brew) →
    python3 → python2 → pure-bash absolute path conversion.
  • semver comparison uses: GNU sort -V → gsort (brew coreutils) →
    python3 → python2 → pure-bash integer comparison.

EOF
  exit 0
}

# =============================================================================
#  PARSE OPTIONS
# =============================================================================
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

# =============================================================================
#  ENTRY POINT
# =============================================================================
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
      [[ "${1:-}" == "-f" ]] && { FORCE=true; shift; }
      cmd_restore "$restore_file"
      return
      ;;
    -*)
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

#!/usr/bin/env bash
# setup-boost.sh — Spin up a Boost devnet for security research
# Part of filecoin-audit-kit: https://github.com/FilecoinFoundationWeb/filecoin-audit-kit
#
# Usage:
#   ./setup-boost.sh                    # Default: latest pinned Boost + Lotus
#   ./setup-boost.sh --lotus-version v1.32.1   # Pin specific Lotus version
#   ./setup-boost.sh --boost-version v2.4.8    # Pin specific Boost version
#   ./setup-boost.sh --build-lotus              # Build Lotus from source (for custom branches)
#   ./setup-boost.sh --ffi-source               # Force FFI build from source (ARM/Apple Silicon)
#   ./setup-boost.sh down                       # Tear down the devnet
#   ./setup-boost.sh status                     # Check devnet health
#   ./setup-boost.sh shell [service]            # Shell into a container (default: boost)

set -euo pipefail

# ─── Configurable Defaults ───────────────────────────────────────────────────
# Override these with flags or environment variables
BOOST_VERSION="${BOOST_VERSION:-v2.4.8}"
LOTUS_VERSION="${LOTUS_VERSION:-}"  # empty = use Boost's default
BUILD_LOTUS="${BUILD_LOTUS:-0}"
FFI_FROM_SOURCE="${FFI_FROM_SOURCE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOST_DIR="${SCRIPT_DIR}/.boost-devnet-src"
OVERRIDE_DIR="${SCRIPT_DIR}/boost-devnet"
DATA_DIR="${SCRIPT_DIR}/boost-devnet/data"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[audit-kit]${NC} $*"; }
ok()    { echo -e "${GREEN}[audit-kit]${NC} $*"; }
warn()  { echo -e "${YELLOW}[audit-kit]${NC} $*"; }
err()   { echo -e "${RED}[audit-kit]${NC} $*" >&2; }

# ─── Parse Arguments ─────────────────────────────────────────────────────────
CMD=""
SHELL_SERVICE="boost"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boost-version)  BOOST_VERSION="$2"; shift 2 ;;
    --lotus-version)  LOTUS_VERSION="$2"; shift 2 ;;
    --build-lotus)    BUILD_LOTUS=1; shift ;;
    --ffi-source)     FFI_FROM_SOURCE=1; shift ;;
    down|status|shell)
      CMD="$1"; shift
      [[ "${CMD}" == "shell" && $# -gt 0 ]] && { SHELL_SERVICE="$1"; shift; }
      ;;
    -h|--help)
      cat <<'EOF'
Filecoin Audit Kit — Boost Devnet Setup

Usage: ./setup-boost.sh [OPTIONS] [COMMAND]

Commands:
  (none)      Build images and start the Boost devnet
  down        Tear down the devnet and remove containers
  status      Check devnet health (container status, chain head, Boost UI)
  shell [svc] Shell into a container (default: boost)

Options:
  --boost-version TAG   Boost git tag to clone (default: v2.4.8)
  --lotus-version TAG   Lotus version for image build (default: Boost's default)
  --build-lotus         Build Lotus image from source (needed for custom branches)
  --ffi-source          Build filecoin-ffi from source (needed for ARM/Apple Silicon)
  -h, --help            Show this help

Environment Variables:
  BOOST_VERSION, LOTUS_VERSION, BUILD_LOTUS, FFI_FROM_SOURCE
  All flags can also be set via env vars.

Examples:
  ./setup-boost.sh                                    # Quick start
  ./setup-boost.sh --ffi-source                       # Apple Silicon
  ./setup-boost.sh --lotus-version my-patched-branch --build-lotus  # Custom Lotus
  ./setup-boost.sh shell lotus                        # Shell into lotus container
  ./setup-boost.sh down                               # Tear down
EOF
      exit 0 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Auto-detect ARM ─────────────────────────────────────────────────────────
if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  if [[ "${FFI_FROM_SOURCE}" == "0" ]]; then
    warn "ARM architecture detected — enabling --ffi-source automatically"
    FFI_FROM_SOURCE=1
  fi
fi

# ─── Prerequisites Check ────────────────────────────────────────────────────
check_prereqs() {
  local missing=()
  command -v docker >/dev/null 2>&1 || missing+=("docker")
  command -v git    >/dev/null 2>&1 || missing+=("git")

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools: ${missing[*]}"
    err "Install Docker: https://docs.docker.com/get-docker/"
    exit 1
  fi

  # Check Docker is running
  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running. Start Docker and try again."
    exit 1
  fi

  # Check Docker resources (recommend 8GB+ for Boost devnet)
  local mem_bytes
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
  local mem_gb=$(( mem_bytes / 1073741824 ))
  if [[ ${mem_gb} -lt 8 ]]; then
    warn "Docker has ${mem_gb}GB RAM allocated. Boost devnet recommends 8GB+."
    warn "Increase in Docker Desktop > Settings > Resources if builds fail."
  fi
}

# ─── Command: down ───────────────────────────────────────────────────────────
cmd_down() {
  info "Tearing down Boost devnet..."
  if [[ -d "${BOOST_DIR}" ]]; then
    cd "${BOOST_DIR}"
    make devnet/down 2>/dev/null || true
  fi
  ok "Devnet stopped."
  info "To also remove proof parameters: rm -rf ~/.cache/filecoin-proof-parameters"
  info "To remove Boost source clone: rm -rf ${BOOST_DIR}"
  info "To remove devnet data: rm -rf ${DATA_DIR}"
}

# ─── Command: status ─────────────────────────────────────────────────────────
cmd_status() {
  info "Checking Boost devnet status..."
  echo ""

  cd "${BOOST_DIR}/docker/devnet" 2>/dev/null || { err "Devnet not set up. Run ./setup-boost.sh first."; exit 1; }

  echo "=== Container Status ==="
  docker compose ps 2>/dev/null || { err "No containers running."; exit 1; }
  echo ""

  echo "=== Chain Head ==="
  docker compose exec -T lotus lotus chain head 2>/dev/null || warn "Lotus not ready yet"
  echo ""

  echo "=== Wallet Balance ==="
  docker compose exec -T lotus lotus wallet list 2>/dev/null || warn "Lotus not ready yet"
  echo ""

  echo "=== Boost UI ==="
  if curl -sf http://localhost:8080 >/dev/null 2>&1; then
    ok "Boost UI is accessible at http://localhost:8080"
  else
    warn "Boost UI not responding yet at http://localhost:8080"
  fi
}

# ─── Command: shell ──────────────────────────────────────────────────────────
cmd_shell() {
  cd "${BOOST_DIR}/docker/devnet" 2>/dev/null || { err "Devnet not set up. Run ./setup-boost.sh first."; exit 1; }
  info "Attaching to ${SHELL_SERVICE} container..."
  docker compose exec "${SHELL_SERVICE}" /bin/bash
}

# ─── Handle subcommands ─────────────────────────────────────────────────────
case "${CMD}" in
  down)   cmd_down; exit 0 ;;
  status) cmd_status; exit 0 ;;
  shell)  cmd_shell; exit 0 ;;
esac

# ─── Main: Build and Start ──────────────────────────────────────────────────
check_prereqs

info "Boost devnet setup"
info "  Boost version:    ${BOOST_VERSION}"
info "  Lotus version:    ${LOTUS_VERSION:-<boost default>}"
info "  Build Lotus:      ${BUILD_LOTUS}"
info "  FFI from source:  ${FFI_FROM_SOURCE}"
echo ""

# Step 1: Clone or update Boost
if [[ -d "${BOOST_DIR}/.git" ]]; then
  info "Boost repo exists at ${BOOST_DIR}"
  cd "${BOOST_DIR}"

  current_tag=$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)
  if [[ "${current_tag}" != "${BOOST_VERSION}" ]]; then
    warn "Current version (${current_tag}) differs from requested (${BOOST_VERSION})"
    info "Fetching and checking out ${BOOST_VERSION}..."
    git fetch --tags --depth 1 origin "${BOOST_VERSION}"
    git checkout "${BOOST_VERSION}"
  else
    ok "Already on ${BOOST_VERSION}"
  fi
else
  info "Cloning Boost ${BOOST_VERSION}..."
  git clone --depth 1 --branch "${BOOST_VERSION}" \
    https://github.com/filecoin-project/boost.git "${BOOST_DIR}"
  cd "${BOOST_DIR}"
fi

# Step 2: Apply audit-kit overrides
# Copy custom docker-compose override if present (exposes Lotus ports, adds labels)
if [[ -f "${OVERRIDE_DIR}/docker-compose.override.yaml" ]]; then
  info "Applying audit-kit docker-compose overrides..."
  cp "${OVERRIDE_DIR}/docker-compose.override.yaml" "${BOOST_DIR}/docker/devnet/docker-compose.override.yaml"
fi

# Step 3: Patch upstream Boost Dockerfiles to use latest Go
# The latest go-car requires Go 1.25, which breaks the 1.24 docker build for Boost. This bumps it.
info "Updating Dockerfile builder stages to golang:latest and runner to ubuntu:24.04..."

if [[ -f "${BOOST_DIR}/docker/devnet/Dockerfile.source" ]]; then
  sed -i 's|FROM golang:1.24-bullseye AS builder|FROM golang:latest AS builder|g' "${BOOST_DIR}/docker/devnet/Dockerfile.source"
  sed -i 's|FROM ubuntu:22.04 AS runner|FROM ubuntu:24.04 AS runner|g' "${BOOST_DIR}/docker/devnet/Dockerfile.source"
fi

if [[ -f "${BOOST_DIR}/docker/devnet/boost/entrypoint.sh" ]]; then
  info "Patching boost entrypoint to include --deprecated=true flag..."
  sed -i 's|boostd -vv run &> $BOOST_PATH/boostd.log &|boostd -vv run --deprecated=true \&> $BOOST_PATH/boostd.log \&|g' "${BOOST_DIR}/docker/devnet/boost/entrypoint.sh"
fi


# Step 4: Build Docker images
info "Building Docker images (this may take 15-30 minutes on first run)..."

BUILD_ARGS="make clean docker/all"
[[ -n "${LOTUS_VERSION}" ]] && BUILD_ARGS+=" lotus_version=${LOTUS_VERSION}"
[[ "${BUILD_LOTUS}" == "1" ]]      && BUILD_ARGS+=" build_lotus=1"
[[ "${FFI_FROM_SOURCE}" == "1" ]]  && BUILD_ARGS+=" ffi_from_source=1"

info "Running: ${BUILD_ARGS}"
eval "${BUILD_ARGS}"

# Step 4: Create data directory
mkdir -p "${DATA_DIR}"

# Step 5: Start the devnet
info "Starting Boost devnet..."
make devnet/up

echo ""
ok "============================================"
ok " Boost devnet is starting up!"
ok "============================================"
echo ""
info "Services: lotus, lotus-miner, boost, booster-http, booster-bitswap"
info ""
info "The initial setup takes up to 20 minutes (proof parameter download)."
info "During startup, error messages and container restarts are normal."
info ""
info "Check status:    ./setup-boost.sh status"
info "Boost UI:        http://localhost:8080"
info "Shell into:      ./setup-boost.sh shell boost"
info "Watch logs:      cd ${BOOST_DIR}/docker/devnet && docker compose logs -f"
info ""
info "Once the Boost UI loads without errors, the devnet is ready."
info ""
info "Quick deal test:"
info "  ./setup-boost.sh shell boost"
info "  ./sample/make-a-deal.sh"
info ""
info "Tear down:       ./setup-boost.sh down"
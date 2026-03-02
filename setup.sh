#!/usr/bin/env bash
# ===========================================================================
# Filecoin Security Devnet
# ===========================================================================
# Deploys a local Filecoin 2k devnet for security research.
# F3 fast bootstrap is ON by default.
#
# Usage:
#   ./setup.sh [options]
#
# Options:
#   --nodes <n>             Number of Lotus nodes (default: 1)
#   --no-fast-f3            Disable F3 fast bootstrap
#   --fevm                  Enable Ethereum RPC
#   --lotus-version <tag>   Checkout specific Lotus release
#   --clean                 Wipe state and start fresh
#   --stop                  Stop all devnet processes
#   --status                Show running devnet info
#   -h, --help              Show this help
#
# Examples:
#   ./setup.sh                    # 1 node, F3 fast, ready to go
#   ./setup.sh --nodes 3 --fevm   # 3-node network with FEVM
#   ./setup.sh --stop             # Shut it all down
# ===========================================================================

set -euo pipefail

# ── Paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/.devnet"
LOTUS_SRC="$WORK_DIR/lotus"
LOGS_DIR="$WORK_DIR/logs"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Defaults ──
NUM_NODES=1
FAST_F3=true
FEVM=false
CLEAN=false
STOP=false
STATUS=false
LOTUS_VERSION=""

BASE_API_PORT=1234
BASE_LIBP2P_PORT=9090

# ── Colors ──
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
ok()   { echo -e "${G}[✓]${NC} $*"; }
info() { echo -e "${B}[*]${NC} $*"; }
warn() { echo -e "${Y}[!]${NC} $*"; }
fail() { echo -e "${R}[✗]${NC} $*" >&2; exit 1; }

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case $1 in
        --nodes)            NUM_NODES="$2"; shift 2 ;;
        --no-fast-f3)       FAST_F3=false; shift ;;
        --fevm)             FEVM=true; shift ;;
        --lotus-version)    LOTUS_VERSION="$2"; shift 2 ;;
        --clean)            CLEAN=true; shift ;;
        --stop)             STOP=true; shift ;;
        --status)           STATUS=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) fail "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ── Lotus env for node 0 (genesis node) ──
export_lotus_env() {
    local node_id="${1:-0}"
    if [[ "$node_id" -eq 0 ]]; then
        export LOTUS_PATH="$WORK_DIR/node0"
        export LOTUS_MINER_PATH="$WORK_DIR/miner0"
    else
        export LOTUS_PATH="$WORK_DIR/node${node_id}"
        unset LOTUS_MINER_PATH 2>/dev/null || true
    fi
    export LOTUS_SKIP_GENESIS_CHECK="_yes_"
    export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
    export CGO_CFLAGS="-D__BLST_PORTABLE__"
}

# ── Stop ──
if $STOP; then
    info "Stopping all devnet processes..."
    pkill -f "lotus-miner" 2>/dev/null && ok "Miner stopped" || true
    pkill -f "lotus daemon" 2>/dev/null && ok "Daemon(s) stopped" || true
    sleep 1
    # Double-check
    pkill -9 -f "lotus" 2>/dev/null || true
    ok "Devnet stopped."
    echo "  State preserved in $WORK_DIR"
    echo "  Wipe everything: ./setup.sh --clean"
    exit 0
fi

# ── Status ──
if $STATUS; then
    echo ""
    echo -e "${BOLD}Devnet Status${NC}"
    echo "─────────────────────────────────────────"
    if [[ -f "$ENV_FILE" ]]; then
        cat "$ENV_FILE"
    else
        warn "No .env found. Devnet may not be initialized."
    fi
    echo ""
    echo "Running processes:"
    ps aux | grep -E "lotus (daemon|miner)" | grep -v grep || echo "  (none)"
    echo "─────────────────────────────────────────"
    exit 0
fi

# ── Preflight ──
info "Checking prerequisites..."
command -v go >/dev/null 2>&1   || fail "Go not found. Install: https://go.dev/dl/"
command -v rustc >/dev/null 2>&1 || fail "Rust not found. Install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
command -v git >/dev/null 2>&1  || fail "Git not found."

ok "Go $(go version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1), Rust $(rustc --version | awk '{print $2}')"

# ── Clean ──
if $CLEAN; then
    warn "Wiping all devnet state..."
    pkill -f "lotus" 2>/dev/null || true
    sleep 2
    rm -rf "$ENV_FILE" "$HOME/.genesis-sectors"
    if [[ -d "$WORK_DIR" ]]; then
        find "$WORK_DIR" -mindepth 1 -maxdepth 1 ! -name "lotus" -exec rm -rf {} +
    fi
    ok "Clean complete (kept Lotus source and binaries)"
fi

mkdir -p "$WORK_DIR" "$LOGS_DIR"

# ── Clone & build Lotus ──
if [[ ! -d "$LOTUS_SRC" ]]; then
    info "Cloning Lotus..."
    git clone https://github.com/filecoin-project/lotus.git "$LOTUS_SRC"
fi

cd "$LOTUS_SRC"

if [[ -n "$LOTUS_VERSION" ]]; then
    git fetch --tags 2>/dev/null
    info "Checking out $LOTUS_VERSION..."
    git checkout "$LOTUS_VERSION"
else
    git fetch --tags 2>/dev/null
    LATEST=$(git tag -l 'v*' --sort=-v:refname | grep -vE 'rc|beta|alpha' | head -1 || echo "")
    if [[ -n "$LATEST" ]]; then
        info "Latest release: $LATEST"
        git checkout "$LATEST" 2>/dev/null || true
    fi
fi

LOTUS_VER=$(git describe --tags --always 2>/dev/null || echo "unknown")

# ── Apply F3 fast bootstrap (default: ON) ──
if $FAST_F3; then
    F3_MANIFEST="$LOTUS_SRC/build/buildconstants/f3manifest_2k.json"
    F3_FAST="$SCRIPT_DIR/config/f3manifest_2k_fast.json"

    if [[ -f "$F3_FAST" ]] && [[ -f "$F3_MANIFEST" ]]; then
        cp "$F3_FAST" "$F3_MANIFEST"
        ok "F3 fast bootstrap applied (BootstrapEpoch=10, Finality=5)"
    elif [[ -f "$F3_MANIFEST" ]]; then
        sed -i 's/"BootstrapEpoch": *[0-9]*/"BootstrapEpoch": 10/' "$F3_MANIFEST"
        sed -i 's/"Finality": *[0-9]*/"Finality": 5/' "$F3_MANIFEST"
        ok "F3 manifest patched inline"
    fi
fi

# ── Build ──
if [[ ! -x "$LOTUS_SRC/lotus" ]]; then
    info "Building Lotus 2k binaries (5-10 min first time)..."
    make 2k 2>&1 | tail -3
    make lotus-shed 2>/dev/null || true
    ok "Build complete ($LOTUS_VER)"
else
    ok "Lotus already built ($LOTUS_VER)"
fi

export PATH="$LOTUS_SRC:$PATH"

# ── Proof parameters ──
PARAMS_DIR="/var/tmp/filecoin-proof-parameters"
if [[ ! -d "$PARAMS_DIR" ]] || [[ $(ls "$PARAMS_DIR" 2>/dev/null | wc -l) -lt 10 ]]; then
    info "Downloading proof parameters (~1 GB)..."
    ./lotus fetch-params 2048
    ok "Proof parameters cached"
else
    ok "Proof parameters already cached"
fi

# ── Check for already running devnet ──
export_lotus_env 0
if ./lotus chain head >/dev/null 2>&1; then
    warn "Devnet already running. Use --stop first or --clean to restart."
    exit 0
fi

# ══════════════════════════════════════════════════════════════
# GENESIS NODE (node 0 + miner)
# ══════════════════════════════════════════════════════════════

NODE0_PATH="$WORK_DIR/node0"
MINER0_PATH="$WORK_DIR/miner0"

if [[ ! -d "$NODE0_PATH/keystore" ]]; then
    info "Initializing genesis..."
    rm -rf "$HOME/.genesis-sectors" "$NODE0_PATH" "$MINER0_PATH"
    mkdir -p "$NODE0_PATH" "$MINER0_PATH"

    export LOTUS_PATH="$NODE0_PATH"
    export LOTUS_MINER_PATH="$MINER0_PATH"
    export LOTUS_SKIP_GENESIS_CHECK="_yes_"

    ./lotus-seed pre-seal --sector-size 2KiB --num-sectors 2
    ./lotus-seed genesis new "$WORK_DIR/localnet.json"
    ./lotus-seed genesis add-miner "$WORK_DIR/localnet.json" \
        "$HOME/.genesis-sectors/pre-seal-t01000.json"
    ok "Genesis created"
fi

# Start genesis daemon
export_lotus_env 0
API_PORT=$BASE_API_PORT
P2P_PORT=$BASE_LIBP2P_PORT

info "Starting genesis node (node0) on API port $API_PORT..."
./lotus daemon \
    --lotus-make-genesis="$WORK_DIR/devgen.car" \
    --genesis-template="$WORK_DIR/localnet.json" \
    --bootstrap=false \
    --api="$API_PORT" \
    > "$LOGS_DIR/node0.log" 2>&1 &

NODE0_PID=$!

# Wait for API
for i in $(seq 1 90); do
    if ./lotus net listen >/dev/null 2>&1; then break; fi
    if ! kill -0 $NODE0_PID 2>/dev/null; then
        fail "Genesis node crashed. Check $LOGS_DIR/node0.log"
    fi
    sleep 1
done
./lotus net listen >/dev/null 2>&1 || fail "Genesis node didn't start. Check $LOGS_DIR/node0.log"
ok "Genesis node running (PID $NODE0_PID)"

# ── FEVM ──
if $FEVM; then
    info "Enabling FEVM..."
    CONF="$NODE0_PATH/config.toml"
    FEVM_CONF="$SCRIPT_DIR/config/lotus-devnet.toml"
    if [[ -f "$FEVM_CONF" ]]; then
        cp "$FEVM_CONF" "$CONF"
    else
        echo -e '\n[Fevm]\n  EnableEthRPC = true\n[Events]\n  EnableActorEventsAPI = true' >> "$CONF"
    fi
    # Restart
    kill $NODE0_PID 2>/dev/null; sleep 2
    ./lotus daemon --bootstrap=false --api="$API_PORT" > "$LOGS_DIR/node0.log" 2>&1 &
    NODE0_PID=$!
    for i in $(seq 1 60); do
        ./lotus net listen >/dev/null 2>&1 && break; sleep 1
    done
    ok "FEVM enabled"
fi

# ── Start miner ──
info "Starting miner..."
export LOTUS_MINER_PATH="$MINER0_PATH"
./lotus wallet import --as-default "$HOME/.genesis-sectors/pre-seal-t01000.key" 2>/dev/null || true

if [[ ! -d "$MINER0_PATH/keystore" ]]; then
    ./lotus-miner init --genesis-miner --actor=t01000 --sector-size=2KiB \
        --pre-sealed-sectors="$HOME/.genesis-sectors" \
        --pre-sealed-metadata="$HOME/.genesis-sectors/pre-seal-t01000.json" \
        --nosync
fi

./lotus-miner run --nosync > "$LOGS_DIR/miner0.log" 2>&1 &
MINER0_PID=$!
ok "Miner running (PID $MINER0_PID)"

# Wait for blocks
info "Waiting for chain to produce blocks..."
sleep 12

# Get genesis node multiaddr for connecting peers
NODE0_MULTIADDR=$(./lotus net listen 2>/dev/null | grep '/ip4/127' | head -1 || echo "")

# ══════════════════════════════════════════════════════════════
# ADDITIONAL NODES (node1, node2, ...)
# ══════════════════════════════════════════════════════════════

declare -a EXTRA_NODE_PIDS=()

if [[ $NUM_NODES -gt 1 ]]; then
    info "Starting $((NUM_NODES - 1)) additional node(s)..."

    for n in $(seq 1 $((NUM_NODES - 1))); do
        NODE_PATH="$WORK_DIR/node${n}"
        NODE_API_PORT=$((BASE_API_PORT + n))
        NODE_P2P_PORT=$((BASE_LIBP2P_PORT + n))

        mkdir -p "$NODE_PATH"
        export LOTUS_PATH="$NODE_PATH"

        # Start with shared genesis
        info "  Starting node${n} (API port $NODE_API_PORT)..."
        ./lotus daemon \
            --genesis="$WORK_DIR/devgen.car" \
            --bootstrap=false \
            --api="$NODE_API_PORT" \
            > "$LOGS_DIR/node${n}.log" 2>&1 &

        NPID=$!
        EXTRA_NODE_PIDS+=("$NPID")

        # Wait for it
        for i in $(seq 1 60); do
            if LOTUS_PATH="$NODE_PATH" ./lotus --repo="$NODE_PATH" net listen >/dev/null 2>&1; then break; fi
            sleep 1
        done

        # Connect to genesis node
        if [[ -n "$NODE0_MULTIADDR" ]]; then
            LOTUS_PATH="$NODE_PATH" ./lotus --repo="$NODE_PATH" net connect "$NODE0_MULTIADDR" 2>/dev/null || true
        fi

        # Apply FEVM config if enabled
        if $FEVM; then
            NCONF="$NODE_PATH/config.toml"
            if [[ -f "$SCRIPT_DIR/config/lotus-devnet.toml" ]]; then
                cp "$SCRIPT_DIR/config/lotus-devnet.toml" "$NCONF"
            else
                echo -e '\n[Fevm]\n  EnableEthRPC = true\n[Events]\n  EnableActorEventsAPI = true' >> "$NCONF"
            fi
            kill $NPID 2>/dev/null; sleep 1
            LOTUS_PATH="$NODE_PATH" ./lotus daemon \
                --genesis="$WORK_DIR/devgen.car" \
                --bootstrap=false \
                --api="$NODE_API_PORT" \
                > "$LOGS_DIR/node${n}.log" 2>&1 &
            NPID=$!
            EXTRA_NODE_PIDS[-1]=$NPID
            for i in $(seq 1 30); do
                LOTUS_PATH="$NODE_PATH" ./lotus --repo="$NODE_PATH" net listen >/dev/null 2>&1 && break; sleep 1
            done
            if [[ -n "$NODE0_MULTIADDR" ]]; then
                LOTUS_PATH="$NODE_PATH" ./lotus --repo="$NODE_PATH" net connect "$NODE0_MULTIADDR" 2>/dev/null || true
            fi
        fi

        ok "  node${n} running (PID $NPID, API :${NODE_API_PORT})"
    done
fi

# ══════════════════════════════════════════════════════════════
# COLLECT INFO & WRITE .env
# ══════════════════════════════════════════════════════════════

export_lotus_env 0

CHAIN_HEAD=$(./lotus chain list --count 1 2>/dev/null | head -1 || echo "?")
WALLET=$(./lotus wallet default 2>/dev/null || echo "?")
BALANCE=$(./lotus wallet balance "$WALLET" 2>/dev/null || echo "?")
API_INFO=$(./lotus auth api-info --perm=admin 2>/dev/null | cut -f2 -d= || echo "?")
MINER_API_INFO=$(LOTUS_MINER_PATH="$MINER0_PATH" ./lotus-miner auth api-info --perm=admin 2>/dev/null | cut -f2 -d= || echo "?")

# Write .env
cat > "$ENV_FILE" << EOF
# ═══════════════════════════════════════════════════════════════
# Filecoin Security Devnet — Environment
# ═══════════════════════════════════════════════════════════════
# Source this file:  source .env
# Generated:         $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Lotus version:     $LOTUS_VER

# ── Core ──
export LOTUS_PATH="$NODE0_PATH"
export LOTUS_MINER_PATH="$MINER0_PATH"
export LOTUS_SKIP_GENESIS_CHECK="_yes_"
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"
export PATH="$LOTUS_SRC:\$PATH"

# ── API Credentials ──
export FULLNODE_API_INFO="$API_INFO"
export MINER_API_INFO="$MINER_API_INFO"

# ── Genesis Node (node0) ──
LOTUS_NODE0_API="http://127.0.0.1:${BASE_API_PORT}/rpc/v0"
LOTUS_NODE0_P2P="$NODE0_MULTIADDR"
LOTUS_NODE0_PID=$NODE0_PID

# ── Miner ──
LOTUS_MINER_PID=$MINER0_PID
LOTUS_MINER_ACTOR="t01000"

# ── Wallet ──
LOTUS_DEFAULT_WALLET="$WALLET"
LOTUS_WALLET_BALANCE="$BALANCE"

# ── Chain ──
LOTUS_BLOCK_TIME="~4 seconds"
LOTUS_SECTOR_SIZE="2 KiB"
LOTUS_GENESIS_CAR="$WORK_DIR/devgen.car"
EOF

# F3 info
if $FAST_F3; then
    cat >> "$ENV_FILE" << EOF

# ── F3 (Fast Finality) ──
F3_BOOTSTRAP_EPOCH=10
F3_FINALITY=5
F3_GOSSIPSUB_TOPIC="/f3/granite/0.0.3/2k"
F3_STATUS="active (fast bootstrap)"
EOF
fi

# FEVM info
if $FEVM; then
    cat >> "$ENV_FILE" << EOF

# ── FEVM / Ethereum RPC ──
FEVM_ENABLED=true
ETH_RPC_URL="http://127.0.0.1:${BASE_API_PORT}/rpc/v1"
EOF
fi

# Additional nodes
if [[ $NUM_NODES -gt 1 ]]; then
    echo "" >> "$ENV_FILE"
    echo "# ── Additional Nodes ──" >> "$ENV_FILE"
    for n in $(seq 1 $((NUM_NODES - 1))); do
        NODE_API_PORT=$((BASE_API_PORT + n))
        echo "LOTUS_NODE${n}_API=\"http://127.0.0.1:${NODE_API_PORT}/rpc/v0\"" >> "$ENV_FILE"
        echo "LOTUS_NODE${n}_PATH=\"$WORK_DIR/node${n}\"" >> "$ENV_FILE"
        echo "LOTUS_NODE${n}_PID=${EXTRA_NODE_PIDS[$((n-1))]:-?}" >> "$ENV_FILE"
    done
fi

# GossipSub topics
cat >> "$ENV_FILE" << EOF

# ── GossipSub Topics ──
GOSSIPSUB_BLOCKS="/fil/blocks/2k"
GOSSIPSUB_MESSAGES="/fil/msgs/2k"
GOSSIPSUB_F3="/f3/granite/0.0.3/2k"

# ── Logs ──
LOG_NODE0="$LOGS_DIR/node0.log"
LOG_MINER0="$LOGS_DIR/miner0.log"
EOF

# ══════════════════════════════════════════════════════════════
# PRINT SUMMARY
# ══════════════════════════════════════════════════════════════

echo ""
echo -e "${C}══════════════════════════════════════════════════════════${NC}"
echo -e "${C}  ${BOLD}Filecoin Security Devnet${NC}"
echo -e "${C}══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Network${NC}"
echo -e "  Lotus version:    $LOTUS_VER"
echo -e "  Chain height:     ${G}$CHAIN_HEAD${NC}"
echo "  Block time:       ~4 seconds"
echo "  Sector size:      2 KiB"
echo "  Nodes:            $NUM_NODES"
echo ""
echo -e "  ${BOLD}Genesis Node (node0)${NC}"
echo "  API:              http://127.0.0.1:${BASE_API_PORT}/rpc/v0"
echo "  P2P:              $NODE0_MULTIADDR"
echo "  Wallet:           $WALLET"
echo "  Balance:          $BALANCE"
echo "  PID:              $NODE0_PID"
echo ""
echo -e "  ${BOLD}Miner${NC}"
echo "  Actor:            t01000"
echo "  PID:              $MINER0_PID"

if [[ $NUM_NODES -gt 1 ]]; then
    echo ""
    echo -e "  ${BOLD}Additional Nodes${NC}"
    for n in $(seq 1 $((NUM_NODES - 1))); do
        NODE_API_PORT=$((BASE_API_PORT + n))
        echo "  node${n}:            API :${NODE_API_PORT}  PID ${EXTRA_NODE_PIDS[$((n-1))]:-?}"
    done
fi

echo ""
echo -e "  ${BOLD}Configuration${NC}"
if $FAST_F3; then
    echo -e "  F3:               ${G}Active (epoch 10)${NC}"
    echo "  F3 topic:         /f3/granite/0.0.3/2k"
else
    echo -e "  F3:               Default (epoch 1000)"
fi
if $FEVM; then
    echo -e "  FEVM:             ${G}Enabled${NC}"
    echo "  Eth RPC:          http://127.0.0.1:${BASE_API_PORT}/rpc/v1"
else
    echo "  FEVM:             Off (use --fevm to enable)"
fi

echo ""
echo -e "  ${BOLD}GossipSub Topics${NC}"
echo "  Blocks:           /fil/blocks/2k"
echo "  Messages:         /fil/msgs/2k"
echo "  F3:               /f3/granite/0.0.3/2k"

echo ""
echo -e "  ${BOLD}Files${NC}"
echo "  .env:             $ENV_FILE"
echo "  Genesis CAR:      $WORK_DIR/devgen.car"
echo "  Logs:             $LOGS_DIR/"

echo ""
echo -e "  ${BOLD}Quick Commands${NC}"
echo "  source .env                              # Load environment"
echo "  lotus chain head                         # Check height"
echo "  lotus net listen                         # Your P2P address"
echo "  lotus wallet list                        # Wallets & balances"
echo "  lotus send <addr> 100                    # Fund a wallet"
echo "  lotus net peers                          # Connected peers"
echo "  ./setup.sh --status                      # Check status"
echo "  ./setup.sh --stop                        # Shut down"
echo ""
echo -e "${C}══════════════════════════════════════════════════════════${NC}"
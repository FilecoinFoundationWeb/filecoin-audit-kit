# Filecoin Security Devnet

Spin up a local Filecoin network for security research. One command, running in minutes.

**Bounty program:** [immunefi.com/bug-bounty/filecoin](https://immunefi.com/bug-bounty/filecoin/)

---

## Quick Start

```bash
git clone https://github.com/<org>/<repo>.git
cd <repo>
./setup.sh
```

That's it. You get a Lotus 2k devnet with F3 fast bootstrap, FEVM (Ethereum RPC) enabled, a funded wallet, and a `.env` file with everything you need.

### Options

```bash
./setup.sh                         # 1 node, F3 fast, FEVM on — ready to go
./setup.sh --nodes 3               # 3-node network (for consensus/p2p testing)
./setup.sh --no-fevm               # Disable Ethereum RPC if you don't need it
./setup.sh --status                # Check what's running
./setup.sh --stop                  # Shut it all down
./setup.sh --clean                 # Wipe everything and start fresh
```

| Flag | Description |
|---|---|
| `--nodes <n>` | Number of Lotus nodes (default: 1). Extra nodes sync from genesis and connect to node0 automatically. |
| `--no-fevm` | Disable Ethereum RPC (enabled by default) |
| `--no-fast-f3` | Disable F3 fast bootstrap (default is ON — F3 activates at epoch 10 instead of 1000) |
| `--lotus-version <tag>` | Pin a specific Lotus release |
| `--clean` | Wipe all state |
| `--stop` | Stop all processes |
| `--status` | Print running devnet info |

### What You Get

After `./setup.sh` completes, it prints all network details and writes a `.env` file:

```bash
source .env   # Load everything into your shell
```

The `.env` contains:

- `FULLNODE_API_INFO` — Lotus API credential (pass to any tool that talks to Lotus)
- `MINER_API_INFO` — Miner API credential
- `LOTUS_NODE0_API` — RPC endpoint URL
- `LOTUS_NODE0_P2P` — libp2p multiaddr (connect exploits here)
- `LOTUS_DEFAULT_WALLET` — Pre-funded wallet address
- `GOSSIPSUB_*` — GossipSub topic names for blocks, messages, F3
- `F3_*` — F3 config (bootstrap epoch, finality, topic)
- `ETH_RPC_URL` — Ethereum RPC endpoint (always set unless `--no-fevm`)
- Per-node API ports and PIDs for multi-node setups

### Prerequisites

| | Version | Install |
|---|---|---|
| Go | ≥ 1.22 | [go.dev/dl](https://go.dev/dl/) |
| Rust | ≥ 1.75 | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Git | any | `apt install git` / `brew install git` |

**Ubuntu/Debian:**
```bash
sudo apt install -y mesa-opencl-icd ocl-icd-opencl-dev gcc git bzr jq pkg-config \
  curl clang build-essential hwloc libhwloc-dev wget
```

**macOS:**
```bash
brew install jq pkg-config hwloc
```

---

## Multi-Node Networks

Use `--nodes` to spin up multiple Lotus nodes. This is useful for testing p2p protocol bugs, consensus attacks, eclipse attacks, or anything where you need multiple peers.

```bash
./setup.sh --nodes 3
```

This creates:

- **node0**: Genesis node + miner (API port 1234)
- **node1**: Syncing peer (API port 1235)
- **node2**: Syncing peer (API port 1236)

All nodes share the same genesis and are automatically connected. Talk to a specific node by setting `LOTUS_PATH`:

```bash
source .env

# Talk to node0 (default)
lotus chain head

# Talk to node1
LOTUS_PATH=.devnet/node1 lotus chain head

# Talk to node2
LOTUS_PATH=.devnet/node2 lotus chain head
```

---

## Building from Source (For Code Modifications)

If you need to modify Lotus, Go-F3, or any dependency to develop your PoC, build manually instead of using `./setup.sh`.

### Lotus

```bash
git clone https://github.com/filecoin-project/lotus.git
cd lotus
git checkout <release-tag>

# Make your changes, then build
make 2k
./lotus fetch-params 2048
```

Then follow the [Manual Devnet Initialization](#manual-devnet-initialization) steps below.

### Go-F3

Go-F3 is a Go module inside Lotus. To test local changes:

```bash
git clone https://github.com/filecoin-project/go-f3.git

# Point Lotus at your local copy
cd lotus
go mod edit -replace github.com/filecoin-project/go-f3=../go-f3

# Make changes in go-f3, then rebuild Lotus
make 2k
```

Key Go-F3 paths:

| Path | What's There |
|---|---|
| `gpbft/` | Core GPBFT consensus + CBOR codegen |
| `host.go` | GossipSub message validation |
| `certexchange/` | Certificate exchange protocol |

### Manual Devnet Initialization

After building, initialize and run:

```bash
export LOTUS_PATH=~/.lotus-local-net
export LOTUS_MINER_PATH=~/.lotus-miner-local-net
export LOTUS_SKIP_GENESIS_CHECK=_yes_
export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"
export CGO_CFLAGS="-D__BLST_PORTABLE__"

rm -rf ~/.genesis-sectors $LOTUS_PATH $LOTUS_MINER_PATH

./lotus-seed pre-seal --sector-size 2KiB --num-sectors 2
./lotus-seed genesis new localnet.json
./lotus-seed genesis add-miner localnet.json ~/.genesis-sectors/pre-seal-t01000.json

# Terminal 1: daemon
./lotus daemon --lotus-make-genesis=devgen.car --genesis-template=localnet.json --bootstrap=false

# Terminal 2: miner
./lotus wallet import --as-default ~/.genesis-sectors/pre-seal-t01000.key
./lotus-miner init --genesis-miner --actor=t01000 --sector-size=2KiB \
  --pre-sealed-sectors=$HOME/.genesis-sectors \
  --pre-sealed-metadata=$HOME/.genesis-sectors/pre-seal-t01000.json --nosync
./lotus-miner run --nosync

# Terminal 3: verify
./lotus chain head
./lotus net listen
```

**Adding more nodes (from official Lotus docs):** share `devgen.car` and start with `--genesis=devgen.car --api <port>`, then connect with `lotus net connect <node0-multiaddr>`.

---

## PoC Submission Requirements

### What We Accept

Every submission needs a working PoC on a local devnet. Include:

1. **Environment** — Lotus version, source modifications (diffs), config changes
2. **Setup steps** — How to reproduce your devnet configuration
3. **Exploit code** — Standalone, runnable
4. **Execution output** — Logs showing the exploit
5. **Impact evidence** — Crash traces, state diffs, chain behavior
6. **Written analysis** — Root cause, affected code, impact justification

### What We Reject

| Submission | Why |
|---|---|
| Unit tests as sole PoC | Don't exercise consensus, networking, or state sync |
| Fuzzer crashes without devnet reproduction | Must show reachability from external input |
| Static analysis output | Tool output ≠ exploitability |
| Theoretical writeups without code | Show it, don't tell it |
| Screenshots/videos as sole evidence | Supplement, don't replace |
| Unvalidated AI-generated reports | Closed without review |


## Troubleshooting

| Issue | Fix |
|---|---|
| Build fails with CGO errors | `export CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"` |
| Chain not advancing | Both daemon and miner must be running. Miner needs `--nosync`. |
| F3 not activating | Must edit f3manifest **before** `make 2k`. Check `BootstrapEpoch ≥ Finality`. |
| Port conflict | Use `--api <port>` or `--nodes` which auto-assigns ports |
| macOS Apple Silicon linker errors | `export LIBRARY_PATH="/opt/homebrew/lib"` |

---

## Resources

| | |
|---|---|
| Bounty Program | [immunefi.com/bug-bounty/filecoin](https://immunefi.com/bug-bounty/filecoin/) |
| Lotus | [github.com/filecoin-project/lotus](https://github.com/filecoin-project/lotus) |
| Go-F3 | [github.com/filecoin-project/go-f3](https://github.com/filecoin-project/go-f3) |
| Boost | [github.com/filecoin-project/boost](https://github.com/filecoin-project/boost) |
| Filecoin Spec | [spec.filecoin.io](https://spec.filecoin.io) |
| Lotus API | [lotus.filecoin.io/reference](https://lotus.filecoin.io/reference/) |
| Lotus Devnet Guide | [lotus.filecoin.io/lotus/developers/local-network](https://lotus.filecoin.io/lotus/developers/local-network/) |
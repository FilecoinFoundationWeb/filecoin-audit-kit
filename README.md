# Filecoin Security Devnet (Audit Kit)

A high-performance research environment for Filecoin security audits. Spin up a local network with F3 fast finality, FEVM support, and pre-funded accounts in minutes.

**Bounty Program:** [immunefi.com/bug-bounty/filecoin/](https://immunefi.com/bug-bounty/filecoin/)

---

## 🚀 Quick Start

The simplest way to get a local devnet running for smart contract audits or basic protocol research.

```bash
git clone https://github.com/FilecoinFoundationWeb/filecoin-audit-kit.git
cd filecoin-audit-kit
./setup.sh
```

### What's included?
- **Lotus 2k Devnet**: A lightweight Filecoin network configuration.
- **F3 Fast Finality**: Configured to activate at epoch 10 for rapid testing.
- **FEVM Ready**: Ethereum RPC enabled by default (`http://localhost:1234/rpc/v1`).
- **Pre-funded Wallet**: Automatically generated and funded with 1,000,000 FIL.
- **Auto-Config**: Generates a `.env` file with all API credentials and multiaddrs.

### Core CLI Options
| Selection | Command |
| :--- | :--- |
| **Standard Setup** | `./setup.sh` |
| **Multi-Node (P2P)** | `./setup.sh --nodes 3` |
| **Specific Release** | `./setup.sh --lotus-version v1.30.0` |
| **Maintenance** | `./setup.sh --status` \| `--stop` \| `--clean` |

---

## 🛠️ Manual Development & Patching

When you need to modify the Lotus source code or test local patches for vulnerabilities.

### 1. Build from Source
If you are working on a custom branch or have applied patches to the Lotus repository:

```bash
cd lotus
# Apply your patches
make 2k
./lotus fetch-params 2048
```

### 2. Manual Devnet Initialization
If you want granular control over the initialization process without using the automation script:

```bash
export LOTUS_PATH=~/.lotus-local-net
export LOTUS_MINER_PATH=~/.lotus-miner-local-net
export LOTUS_SKIP_GENESIS_CHECK=_yes_

# 1. Generate Genesis
./lotus-seed pre-seal --sector-size 2KiB --num-sectors 2
./lotus-seed genesis new localnet.json
./lotus-seed genesis add-miner localnet.json ~/.genesis-sectors/pre-seal-t01000.json

# 2. Start Daemon
./lotus daemon --lotus-make-genesis=devgen.car --genesis-template=localnet.json --bootstrap=false

# 3. Start Miner
./lotus wallet import --as-default ~/.genesis-sectors/pre-seal-t01000.key
./lotus-miner init --genesis-miner --actor=t01000 --sector-size=2KiB \
  --pre-sealed-sectors=$HOME/.genesis-sectors \
  --pre-sealed-metadata=$HOME/.genesis-sectors/pre-seal-t01000.json --nosync
./lotus-miner run --nosync
```

---

## 🧬 Modifying Source Code

### 🧪 Modifying Go-F3
Go-F3 is a Go module inside Lotus. To test local changes, use a `replace` directive:

```bash
# Clone go-f3 alongside your Lotus checkout
git clone https://github.com/filecoin-project/go-f3.git

# Point Lotus at your local copy
cd lotus
go mod edit -replace github.com/filecoin-project/go-f3=../go-f3

# Make changes in go-f3, then rebuild Lotus
make 2k
```

### 🧠 Modifying Built-in Actors
Built-in actors are Rust code compiled to Wasm and bundled into Lotus.

```bash
# Clone the built-in actors repo
git clone https://github.com/filecoin-project/builtin-actors.git
cd builtin-actors

# 1. Make your changes to the actor code (Rust)
# Key directories: actors/miner, actors/market, actors/power, etc.

# 2. Build the actor bundle for devnet
make bundle-devnet

# 3. Integrate into Lotus
# OPTION A: Build-time (replace and rebuild)
cp output/builtin-actors-devnet.car ~/lotus/build/actors/
cd ~/lotus && make 2k

# OPTION B: Runtime Override (No rebuild needed!)
export LOTUS_BUILTIN_ACTORS_V12_BUNDLE=/path/to/builtin-actors-devnet.car
./lotus daemon ...
```

---

## 🔍 Testing & Analysis

### Inspecting Actor State
Use these commands to verify the impact of your exploit:

```bash
# Read actor state as JSON
./lotus state read-state <address>

# Inspect a specific tipset
./lotus chain get-block <block-cid>

# Invoke a method on an actor (advanced)
./lotus chain invoke <actor-address> <method-number> <params-hex>
```


---

## 📋 Submission Requirements

Every vulnerability report must be accompanied by a reproducible PoC.

| Requirement | Description |
| :--- | :--- |
| **Reproducibility** | Must run on a clean devnet setup using this kit. |
| **Environment** | Specify Lotus/Boost versions and include any `.diff` files. |
| **Exploit Code** | Standalone script or program that triggers the vulnerability. |
| **Impact Evidence** | Logs, panics, or state diffs proving the exploit. |

---

## 🔧 Troubleshooting

> [!TIP]
> **Build Failures?** Ensure you have `CGO_CFLAGS_ALLOW="-D__BLST_PORTABLE__"` set.
>
> **Chain Stalled?** Ensure the Miner is running and logs show `Mining`.
>
> **Port Conflicts?** Use `./setup.sh --stop` to kill any hanging processes from previous runs.

---

## 📖 Resources

- **Main Discovery**: [Filecoin Spec](https://spec.filecoin.io)
- **Official Docs**: [Lotus Documentation](https://lotus.filecoin.io)
- **Bounty Program**: [Immunefi](https://immunefi.com/bug-bounty/filecoin/)
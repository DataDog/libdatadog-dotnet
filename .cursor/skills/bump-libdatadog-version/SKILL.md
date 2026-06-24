---
name: bump-libdatadog-version
description: >-
  Bump the pinned upstream libdatadog version for libdatadog-dotnet. Use when
  the user says "Bump to the latest version of libdatadog", "Bump to libdatadog
  vX.Y.Z", or otherwise asks to upgrade / update the libdatadog version in this
  repo. Handles the LIBDATADOG_VERSION file and any required Rust toolchain pin
  update.
disable-model-invocation: true
---

# Bump libdatadog Version

Upgrades the pinned upstream [libdatadog](https://github.com/DataDog/libdatadog)
version for this packaging repo. The version lives in a single file
(`LIBDATADOG_VERSION`, no `v` prefix), and a correct bump may also require a
Rust toolchain pin update.

## Workflow

Copy this checklist and track progress:

```
- [ ] Step 1: Resolve the target version
- [ ] Step 2: Update LIBDATADOG_VERSION
- [ ] Step 3: Check upstream Rust MSRV; update the pin if changed
- [ ] Step 4: Check the macOS runner pin (only if MSRV/toolchain shifted)
- [ ] Step 5: Update AGENTS.md "Recent Changes" + README if needed
- [ ] Step 6: Summarize and propose next steps (build / PR)
```

### Step 1: Resolve the target version

- **"Bump to libdatadog vX.Y.Z"** → target is `X.Y.Z` (strip any leading `v`).
- **"Bump to the latest version"** → fetch the latest stable release (already
  strips the leading `v`):

```bash
curl -fsSL https://api.github.com/repos/DataDog/libdatadog/releases/latest \
  | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"v?([^"]+)".*/\1/'
```

Read the current pin with the Read tool on `LIBDATADOG_VERSION`. If it already
equals the target, tell the user and stop. Otherwise **remember this value as
`OLD_VERSION`** — Step 2 overwrites the file, and Step 3 needs the old version
to detect an MSRV change.

### Step 2: Update LIBDATADOG_VERSION

Write the bare version (no `v`, single trailing newline) to `LIBDATADOG_VERSION`.

### Step 3: Check upstream Rust MSRV; update the pin if changed

The Rust toolchain is pinned to **match upstream libdatadog's MSRV**. Building
with a different toolchain than upstream can introduce subtle codegen / ABI
differences. The MSRV lives in `rust-version` under `[workspace.package]` in
libdatadog's root `Cargo.toml`.

Compare the MSRV at the **target** tag against the MSRV at the **`OLD_VERSION`**
tag (the value captured in Step 1) — don't compare against a hardcoded number,
since the repo's pin moves over time, and don't re-read `LIBDATADOG_VERSION`
here (Step 2 already overwrote it with `TARGET`, so it would falsely report no
change):

```bash
extract_msrv() {  # $1 = libdatadog tag without leading v
  curl -fsSL "https://raw.githubusercontent.com/DataDog/libdatadog/v$1/Cargo.toml" \
    | grep -i 'rust-version' | head -n1 \
    | sed -E 's/.*"([0-9]+\.[0-9]+(\.[0-9]+)?)".*/\1/'
}
echo "old:    $(extract_msrv <OLD_VERSION>)"   # the pin captured in Step 1
echo "target: $(extract_msrv <TARGET>)"
```

- **Same value** → MSRV unchanged, leave the toolchain alone. Skip to Step 4.
- **Different value** → the bump needs a toolchain pin update. Sanity-check the
  target MSRV against what's actually pinned in this repo:

```bash
grep -rn 'rust-version\|RUST_VERSION\|default-toolchain\|rustup' . \
  --exclude-dir=.cursor --exclude-dir=.git
```

Then update **all** of these from the old MSRV to the target MSRV:

- `.github/workflows/build-platform.yml` — the `Setup Rust` step (`rustup install` / `rustup default`)
- `tools/docker/Dockerfile.centos-aarch64` — `--default-toolchain`
- `tools/docker/Dockerfile.musl-x64` — `ARG RUST_VERSION`
- `tools/docker/Dockerfile.musl-aarch64` — `ARG RUST_VERSION`
- `README.md` — the prerequisites line

Keep this in the **same commit** as the `LIBDATADOG_VERSION` bump — the two are
coupled (building the new version with the old toolchain is exactly the
mismatch the pin guards against). The change is picked up automatically on the
next build; there are no prebuilt/pushed images to refresh:

- Docker-image platforms (aarch64-gnu, musl-x64, musl-aarch64): `build.sh`
  rebuilds each image from its Dockerfile every run (`docker build -f ...`), so
  editing `ARG RUST_VERSION` / `--default-toolchain` recompiles with the new
  toolchain.
- Host-toolchain platforms (x86_64-gnu, macOS, Windows): the pin comes from the
  `Setup Rust` step in `build-platform.yml`, which runs fresh each time.
  (`Dockerfile.centos` for x86_64-gnu installs no Rust — it mounts the host
  toolchain — which is why it is not in the list above.)

### Step 4: Check the macOS runner pin (only if the toolchain shifted)

macOS runners are pinned (`macos-14` / `macos-14-large`, Sonoma) to match
upstream libdatadog's `libddprof-build` pipeline. This rarely changes. Only
revisit it if upstream moved its macOS build image; the `os:` fields live in
`.github/workflows/build-platform.yml`.

### Step 5: Update docs

- Add a dated entry to the top of the **Recent Changes** list in `AGENTS.md`
  (e.g. `- **YYYY-MM**: Bumped to libdatadog v<TARGET>.` and note the MSRV change
  if any).
- The README's libdatadog references are version-agnostic (they read the file),
  so only edit it if the Rust pin changed (Step 3).

### Step 6: Summarize and propose next steps

Report what changed (version, and MSRV pin if touched). Then offer to:

- Run a local smoke build: `./build.sh --platform x86_64-unknown-linux-gnu --clean`
- Open a PR (CI's **Build** workflow runs all 8 platforms on the PR).

Do not commit or open a PR unless the user asks.

**Always flag the coordinated-rollout caveat** so the bump isn't mistaken for a
complete, self-contained change: bumping `LIBDATADOG_VERSION` (and cutting a
release) here is fine on its own, but libdatadog's profiling FFI API drifts
between tags. The new version is only proven compatible once the dd-trace-dotnet
PR that adopts the new libdatadog-dotnet **release tag** (e.g. `v1.3.5` — a
different number from `LIBDATADOG_VERSION`) compiles its native profiler
(`cor_profiler.cpp`, `dd_profiler_constants.h`) against the matching profiling
headers in the same rollout. This is a coordination requirement on the tracer
side, **not** a precondition that blocks the bump here.

## Notes

- Feature set is **not** part of a version bump — leave `FEATURES` / `Features`
  / workflow `features` defaults alone unless the user explicitly asks.
- The `curl` commands need network access but no auth or extra tooling (they
  hit public release/raw endpoints). If `curl` is unavailable, `wget -qO-` works
  with the same URLs.

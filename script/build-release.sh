#!/usr/bin/env bash
# Build a release-channel opencode binary locally.
#
# Why this script exists: a plain `bun run script/build.ts` picks up the current
# git branch as its channel, which produces a preview build (`0.0.0-v2-<ts>`,
# `opencode-v2.db`, `service-v2.json`, hashed port). A "release" build needs
# channel=latest and an explicit version, plus a bun that satisfies the repo's
# `packageManager` pin.
#
# See docs/learn/local-release-build.md for the full walkthrough and pitfalls.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly DEFAULT_SERVICE_PORT=49374

channel="${OPENCODE_CHANNEL:-latest}"
version="${OPENCODE_VERSION:-}"
target=""
outdir=""
single=1
skip_install=1
skip_web=0
ci_compiler=0
smoke=0
lockfile_guard=1

usage() {
  cat <<'EOF'
Usage: script/build-release.sh [options]

Build a "release" (channel=latest) opencode binary for the host platform.

Options:
  --version <semver>     Version baked into the binary (default: repo package.json)
  --channel <name>       OPENCODE_CHANNEL (default: latest; anything else is a preview)
  --target <triple>      Build one specific target, e.g. linux-x64, linux-x64-musl
  --all                  Build every target instead of only the host
  --outdir <path>        Output directory (default: packages/cli/dist)
  --skip-web-ui          Embed an empty web UI archive (smaller/faster, no browser UI)
  --with-cross-install   Let build.ts install @opentui/core and pty for all platforms
  --ci-compiler          Download the pinned bun release as compiler (CI parity)
  --smoke                Run script/service-smoke.ts afterwards
  --no-lockfile-guard    Keep bun.lock/package.json changes made by the build
  -h, --help             Show this help

Environment:
  OPENCODE_CHANNEL, OPENCODE_VERSION   Same meaning as for build.ts
  OPENCODE_BUILD_CACHE                 Where to cache the pinned bun (default: ~/.cache/opencode-build)

Examples:
  script/build-release.sh
  script/build-release.sh --version 2.0.24
  script/build-release.sh --version 2.0.24 --target linux-x64 --smoke
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version needs a value"
      version="$2"
      shift 2
      ;;
    --version=*)
      version="${1#*=}"
      shift
      ;;
    --channel)
      [[ $# -ge 2 ]] || die "--channel needs a value"
      channel="$2"
      shift 2
      ;;
    --channel=*)
      channel="${1#*=}"
      shift
      ;;
    --target)
      [[ $# -ge 2 ]] || die "--target needs a value"
      target="$2"
      single=0
      shift 2
      ;;
    --target=*)
      target="${1#*=}"
      single=0
      shift
      ;;
    --all)
      single=0
      shift
      ;;
    --outdir)
      [[ $# -ge 2 ]] || die "--outdir needs a value"
      outdir="$2"
      shift 2
      ;;
    --outdir=*)
      outdir="${1#*=}"
      shift
      ;;
    --skip-web-ui)
      skip_web=1
      shift
      ;;
    --with-cross-install)
      skip_install=0
      shift
      ;;
    --ci-compiler)
      ci_compiler=1
      shift
      ;;
    --smoke)
      smoke=1
      shift
      ;;
    --no-lockfile-guard)
      lockfile_guard=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

cd "$ROOT"

# --- version -----------------------------------------------------------------

if [[ -z "$version" ]]; then
  version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' package.json | head -n1)"
  [[ -n "$version" ]] || die "cannot read version from package.json; pass --version"
fi
[[ "$version" != 0.0.0-* ]] || die "refusing preview version '$version'; pass a release version like 2.0.24"
[[ "$channel" == "latest" ]] || printf 'warning: channel=%s is not "latest"; output is a preview build\n' "$channel" >&2

# --- bun ---------------------------------------------------------------------

required_bun="$(sed -n 's/.*"packageManager": *"bun@\([^"]*\)".*/\1/p' package.json | head -n1)"
[[ -n "$required_bun" ]] || die "cannot read packageManager from package.json"

ver_num() {
  awk -F'[.+-]' '{ printf "%03d%03d%03d", $1, $2, $3 }' <<<"$1"
}

bun_is_compatible() {
  local actual="${1:-}"
  [[ -n "$actual" ]] || return 1
  [[ "${actual%%.*}" == "${required_bun%%.*}" ]] || return 1
  (( $(ver_num "$actual") >= $(ver_num "$required_bun") ))
}

host_platform="$(uname -s)"
host_arch="$(uname -m)"

bun_asset() {
  case "$host_platform-$host_arch" in
    Linux-x86_64|Linux-amd64) echo "bun-linux-x64" ;;
    Linux-aarch64|Linux-arm64) echo "bun-linux-aarch64" ;;
    Darwin-x86_64) echo "bun-darwin-x64" ;;
    Darwin-arm64|Darwin-aarch64) echo "bun-darwin-aarch64" ;;
    *) return 1 ;;
  esac
}

if command -v bun >/dev/null 2>&1 && bun_is_compatible "$(bun --version 2>/dev/null || true)"; then
  BUN="$(command -v bun)"
  note "using bun $(bun --version) ($BUN)"
else
  asset="$(bun_asset)" || die "no standalone bun build for $host_platform-$host_arch; install bun@$required_bun manually"
  cache="${OPENCODE_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode-build}"
  bun_dir="$cache/bun-v$required_bun"
  BUN="$bun_dir/$asset/bun"
  if [[ ! -x "$BUN" ]]; then
    note "installing bun $required_bun into $bun_dir"
    mkdir -p "$bun_dir"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/oven-sh/bun/releases/download/bun-v$required_bun/$asset.zip"
    curl -fL --progress-bar -o "$tmp/bun.zip" "$url" || die "failed to download $url"
    unzip -oq "$tmp/bun.zip" -d "$bun_dir"
    rm -rf "$tmp"
    trap - EXIT
  fi
  [[ -x "$BUN" ]] || die "bun binary missing at $BUN"
  export PATH="$(dirname "$BUN"):$PATH"
  note "using bun $("$BUN" --version) ($BUN)"
fi

# --- dependencies ------------------------------------------------------------

if [[ ! -d node_modules/@opencode/script ]]; then
  note "workspace dependencies missing; running bun install"
  bun install --frozen-lockfile
fi

# --- build -------------------------------------------------------------------

lockfile_dirty_before=0
if (( lockfile_guard )); then
  git diff --quiet -- bun.lock packages/cli/package.json || lockfile_dirty_before=1
fi

flags=()
(( single )) && flags+=(--single)
[[ -n "$target" ]] && flags+=(--target="$target")
(( skip_web )) && flags+=(--skip-web-ui)
(( skip_install )) && flags+=(--skip-install)
if [[ -n "$outdir" ]]; then
  [[ "$outdir" == /* ]] || outdir="$PWD/$outdir"
  flags+=(--outdir="$outdir")
fi

env_args=(OPENCODE_CHANNEL="$channel" OPENCODE_VERSION="$version")
if (( ci_compiler )); then
  env_args+=(BUN_COMPILE_RELEASE="bun-v$required_bun")
  note "compiler will be downloaded from bun-v$required_bun (CI parity)"
fi

note "building channel=$channel version=$version"
note "packages/cli/script/build.ts ${flags[*]}"
(cd packages/cli && env "${env_args[@]}" "$BUN" run script/build.ts "${flags[@]}")

if (( lockfile_guard )) && (( lockfile_dirty_before == 0 )); then
  if ! git diff --quiet -- bun.lock packages/cli/package.json; then
    note "restoring bun.lock and packages/cli/package.json (build's internal bun install rewrote them)"
    git checkout -- bun.lock packages/cli/package.json
  fi
fi

# --- verify ------------------------------------------------------------------

case "$host_platform" in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) os="$(printf '%s' "$host_platform" | tr '[:upper:]' '[:lower:]')" ;;
esac
case "$host_arch" in
  x86_64|amd64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) arch="$host_arch" ;;
esac

out="${outdir:-$ROOT/packages/cli/dist}"
binary="$(ls -1 "$out"/cli-"$os"-"$arch"*/bin/opencode "$out"/cli-"$os"-"$arch"*/bin/opencode.exe 2>/dev/null | head -n1 || true)"
[[ -n "$binary" ]] || die "no artifact found under $out; run with --all and inspect the directory"

note "artifact: $binary ($(du -h "$binary" | cut -f1))"
printf 'version: %s\n' "$("$binary" --version)"

leaks="$(env | grep -E '^(OPENCODE_CONFIG_DIR|OPENCODE_DB|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|XDG_STATE_HOME|TMPDIR)=' || true)"
if [[ -n "$leaks" ]]; then
  printf 'warning: these variables are set and change what the artifact will use at runtime:\n%s\n' "$leaks" >&2
fi

# --- smoke -------------------------------------------------------------------

if (( smoke )); then
  busy=0
  owner=""
  if command -v ss >/dev/null 2>&1; then
    if ss -ltnH "sport = :$DEFAULT_SERVICE_PORT" 2>/dev/null | grep -q .; then
      busy=1
    fi
  elif command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$DEFAULT_SERVICE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      busy=1
    fi
  fi
  if (( busy )); then
    if command -v ss >/dev/null 2>&1; then
      owner="$(ss -ltnpH "sport = :$DEFAULT_SERVICE_PORT" 2>/dev/null | head -n1)"
    elif command -v lsof >/dev/null 2>&1; then
      owner="$(lsof -nP -iTCP:"$DEFAULT_SERVICE_PORT" -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n1)"
    fi
    printf 'warning: port %s is in use; skipping service smoke test\n' "$DEFAULT_SERVICE_PORT" >&2
    [[ -n "$owner" ]] && printf '         %s\n' "$owner" >&2
    printf '         free the port (or stop the stray service) and rerun with --smoke\n' >&2
  else
    note "running service smoke test"
    (cd packages/cli && "$BUN" run script/service-smoke.ts)
  fi
fi

note "done"
cat <<EOF

Next steps:
  install:  install -m 755 "$binary" ~/.local/bin/opencode
  try it:   "$binary" --standalone
  inspect:  "$binary" debug paths

Channel=latest shares ~/.local/share/opencode/opencode.db, ~/.local/state/opencode/service.json
and the service port with any officially installed build. Running the binary only connects to the
existing service; \`opencode service restart\` would replace that service with this build.
EOF

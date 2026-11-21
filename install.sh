#!/bin/sh
# opencode-hop installer for macOS and Linux.
#
#   curl -fsSL https://github.com/TkgJamuKeliling/opencode-hop/releases/latest/download/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --tag v2.3.4
#
# The installer picks the asset for this machine, verifies it, installs it to
# ~/.local/bin/opencode-hop, updates PATH, and prepares the 9router marker when
# no stock opencode is visible. It never installs stock opencode.
set -eu
: "${HOME:?HOME is not set}"

REPO="TkgJamuKeliling/opencode-hop"
PROG="opencode-hop"
BIN_DIR="$HOME/.local/bin"
TARGET="$BIN_DIR/$PROG"
STATE="$HOME/.local/state/opencode/service-hop.json"
MARKER="$HOME/.config/opencode/opencode.json"

TAG=""
MODE="install"
TMP=""

OS=""
ARCH=""
PRETTY_OS=""
MACHINE=""
ASSET=""
WANT_FORMAT=""
PRETTY_FORMAT=""
ROSETTA=0
BASE=""
RELEASE=""
STOCK_FOUND=0
STOCK_STATUS=""
MARKER_STATUS=""
PATH_STATUS=""
PATH_RC=""
SERVICE_WAS_RUNNING=0
SERVICE_STATUS=""
CHECKSUM=""
FORMAT=""
VERSION_LINE=""
DOWNLOAD_STATUS=""
DOWNLOAD_OK=0
READ_ONLY=0

if [ -t 1 ]; then
  B=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m')
  YELLOW=$(printf '\033[33m')
  RESET=$(printf '\033[0m')
else
  B=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  RESET=""
fi

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "${YELLOW}warning:${RESET} $*" >&2; }
die() { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
opencode-hop installer

Usage:
  sh install.sh [options]

Options:
  --tag <tag>    Install a specific release (for example v2.3.4)
  --check        Report what would happen; no changes, no download
  --dry-run      Print the install plan; no changes, no download
  -h, --help     Show this help

Downloads from:
  https://github.com/$REPO/releases
EOF
}

row() { printf '%-9s %s\n' "$1" "$2"; }

display() (
  case "$1" in
    "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
)

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag)
        if [ $# -lt 2 ]; then die "--tag needs a value"; fi
        TAG=$2
        shift 2
        ;;
      --tag=*)
        TAG=${1#--tag=}
        [ -n "$TAG" ] || die "--tag needs a value"
        shift
        ;;
      --check)
        MODE=check
        shift
        ;;
      --dry-run)
        MODE=dry-run
        shift
        ;;
      -h|--help)
        MODE=help
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        die "unknown argument: $1 (try --help)"
        ;;
    esac
  done
  if [ $# -gt 0 ]; then
    die "unexpected argument: $1"
  fi
  if [ -n "$TAG" ]; then
    case "$TAG" in
      -*|*[!A-Za-z0-9._-]*) die "invalid tag: $TAG" ;;
    esac
    case "$TAG" in
      [0-9]*) TAG="v$TAG" ;;
    esac
  fi
}

detect_platform() {
  local os arch translated musl
  os=$(uname -s 2>/dev/null || true)
  arch=$(uname -m 2>/dev/null || true)
  case "$os" in
    Darwin) OS=darwin; PRETTY_OS="macOS" ;;
    Linux) OS=linux; PRETTY_OS="Linux" ;;
    *) die "unsupported operating system: ${os:-unknown}. On Windows, run install.cmd." ;;
  esac
  case "$arch" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64) ARCH=x64 ;;
    *) die "unsupported CPU: ${arch:-unknown}" ;;
  esac

  ROSETTA=0
  if [ "$OS" = darwin ] && [ "$ARCH" = x64 ]; then
    translated=$(sysctl -n sysctl.proc_translated 2>/dev/null || true)
    if [ "$translated" = 1 ]; then
      ARCH=arm64
      ROSETTA=1
    fi
  fi

  if [ "$OS" = linux ]; then
    case "${PREFIX:-}" in
      *com.termux*) die "Termux uses Android's libc; the Linux build needs glibc." ;;
    esac
    musl=0
    if ldd --version 2>&1 | grep -qi musl; then musl=1; fi
    if ls /lib/ld-musl-* >/dev/null 2>&1; then musl=1; fi
    if [ "$musl" = 1 ]; then
      die "this is a musl system (Alpine). The release ships glibc builds only; there is no musl asset."
    fi
  fi

  ASSET="$PROG-$OS-$ARCH"
  MACHINE="$PRETTY_OS $ARCH"
  if [ "$OS" = darwin ] && [ "$ARCH" = arm64 ]; then
    MACHINE="$MACHINE (Apple Silicon)"
  fi
  if [ "$ROSETTA" = 1 ]; then
    MACHINE="$MACHINE, Rosetta"
  fi

  case "$OS-$ARCH" in
    darwin-arm64) WANT_FORMAT=macho-arm64; PRETTY_FORMAT="Mach-O arm64" ;;
    darwin-x64) WANT_FORMAT=macho-x64; PRETTY_FORMAT="Mach-O x86_64" ;;
    linux-x64) WANT_FORMAT=elf-x64; PRETTY_FORMAT="ELF x86_64" ;;
    linux-arm64) WANT_FORMAT=elf-arm64; PRETTY_FORMAT="ELF arm64" ;;
  esac
}

set_base() {
  if [ -n "$TAG" ]; then
    BASE="https://github.com/$REPO/releases/download/$TAG"
    RELEASE="$TAG"
  else
    BASE="https://github.com/$REPO/releases/latest/download"
    RELEASE="latest"
  fi
}

check_stock() {
  local path
  path=$(command -v opencode 2>/dev/null || true)
  case "$path" in
    /*)
      STOCK_FOUND=1
      STOCK_STATUS="found ($path)"
      ;;
    *)
      STOCK_FOUND=0
      STOCK_STATUS="not found"
      ;;
  esac
}

download() {
  local url dest
  url=$1
  dest=$2
  if have curl; then
    if [ -t 2 ]; then
      curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --progress-bar -o "$dest" "$url"
    else
      curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$dest" "$url"
    fi
    return $?
  fi
  if have wget; then
    wget -O "$dest" "$url"
    return $?
  fi
  die "curl or wget is required to download opencode-hop"
}

sha256() {
  local file out
  file=$1
  if have shasum; then
    out=$(shasum -a 256 "$file") || die "could not hash $file"
  elif have sha256sum; then
    out=$(sha256sum "$file") || die "could not hash $file"
  else
    die "shasum or sha256sum is required"
  fi
  printf '%s\n' "$out" | awk '{print $1}'
}

verify_checksum() {
  local file sums expected actual
  file=$1
  sums=$2
  expected=$(awk -v a="$ASSET" '$2 == a { print tolower($1); exit }' "$sums")
  if [ -z "$expected" ]; then
    die "SHA256SUMS has no entry for $ASSET"
  fi
  actual=$(sha256 "$file")
  actual=$(printf '%s' "$actual" | tr 'A-F' 'a-f')
  if [ "$actual" != "$expected" ]; then
    die "checksum mismatch for $ASSET.
  expected: $expected
  actual:   $actual
The download is incomplete or the release is broken. Try again."
  fi
  CHECKSUM="OK"
}

le16() {
  local off f vals
  off=$1
  f=$2
  vals=$(od -An -tu1 -j"$off" -N2 "$f" 2>/dev/null | tr -s ' ')
  set -- $vals
  if [ $# -ne 2 ]; then printf '0\n'; return 0; fi
  printf '%s\n' "$(( $1 + $2 * 256 ))"
}

le32() {
  local off f vals
  off=$1
  f=$2
  vals=$(od -An -tu1 -j"$off" -N4 "$f" 2>/dev/null | tr -s ' ')
  set -- $vals
  if [ $# -ne 4 ]; then printf '0\n'; return 0; fi
  printf '%s\n' "$(( $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 ))"
}

be32() {
  local off f vals
  off=$1
  f=$2
  vals=$(od -An -tu1 -j"$off" -N4 "$f" 2>/dev/null | tr -s ' ')
  set -- $vals
  if [ $# -ne 4 ]; then printf '0\n'; return 0; fi
  printf '%s\n' "$(( $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 ))"
}

detect_format() {
  local f size magic cpu n i arm x64 class machine peoff sig
  f=$1
  size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  size=${size:-0}
  if [ "$size" -lt 8 ]; then
    printf 'too-small\n'
    return 0
  fi
  magic=$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')
  case "$magic" in
    cffaedfe)
      cpu=$(le32 4 "$f")
      case "$cpu" in
        16777228) printf 'macho-arm64\n' ;;
        16777223) printf 'macho-x64\n' ;;
        *) printf 'macho-other\n' ;;
      esac
      ;;
    cafebabe)
      n=$(be32 4 "$f")
      if [ "$n" -le 0 ] || [ "$n" -gt 16 ]; then
        printf 'macho-fat-other\n'
        return 0
      fi
      arm=0
      x64=0
      i=0
      while [ "$i" -lt "$n" ]; do
        cpu=$(be32 $((8 + i * 20)) "$f")
        if [ "$cpu" = 16777228 ]; then arm=1; fi
        if [ "$cpu" = 16777223 ]; then x64=1; fi
        i=$((i + 1))
      done
      if [ "$arm" = 1 ] && [ "$x64" = 1 ]; then
        printf 'macho-fat-both\n'
      elif [ "$arm" = 1 ]; then
        printf 'macho-fat-arm64\n'
      elif [ "$x64" = 1 ]; then
        printf 'macho-fat-x64\n'
      else
        printf 'macho-fat-other\n'
      fi
      ;;
    7f454c46)
      class=$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')
      machine=$(le16 18 "$f")
      if [ "$class" != 2 ]; then
        printf 'elf-other\n'
      elif [ "$machine" = 62 ]; then
        printf 'elf-x64\n'
      elif [ "$machine" = 183 ]; then
        printf 'elf-arm64\n'
      else
        printf 'elf-other\n'
      fi
      ;;
    4d5a*)
      peoff=$(le32 60 "$f")
      if [ "$peoff" -le 0 ] || [ $((peoff + 24)) -gt "$size" ]; then
        printf 'pe-truncated\n'
        return 0
      fi
      sig=$(le32 "$peoff" "$f")
      if [ "$sig" != 17744 ]; then
        printf 'pe-other\n'
        return 0
      fi
      machine=$(le16 $((peoff + 4)) "$f")
      case "$machine" in
        34404) printf 'pe-x64\n' ;;
        43620) printf 'pe-arm64\n' ;;
        *) printf 'pe-other\n' ;;
      esac
      ;;
    3c21444f|3c68746d|3c48544d|3c3f786d) printf 'html\n' ;;
    504b0304|1f8b*|425a68*|fd377a58|377abcaf) printf 'archive\n' ;;
    "") printf 'empty\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

format_mismatch() {
  local file got
  file=$1
  got=$2
  die "the downloaded file does not match this machine.
  file:     $(basename "$file") ($got)
  machine:  $MACHINE
  expected: $ASSET ($PRETTY_FORMAT)
This release asset is mislabeled or corrupt; please report it."
}

check_format() {
  local file got
  file=$1
  got=$(detect_format "$file")
  case "$got" in
    "$WANT_FORMAT")
      FORMAT="$PRETTY_FORMAT"
      ;;
    macho-fat-both)
      case "$WANT_FORMAT" in
        macho-*) FORMAT="$PRETTY_FORMAT (universal)" ;;
        *) format_mismatch "$file" "$got" ;;
      esac
      ;;
    macho-fat-arm64)
      if [ "$WANT_FORMAT" = macho-arm64 ]; then
        FORMAT="$PRETTY_FORMAT (universal)"
      else
        format_mismatch "$file" "$got"
      fi
      ;;
    macho-fat-x64)
      if [ "$WANT_FORMAT" = macho-x64 ]; then
        FORMAT="$PRETTY_FORMAT (universal)"
      else
        format_mismatch "$file" "$got"
      fi
      ;;
    *)
      format_mismatch "$file" "$got"
      ;;
  esac
}

check_service() {
  SERVICE_WAS_RUNNING=0
  SERVICE_STATUS="not running"
  local out pid
  if [ -x "$TARGET" ]; then
    if out=$("$TARGET" service status 2>/dev/null); then
      out=$(printf '%s' "$out" | tr -d '\r')
      if [ -z "$out" ] || [ "$out" = stopped ]; then
        SERVICE_STATUS="not running"
      else
        SERVICE_WAS_RUNNING=1
        SERVICE_STATUS="running at $out"
      fi
      return 0
    fi
    SERVICE_STATUS="unknown (installed binary did not run)"
  fi
  if [ -f "$STATE" ]; then
    pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE" 2>/dev/null | head -n 1)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if [ "$READ_ONLY" = 1 ]; then
        SERVICE_STATUS="running (pid $pid; binary did not run)"
        return 0
      fi
      die "a service is still running (pid $pid), but the installed binary cannot be queried.
Stop it first, then run this installer again."
    fi
    SERVICE_STATUS="stale service state"
  fi
}

stop_service() {
  if [ "$SERVICE_WAS_RUNNING" != 1 ]; then
    return 0
  fi
  if ! "$TARGET" service stop >/dev/null 2>&1; then
    die "could not stop the running service.
Run '$TARGET service stop' and try again."
  fi
  local i s
  i=0
  while [ "$i" -lt 20 ]; do
    s=$("$TARGET" service status 2>/dev/null || true)
    s=$(printf '%s' "$s" | tr -d '\r')
    if [ -z "$s" ] || [ "$s" = stopped ]; then
      SERVICE_STATUS="stopped for upgrade"
      return 0
    fi
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  die "the service is still running at $s; stop it manually and try again."
}

start_service() {
  if [ "$SERVICE_WAS_RUNNING" != 1 ]; then
    return 0
  fi
  local i out
  i=0
  while [ "$i" -lt 10 ]; do
    if out=$("$TARGET" service start 2>/dev/null); then
      out=$(printf '%s' "$out" | tr -d '\r')
      SERVICE_STATUS="restarted at $out"
      return 0
    fi
    sleep 0.3 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  SERVICE_STATUS="stopped (start failed)"
  warn "could not restart the service; run: $TARGET service start"
}

install_binary() {
  local file backup had_old version code
  file=$1
  backup="$BIN_DIR/.$PROG.previous"
  had_old=0
  if ! mkdir -p "$BIN_DIR" 2>/dev/null; then
    die "could not create $BIN_DIR"
  fi
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    rm -f "$backup" 2>/dev/null || true
    if ! mv "$TARGET" "$backup"; then
      die "could not move the old binary out of the way: $TARGET"
    fi
    had_old=1
  elif [ -e "$backup" ]; then
    had_old=1
  fi
  if ! cp "$file" "$TARGET"; then
    if [ "$had_old" = 1 ]; then mv "$backup" "$TARGET" 2>/dev/null || true; fi
    die "could not write $TARGET"
  fi
  chmod 755 "$TARGET" 2>/dev/null || true
  if [ "$OS" = darwin ]; then
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
  fi
  if version=$("$TARGET" --version 2>&1); then
    version=$(printf '%s\n' "$version" | sed -n '1p')
    if [ -z "$version" ]; then
      rm -f "$TARGET"
      if [ "$had_old" = 1 ]; then
        mv "$backup" "$TARGET" 2>/dev/null || true
        chmod 755 "$TARGET" 2>/dev/null || true
        if [ "$SERVICE_WAS_RUNNING" = 1 ]; then
          "$TARGET" service start >/dev/null 2>&1 || true
        fi
      fi
      die "the new binary ran but printed no version. Rolled back."
    fi
    VERSION_LINE="$version"
  else
    code=$?
    rm -f "$TARGET"
    if [ "$had_old" = 1 ]; then
      mv "$backup" "$TARGET" 2>/dev/null || true
      chmod 755 "$TARGET" 2>/dev/null || true
      if [ "$SERVICE_WAS_RUNNING" = 1 ]; then
        "$TARGET" service start >/dev/null 2>&1 || true
      fi
    fi
    if [ -z "$version" ]; then version="(no output)"; fi
    die "the new binary did not run (exit $code):
$version
Rolled back to the previous binary."
  fi
  rm -f "$backup" 2>/dev/null || true
}

path_contains() (
  case ":$PATH:" in
    *":$BIN_DIR:"*) return 0 ;;
    *) return 1 ;;
  esac
)

rc_target() (
  local shell_name
  shell_name=$(basename "${SHELL:-sh}")
  case "$shell_name" in
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    bash)
      if [ "$OS" = darwin ] && [ -f "$HOME/.bash_profile" ]; then
        printf '%s\n' "$HOME/.bash_profile"
      elif [ -f "$HOME/.bashrc" ]; then
        printf '%s\n' "$HOME/.bashrc"
      else
        printf '%s\n' "$HOME/.bash_profile"
      fi
      ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    *) printf '%s\n' "$HOME/.profile" ;;
  esac
)

add_path() {
  PATH_RC=""
  if path_contains; then
    PATH_STATUS="already on PATH"
    return 0
  fi
  local shell_name rc line
  shell_name=$(basename "${SHELL:-sh}")
  if [ "$shell_name" = fish ] && have fish; then
    if fish -c 'fish_add_path "$HOME/.local/bin"' >/dev/null 2>&1; then
      PATH_STATUS="added with fish_add_path"
      PATH="$BIN_DIR:$PATH"
      return 0
    fi
  fi
  rc=$(rc_target)
  PATH_RC="$rc"
  if [ -f "$rc" ] && grep -Fq '.local/bin' "$rc" 2>/dev/null; then
    PATH_STATUS="already in $(display "$rc")"
    PATH="$BIN_DIR:$PATH"
    return 0
  fi
  case "$shell_name" in
    fish) line='fish_add_path "$HOME/.local/bin"' ;;
    *) line='export PATH="$HOME/.local/bin:$PATH"' ;;
  esac
  if ! mkdir -p "$(dirname "$rc")" 2>/dev/null; then
    PATH_STATUS="could not create $(dirname "$rc")"
    warn "could not create $(dirname "$rc"); add $BIN_DIR to PATH manually"
    return 0
  fi
  if [ -s "$rc" ]; then
    if [ "$(tail -c 1 "$rc" | wc -l | tr -d ' ')" = 0 ]; then
      printf '\n' >> "$rc" || { PATH_STATUS="could not write $(display "$rc")"; return 0; }
    fi
  fi
  if printf '%s\n' "$line" >> "$rc" 2>/dev/null; then
    PATH_STATUS="added to $(display "$rc")"
    PATH="$BIN_DIR:$PATH"
  else
    PATH_STATUS="could not write $(display "$rc")"
    warn "could not write $rc; add $BIN_DIR to PATH manually"
  fi
}

path_plan() {
  if path_contains; then
    PATH_STATUS="already on PATH"
    return 0
  fi
  local shell_name rc
  shell_name=$(basename "${SHELL:-sh}")
  if [ "$shell_name" = fish ] && have fish; then
    PATH_STATUS="would add with fish_add_path"
    return 0
  fi
  rc=$(rc_target)
  if [ -f "$rc" ] && grep -Fq '.local/bin' "$rc" 2>/dev/null; then
    PATH_STATUS="already in $(display "$rc")"
  else
    PATH_STATUS="would add to $(display "$rc")"
  fi
}

prepare_marker() {
  if [ "$STOCK_FOUND" = 1 ]; then
    MARKER_STATUS="stock opencode found; not needed"
    return 0
  fi
  if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
    MARKER_STATUS="already exists"
    return 0
  fi
  local dir
  dir=$(dirname "$MARKER")
  if ! mkdir -p "$dir" 2>/dev/null; then
    MARKER_STATUS="could not create $(display "$dir")"
    warn "could not create $dir; 9router will not see this build until you create $MARKER"
    return 0
  fi
  if printf '{}' > "$MARKER" 2>/dev/null; then
    MARKER_STATUS="created $(display "$MARKER")"
  else
    MARKER_STATUS="could not write $(display "$MARKER")"
    warn "could not write $MARKER"
  fi
}

marker_plan() {
  if [ "$STOCK_FOUND" = 1 ]; then
    MARKER_STATUS="stock opencode found; not needed"
  elif [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
    MARKER_STATUS="already exists"
  else
    MARKER_STATUS="would create $(display "$MARKER")"
  fi
}

check_download() {
  DOWNLOAD_OK=0
  local code
  if have curl; then
    code=$(curl -sIL -o /dev/null -w '%{http_code}' "$BASE/$ASSET" 2>/dev/null || true)
    case "$code" in
      200) DOWNLOAD_OK=1; DOWNLOAD_STATUS="available (200)" ;;
      000|"") DOWNLOAD_STATUS="unreachable" ;;
      *) DOWNLOAD_STATUS="not available (HTTP $code)" ;;
    esac
  elif have wget; then
    if wget --spider -q "$BASE/$ASSET" >/dev/null 2>&1; then
      DOWNLOAD_OK=1
      DOWNLOAD_STATUS="available"
    else
      DOWNLOAD_STATUS="not available"
    fi
  else
    DOWNLOAD_STATUS="unknown (curl or wget required)"
  fi
}

print_summary() {
  printf '\n'
  printf '%sopencode-hop installer%s\n' "$B" "$RESET"
  printf '\n'
  row "Machine" "$MACHINE"
  row "Asset" "$ASSET"
  row "Release" "$RELEASE"
  if [ -n "$CHECKSUM" ]; then row "Checksum" "$CHECKSUM"; fi
  if [ -n "$FORMAT" ]; then row "Format" "$FORMAT"; fi
  if [ -n "$DOWNLOAD_STATUS" ]; then row "Download" "$DOWNLOAD_STATUS"; fi
  row "Stock" "$STOCK_STATUS"
  row "9router" "$MARKER_STATUS"
  row "Install" "$(display "$TARGET")"
  row "PATH" "$PATH_STATUS"
  row "Service" "$SERVICE_STATUS"
  if [ -n "$VERSION_LINE" ]; then row "Version" "$VERSION_LINE"; fi
  printf '\n'
}

print_done() {
  case "$PATH_STATUS" in
    added*|already\ in*)
      if [ -n "$PATH_RC" ]; then
        printf 'Done. Open a new terminal or run: . %s\n' "$(display "$PATH_RC")"
      else
        printf 'Done. Open a new terminal.\n'
      fi
      ;;
    *) printf 'Done.\n' ;;
  esac
  if [ "$STOCK_FOUND" = 0 ] && { [ -e "$MARKER" ] || [ -L "$MARKER" ]; }; then
    printf 'For 9router: refresh the dashboard, then CLI Tools -> OpenCode.\n'
  fi
}

cleanup() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

main() {
  parse_args "$@"
  if [ "$MODE" = help ]; then
    usage
    exit 0
  fi
  detect_platform
  set_base
  check_stock

  if [ "$MODE" = check ] || [ "$MODE" = dry-run ]; then
    READ_ONLY=1
    check_service
    marker_plan
    path_plan
    if [ "$MODE" = check ]; then
      check_download
    else
      DOWNLOAD_STATUS="would download $BASE/$ASSET"
    fi
    print_summary
    printf 'No changes made.\n'
    if [ "$MODE" = check ] && [ "$DOWNLOAD_OK" != 1 ]; then
      exit 1
    fi
    exit 0
  fi

  TMP=$(mktemp -d "${TMPDIR:-/tmp}/opencode-hop.XXXXXX") || die "could not create a temporary directory"
  local file
  file="$TMP/$ASSET"

  printf 'Downloading %s (%s)...\n' "$ASSET" "$RELEASE"
  if ! download "$BASE/$ASSET" "$file"; then
    die "could not download $ASSET.
Manual download: https://github.com/$REPO/releases/latest
Asset: $ASSET"
  fi
  if ! download "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"; then
    die "could not download SHA256SUMS.
Manual download: https://github.com/$REPO/releases/latest"
  fi

  verify_checksum "$file" "$TMP/SHA256SUMS"
  check_format "$file"
  check_service
  stop_service
  install_binary "$file"
  start_service
  add_path
  prepare_marker

  print_summary
  print_done
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

main "$@"

#!/usr/bin/env bash
#
# migrate.sh - move Claude Code state, claude-mem memory, and the /data2
# working tree from this machine to a replacement host.
#
# Every phase is idempotent: rsync only ships changed blocks, so re-running
# after more work lands on the old machine is cheap and safe. Nothing is
# deleted on either side.
#
#   ./migrate.sh --dry-run all      # rehearse everything, transfer nothing
#   ./migrate.sh preflight          # check connectivity, tools, disk space
#   ./migrate.sh claude mem         # Claude Code config + memory database
#   ./migrate.sh code               # /data2 minus build output and media
#   ./migrate.sh --with-secrets secrets
#   ./migrate.sh verify             # compare both sides, integrity-check DBs
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=migrate.conf
. "${MIGRATE_CONF:-$HERE/migrate.conf}"

DRY_RUN=0
WITH_SECRETS=0
NO_STOP=0
declare -a PHASES=()

readonly ALL_PHASES=(preflight claude mem code dotfiles verify)

# --- output helpers ---
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  printf 'Phases: %s  (or "all")\n' "${ALL_PHASES[*]}"
  printf 'Flags:  --dry-run  --with-secrets  --no-stop  --help\n'
  exit "${1:-0}"
}

# --- argument parsing ---
while (($#)); do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --with-secrets) WITH_SECRETS=1 ;;
    --no-stop)      NO_STOP=1 ;;
    -h|--help)      usage 0 ;;
    all)            PHASES+=("${ALL_PHASES[@]}") ;;
    secrets)        PHASES+=(secrets) ;;
    preflight|claude|mem|code|dotfiles|verify) PHASES+=("$1") ;;
    *)              printf 'unknown argument: %s\n\n' "$1" >&2; usage 2 ;;
  esac
  shift
done
((${#PHASES[@]})) || usage 0

readonly TARGET="${TARGET_USER}@${TARGET_HOST}"

# --- transfer primitives ---
# -a preserves perms/times/symlinks; --partial resumes an interrupted file
# rather than restarting it, which matters on a 40G+ transfer.
rsync_base=(rsync -a --human-readable --partial --info=stats1,progress2)
((DRY_RUN)) && rsync_base+=(--dry-run)

# push <source> <destination-relative-to-target-home-or-absolute> [extra rsync args...]
#
# rsync exits 23/24 when it could not transfer absolutely everything. Two
# causes are benign for this migration and must not abort it:
#
#   * The transfer root (/data2) is root-owned on both machines, so stuart
#     cannot set its mtime. Everything inside it still syncs, and
#     subdirectory times are preserved because those are stuart-owned.
#   * A file vanished mid-run, which is normal in a live working tree.
#
# Anything else is a genuine failure and still stops the migration.
push() {
  local src="$1" dst="$2"; shift 2
  local tmp rc=0 real

  tmp=$(mktemp)
  set +e
  "${rsync_base[@]}" "$@" "$src" "${TARGET}:${dst}" 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  set -e

  if ((rc != 0 && rc != 23 && rc != 24)); then
    rm -f "$tmp"
    die "rsync failed (exit $rc) syncing $src"
  fi

  if ((rc == 23 || rc == 24)); then
    # The whitelist is anchored to "/." - the notation rsync uses only for the
    # transfer root - so the same failure on a real subdirectory still reports.
    real=$(grep '^rsync:' "$tmp" \
      | grep -vE 'failed to set (times|permissions) on "[^"]*/\.": Operation not permitted' \
      | grep -v 'file has vanished:' || true)
    if [[ -n $real ]]; then
      rm -f "$tmp"
      printf '%s\n' "$real" >&2
      die "rsync reported errors that are not benign (exit $rc) syncing $src"
    fi
    warn "exit $rc: could not stamp the destination root's own mtime (root-owned on both ends)."
    warn "file contents and subdirectory times transferred correctly; continuing."
  fi

  rm -f "$tmp"
}

remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$@"; }

# Make a remote directory without tripping over dry-run mode.
remote_mkdir() {
  if ((DRY_RUN)); then info "would mkdir -p $* on $TARGET_HOST"; return 0; fi
  remote "mkdir -p $*"
}

# --- service control ---
# The claude-mem worker and its Chroma child hold SQLite files open. Stopping
# them yields a clean snapshot; both are respawned by the plugin the next time
# a Claude Code session starts, so there is nothing to restart by hand.
stop_services() {
  ((NO_STOP)) && { warn "--no-stop given; snapshotting live databases"; return 0; }
  local pidfile="$SRC_HOME/.claude-mem/worker.pid" pid
  if [[ -f $pidfile ]] && pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$pidfile") && [[ -n ${pid:-} ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      info "stopping claude-mem worker (pid $pid)"
      ((DRY_RUN)) || { kill "$pid" 2>/dev/null || true; }
    fi
  fi
  if ((DRY_RUN == 0)); then
    pkill -f 'chroma-mcp --client-type persistent' 2>/dev/null || true
    pkill -f 'claude-mem/.*worker-service' 2>/dev/null || true
    # Give SQLite a moment to release its locks and checkpoint the WAL.
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f 'claude-mem/.*worker-service' >/dev/null 2>&1 || break
      sleep 1
    done
  fi
  ok "claude-mem services stopped (they respawn on the next Claude session)"
}

# snapshot_db <source.db> <destination.db>
# `.backup` takes a read lock and writes a single consistent file with the
# WAL already applied - a plain cp of a live WAL database can be unreadable.
snapshot_db() {
  local src="$1" dst="$2"
  [[ -f $src ]] || { warn "no such database: $src"; return 0; }
  mkdir -p "$(dirname "$dst")"
  if ((DRY_RUN)); then info "would snapshot $(basename "$src")"; return 0; fi
  sqlite3 "file:$src?mode=ro" ".backup '$dst'"
  sqlite3 "$dst" 'PRAGMA integrity_check;' | grep -qx ok \
    || die "snapshot of $src failed its integrity check"
  ok "$(basename "$src") -> $(du -h "$dst" | cut -f1) (integrity ok)"
}

# ======
# Phases
# ======

phase_preflight() {
  log "Preflight"

  local t
  for t in rsync sqlite3 ssh python3; do
    command -v "$t" >/dev/null || die "missing locally: $t"
  done
  ok "local tools present"

  remote true 2>/dev/null \
    || die "cannot ssh to $TARGET without a password.
    Authorise this machine's key first, then re-run:
        ssh-copy-id -i $SRC_HOME/.ssh/id_ed25519.pub $TARGET"
  ok "ssh to $TARGET works without a password"

  info "remote: $(remote 'echo "$(hostname) / $(uname -sr)"')"

  local missing
  missing=$(remote 'for t in rsync sqlite3 git; do command -v $t >/dev/null || echo $t; done')
  [[ -z $missing ]] || warn "missing on $TARGET_HOST: $(tr '\n' ' ' <<<"$missing")"

  # Size the payload from rsync itself rather than guessing.
  log "Measuring payload"
  local need_kb=0 avail_kb size
  size=$(rsync -a --dry-run --stats \
           --exclude-from="$HERE/excludes-code.txt" \
           "$SRC_WORK/" "$TARGET:$DST_WORK/" 2>/dev/null \
         | sed -n 's/^Total transferred file size: \([0-9,]*\).*/\1/p' | tr -d ,)
  info "code payload to transfer: $(numfmt --to=iec --suffix=B "${size:-0}")"
  need_kb=$(( ${size:-0} / 1024 ))

  avail_kb=$(remote "df -Pk $DST_WORK 2>/dev/null | awk 'NR==2{print \$4}'") || avail_kb=0
  if [[ -z ${avail_kb:-} || $avail_kb -eq 0 ]]; then
    warn "$DST_WORK does not exist on $TARGET_HOST yet - create it and re-run preflight"
  else
    info "space free at $DST_WORK on $TARGET_HOST: $(numfmt --to=iec --suffix=B $((avail_kb*1024)))"
    (( avail_kb > need_kb )) || die "not enough free space at $DST_WORK on $TARGET_HOST"
    ok "destination has room"
  fi
}

phase_claude() {
  log "Claude Code configuration, projects and skills"
  remote_mkdir "$TARGET_HOME/.claude"

  push "$SRC_HOME/.claude/" "$TARGET_HOME/.claude/" \
    --exclude-from="$HERE/excludes-claude.txt"
  ok "~/.claude synced (plugin caches skipped; they reinstall on first launch)"

  # ~/.claude.json carries account state AND a machine identity. Ship the
  # state, drop the identity so the replacement registers as itself.
  log "Sanitising ~/.claude.json"
  mkdir -p "$STAGE"
  local drop=("${SANITIZE_KEYS[@]}")
  if ((WITH_SECRETS)); then
    warn "--with-secrets: the API key in ~/.claude.json will be transferred"
  else
    drop+=("${SANITIZE_SECRET_KEYS[@]}")
  fi

  DROP_KEYS="${drop[*]}" python3 - "$SRC_HOME/.claude.json" "$STAGE/.claude.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    data = json.load(fh)
removed = [k for k in os.environ["DROP_KEYS"].split() if data.pop(k, None) is not None]
with open(dst, "w") as fh:
    json.dump(data, fh, indent=2)
os.chmod(dst, 0o600)
print("    stripped: " + ", ".join(removed) if removed else "    nothing to strip")
print(f"    kept {len(data)} keys, including {len(data.get('projects', {}))} project histories")
PY

  push "$STAGE/.claude.json" "$TARGET_HOME/.claude.json"
  # The per-install marker holds a second machineID; let the new host write
  # its own rather than inheriting this one.
  ((DRY_RUN)) || remote "rm -f $TARGET_HOME/.claude/.claude.json"
  ok "~/.claude.json transferred without this machine's identity"
}

phase_mem() {
  log "claude-mem memory database"
  stop_services

  local stage="$STAGE/.claude-mem"
  mkdir -p "$stage/chroma" "$stage/vector-db"

  snapshot_db "$SRC_HOME/.claude-mem/claude-mem.db"        "$stage/claude-mem.db"
  snapshot_db "$SRC_HOME/.claude-mem/chroma/chroma.sqlite3" "$stage/chroma/chroma.sqlite3"
  snapshot_db "$SRC_HOME/.claude-mem/vector-db/chroma.sqlite3" "$stage/vector-db/chroma.sqlite3"

  remote_mkdir "$TARGET_HOME/.claude-mem"

  # Settings, embeddings segments and state, minus the live DB files.
  push "$SRC_HOME/.claude-mem/" "$TARGET_HOME/.claude-mem/" \
    --exclude-from="$HERE/excludes-mem.txt"
  # Then the consistent snapshots on top.
  push "$stage/" "$TARGET_HOME/.claude-mem/"
  ok "memory database and vector store transferred"

  # CLAUDE_MEM_DATA_DIR is an absolute path; correct it if homes differ.
  if [[ $SRC_HOME != "$TARGET_HOME" ]] && ((DRY_RUN == 0)); then
    remote "sed -i 's#$SRC_HOME/.claude-mem#$TARGET_HOME/.claude-mem#g' \
              $TARGET_HOME/.claude-mem/settings.json"
    ok "rewrote CLAUDE_MEM_DATA_DIR for $TARGET_HOME"
  fi
}

phase_code() {
  log "Working tree: $SRC_WORK -> $TARGET_HOST:$DST_WORK"
  remote_mkdir "$DST_WORK"
  push "$SRC_WORK/" "$DST_WORK/" --exclude-from="$HERE/excludes-code.txt"
  ok "working tree synced (build artifacts and media trees excluded)"
}

phase_dotfiles() {
  log "Dotfiles"
  local f
  for f in "${DOTFILES[@]}"; do
    [[ -e "$SRC_HOME/$f" ]] || { warn "skipping absent $f"; continue; }
    remote_mkdir "$TARGET_HOME/$(dirname "$f")"
    push "$SRC_HOME/$f" "$TARGET_HOME/$f"
    info "$f"
  done
  ok "dotfiles synced"
}

phase_secrets() {
  log "Secret material"
  ((WITH_SECRETS)) || die "the secrets phase needs --with-secrets stated explicitly.
    It would copy private SSH keys, git and gh credentials, and AWS keys to
    $TARGET_HOST. Re-run as:  ./migrate.sh --with-secrets secrets"

  local f
  for f in "${SECRET_FILES[@]}"; do
    [[ -e "$SRC_HOME/$f" ]] || continue
    remote_mkdir "$TARGET_HOME/$(dirname "$f")"
    push "$SRC_HOME/$f" "$TARGET_HOME/$f" --chmod=F600
    info "$f"
  done
  ((DRY_RUN)) || remote "chmod 700 $TARGET_HOME/.ssh 2>/dev/null; \
                         chmod 600 $TARGET_HOME/.ssh/* 2>/dev/null; true"
  ok "secrets transferred with 0600 permissions"
}

phase_verify() {
  log "Verification"

  # Counting files on each side and comparing the totals is misleading here,
  # because whole subtrees are excluded by design. The honest question is
  # "would another sync still have work to do?", so ask rsync exactly that:
  # a dry run with --itemize-changes lists only items that differ.
  # Lines are prefixed <,>,c,h for transfers/creations; a bare "." prefix is
  # an attribute-only note (such as the root mtime we cannot set) and is
  # deliberately not counted.
  check_sync() {
    local label="$1" src="$2" dst="$3"; shift 3
    local pending
    pending=$(rsync -a --dry-run --itemize-changes "$@" \
                "$src" "${TARGET}:${dst}" 2>/dev/null \
              | grep -cE '^[<>ch]' || true)
    if ((pending == 0)); then
      ok "$label: in sync"
    else
      warn "$label: $pending item(s) still pending - re-run that phase"
    fi
  }

  check_sync "~/.claude"     "$SRC_HOME/.claude/"     "$TARGET_HOME/.claude/" \
    --exclude-from="$HERE/excludes-claude.txt"
  check_sync "~/.claude-mem" "$SRC_HOME/.claude-mem/" "$TARGET_HOME/.claude-mem/" \
    --exclude-from="$HERE/excludes-mem.txt"
  check_sync "$DST_WORK"     "$SRC_WORK/"             "$DST_WORK/" \
    --exclude-from="$HERE/excludes-code.txt"

  local f
  for f in "${DOTFILES[@]}"; do
    [[ -e "$SRC_HOME/$f" ]] && check_sync "$f" "$SRC_HOME/$f" "$TARGET_HOME/$f"
  done

  log "Remote database integrity"
  local db
  for db in .claude-mem/claude-mem.db .claude-mem/chroma/chroma.sqlite3; do
    if remote "test -f $TARGET_HOME/$db"; then
      printf '    %-38s %s\n' "$db" \
        "$(remote "sqlite3 $TARGET_HOME/$db 'PRAGMA integrity_check;' 2>&1 | head -1")"
    else
      warn "missing on remote: $db"
    fi
  done

  log "Memory carried across"
  local lo ro
  lo=$(sqlite3 "file:$SRC_HOME/.claude-mem/claude-mem.db?mode=ro" \
        'select count(*) from observations;' 2>/dev/null) || lo="?"
  ro=$(remote "sqlite3 $TARGET_HOME/.claude-mem/claude-mem.db \
        'select count(*) from observations;' 2>/dev/null") || ro="?"
  printf '    observations   local %-8s remote %-8s %s\n' "$lo" "$ro" \
    "$([[ $lo == "$ro" ]] && echo match || echo MISMATCH)"

  log "Identity hygiene"
  if remote "grep -q machineID $TARGET_HOME/.claude.json 2>/dev/null"; then
    warn "machineID present on remote - it should have been stripped"
  else
    ok "no machineID on remote (it will generate its own)"
  fi
  if remote "test -f $TARGET_HOME/.claude/.claude.json"; then
    warn "$TARGET_HOME/.claude/.claude.json exists - holds a second machine identity"
  else
    ok "no inherited per-install identity marker"
  fi

  log "Finish on $TARGET_HOST"
  cat <<'NEXT'
    1. Install Claude Code:  curl -fsSL https://claude.ai/install.sh | bash
    2. Start it once and run /login to authenticate this machine.
    3. Plugins reinstall from the transferred manifests on first launch;
       confirm with /plugin  (expect claude-mem, gopls-lsp,
       rust-analyzer-lsp, mattpocock-skills).
    4. Rebuild artifacts where needed: cargo build / npm install / uv sync.
NEXT
}

# ===========================================================================
((DRY_RUN)) && log "DRY RUN - nothing will be written to $TARGET_HOST"
for p in "${PHASES[@]}"; do "phase_$p"; done
log "Done: ${PHASES[*]}"

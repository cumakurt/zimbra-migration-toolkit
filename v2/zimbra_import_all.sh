#!/usr/bin/env bash
#
# Zimbra full configuration import from backup tree (resumable, with safety prompts)
# Run as root on the target Zimbra server. Requires sudo -u zimbra.
#
# This script MODIFIES Zimbra LDAP: domains, accounts, global admins, distribution lists,
# aliases, signatures, and Sieve filters.
# Large deployments: run in a maintenance window; LDAP write load is significant.
#
# Backup layout (same as zimbra_export_all.sh output):
#   domains.txt, emails.txt, admins.txt (gaaa), distributinlist.txt, userpass/*.shadow, userdata/*.txt,
#   distributinlist_members/*.txt, alias/*.txt, signatures/*.signature + *.name, filter/*.filter
#
# If upgrading from an older 8-stage import build, run --reset-state once so stage markers match.
#
# Parallel zmprov (default IMPORT_PARALLEL=10) and per-stage checkpoints under STATE_DIR let you resume
# mid-stage after a crash: re-run the script; it skips lines already recorded in checkpoint_NN.txt.
#
set -euo pipefail

ZIMBRA_STDERR_WAS_TTY=0
[[ -t 2 ]] && ZIMBRA_STDERR_WAS_TTY=1
export ZIMBRA_STDERR_WAS_TTY

readonly ZIMBRA_IMPORT_INLINE="${ZIMBRA_IMPORT_INLINE:-${ZIMBRA_EXPORT_INLINE:-1}}"
if [[ -z "${ZIMBRA_IMPORT_NO_LINEBUF:-${ZIMBRA_EXPORT_NO_LINEBUF:-}}" ]] && command -v stdbuf >/dev/null 2>&1; then
  if [[ "${ZIMBRA_IMPORT_INLINE}" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY}" == "1" ]]; then
    exec 2> >(stdbuf -o0 cat >&2)
  else
    exec 2> >(stdbuf -oL cat >&2)
  fi
fi

readonly SCRIPT_NAME="${0##*/}"
readonly BACKUP_ROOT="${ZIMBRA_IMPORT_DIR:-${ZIMBRA_EXPORT_DIR:-/backups/zmigrate}}"
readonly STATE_DIR="${BACKUP_ROOT}/.import_state"

readonly STAGE_PREPARE=1
readonly STAGE_DOMAINS=2
readonly STAGE_ACCOUNTS=3
readonly STAGE_ADMINS=4
readonly STAGE_DISTRIBUTION=5
readonly STAGE_DISTRIBUTION_MEMBERS=6
readonly STAGE_ALIASES=7
readonly STAGE_SIGNATURES=8
readonly STAGE_FILTERS=9
readonly LAST_STAGE="${STAGE_FILTERS}"

readonly IMPORT_PROGRESS_INTERVAL="${IMPORT_PROGRESS_INTERVAL:-50}"
readonly IMPORT_EACH_ITEM="${IMPORT_EACH_ITEM:-1}"
readonly IMPORT_TMP_PASS="${IMPORT_TMP_PASS:-CHANGEme}"
# Default concurrent zmprov workers per heavy stage (override per stage with IMPORT_*_PARALLEL)
readonly IMPORT_PARALLEL="${IMPORT_PARALLEL:-10}"
readonly IMPORT_PARALLEL_PROGRESS_INTERVAL="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

use_color() {
  [[ -z "${NO_COLOR:-}" ]] && [[ -z "${ZIMBRA_IMPORT_NO_COLOR:-${ZIMBRA_EXPORT_NO_COLOR:-}}" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]]
}

stage_color_begin() {
  local id="$1"
  use_color || return 0
  case "$id" in
    1) printf '\033[1;95m' ;;
    2) printf '\033[1;94m' ;;
    3) printf '\033[1;93m' ;;
    4) printf '\033[1;92m' ;;
    5) printf '\033[1;96m' ;;
    6) printf '\033[1;91m' ;;
    7) printf '\033[0;35m' ;;
    8) printf '\033[0;34m' ;;
    9) printf '\033[0;33m' ;;
    *) printf '\033[0m' ;;
  esac
}

color_reset() {
  use_color && printf '\033[0m' >&2 || true
}

log() {
  printf '%s\n' "$*" >&2
}

log_err() {
  if use_color; then
    printf '\033[1;31m%s\033[0m\n' "$*" >&2
  else
    printf '%s\n' "$*" >&2
  fi
}

log_stage_line() {
  local id="$1" title="$2" detail="$3"
  stage_color_begin "$id"
  printf '[IMPORT %s] %s — %s' "$id" "$title" "$detail" >&2
  color_reset
  printf '\n' >&2
}

log_stage_note() {
  local id="$1" msg="$2"
  stage_color_begin "$id"
  printf '  %s' "$msg" >&2
  color_reset
  printf '\n' >&2
}

log_stage_status() {
  local id="$1"
  shift
  stage_color_begin "$id"
  printf '%s' "$*" >&2
  color_reset
  printf '\n' >&2
}

log_stage_done_line() {
  local id="$1" last="$2" dur="$3" name="$4"
  stage_color_begin "$id"
  printf '[IMPORT %s/%s] ✓ %s — %s ·' "$id" "$last" "$dur" "$name" >&2
  color_reset
  printf '\n' >&2
}

fmt_duration() {
  local s="$1"
  if ((s < 60)); then
    echo "${s}s"
  elif ((s < 3600)); then
    echo "$((s / 60))m $((s % 60))s"
  else
    echo "$((s / 3600))h $(((s % 3600) / 60))m"
  fi
}

count_nonempty_lines() {
  local f="$1" n
  [[ -r "$f" ]] || { echo 0; return 0; }
  n=$(grep -cve '^[[:space:]]*$' "$f" 2>/dev/null) || n=0
  echo "$n"
}

die() {
  log_err "ERROR: $*"
  exit 1
}

on_err() {
  local ec=$?
  log_err "Script aborted — exit ${ec} — line ${BASH_LINENO[0]:-?}."
  exit "$ec"
}
trap on_err ERR

on_int() {
  log_err "Interrupted — SIGINT — import may be incomplete; re-run to resume from the last incomplete stage."
  exit 130
}
trap on_int INT

# -----------------------------------------------------------------------------
# State / resume
# -----------------------------------------------------------------------------

marker_path() {
  printf '%s/stage_%02d.done' "$STATE_DIR" "$1"
}

stage_is_done() {
  [[ -f "$(marker_path "$1")" ]]
}

mark_stage_done() {
  local id="$1"
  mkdir -p "$STATE_DIR"
  touch "$(marker_path "$id")"
}

clear_all_markers() {
  if [[ -d "$STATE_DIR" ]]; then
    (
      shopt -s nullglob
      files=("$STATE_DIR"/stage_*.done)
      ((${#files[@]})) && rm -f "${files[@]}"
      rm -f "$STATE_DIR"/checkpoint_*.txt "$STATE_DIR"/checkpoint_*.lock 2>/dev/null || true
    ) 2>/dev/null || true
  fi
  log "State: import resume markers and checkpoints cleared"
}

first_incomplete_stage() {
  local s
  for ((s = STAGE_PREPARE; s <= LAST_STAGE; s++)); do
    if ! stage_is_done "$s"; then
      echo "$s"
      return 0
    fi
  done
  echo ""
}

all_stages_done() {
  [[ "$(first_incomplete_stage)" == "" ]]
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local reply
  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt [Y/n] " reply || true
    [[ -z "$reply" || "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
  else
    read -r -p "$prompt [y/N] " reply || true
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
  fi
}

# -----------------------------------------------------------------------------
# Privileges
# -----------------------------------------------------------------------------

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run this script as root (e.g. sudo $SCRIPT_NAME)."
  fi
}

require_backup_root() {
  [[ -d "$BACKUP_ROOT" ]] || die "Backup directory missing: $BACKUP_ROOT — set ZIMBRA_IMPORT_DIR"
}

# Progress helpers for zimbra subshells (stage id 1–9)
ZIMBRA_PROGRESS_HELPERS=$(
  cat <<'EOS_HELP'
c_for() {
  [[ -n "${NO_COLOR:-}" ]] || [[ -n "${ZIMBRA_IMPORT_NO_COLOR:-}" ]] || [[ -n "${ZIMBRA_EXPORT_NO_COLOR:-}" ]] && return 0
  [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" != "1" ]] && return 0
  case "$1" in
    1) printf '\033[1;95m' ;; 2) printf '\033[1;94m' ;; 3) printf '\033[1;93m' ;; 4) printf '\033[1;92m' ;;
    5) printf '\033[1;96m' ;; 6) printf '\033[1;91m' ;; 7) printf '\033[0;35m' ;; 8) printf '\033[0;34m' ;; 9) printf '\033[0;33m' ;; *) printf '\033[0m' ;;
  esac
}
c_reset() {
  [[ -n "${NO_COLOR:-}" ]] || [[ -n "${ZIMBRA_IMPORT_NO_COLOR:-}" ]] || [[ -n "${ZIMBRA_EXPORT_NO_COLOR:-}" ]] && return 0
  [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" != "1" ]] && return 0
  printf '\033[0m'
}
p_inline() {
  local st="$1" n="$2" t="$3" r="$4" lb="$5"
  local a b
  a=$(c_for "$st")
  b=$(c_reset)
  local zi="${ZIMBRA_IMPORT_INLINE:-${ZIMBRA_EXPORT_INLINE:-1}}"
  if [[ "$zi" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]]; then
    printf '\r\033[K%s[IMPORT %s] +%ss | %d/%d done | %d left | %s%s' "$a" "$st" "$SECONDS" "$n" "$t" "$r" "$lb" "$b" >&2
  else
    printf '%s[IMPORT %s] +%ss | %d/%d done | %d left | %s%s\n' "$a" "$st" "$SECONDS" "$n" "$t" "$r" "$lb" "$b" >&2
  fi
}
p_batch() {
  local st="$1" n="$2" t="$3" tag="$4"
  local a b
  a=$(c_for "$st")
  b=$(c_reset)
  local zi="${ZIMBRA_IMPORT_INLINE:-${ZIMBRA_EXPORT_INLINE:-1}}"
  if [[ "$zi" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]]; then
    printf '\r\033[K%s[IMPORT %s] +%ss | %s %d/%d%s' "$a" "$st" "$SECONDS" "$tag" "$n" "$t" "$b" >&2
  else
    printf '%s[IMPORT %s] +%ss | %s %d/%d%s\n' "$a" "$st" "$SECONDS" "$tag" "$n" "$t" "$b" >&2
  fi
}
p_end() {
  local zi="${ZIMBRA_IMPORT_INLINE:-${ZIMBRA_EXPORT_INLINE:-1}}"
  [[ "$zi" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]] && printf '\n' >&2
}
EOS_HELP
)

run_as_zimbra_login() {
  local cmd="$1"
  sudo -u zimbra -H bash -lc "set -euo pipefail; export PATH=\"/opt/zimbra/bin:\${PATH}\"; $cmd"
}

run_as_zimbra_stdin() {
  require_backup_root
  local _zbuf=()
  if [[ -z "${ZIMBRA_IMPORT_NO_LINEBUF:-${ZIMBRA_EXPORT_NO_LINEBUF:-}}" ]] && command -v stdbuf >/dev/null 2>&1; then
    _zbuf=(stdbuf -o0 -e0)
  fi
  {
    printf '%s\n' "$ZIMBRA_PROGRESS_HELPERS"
    printf '%s\n' '[[ -r /opt/zimbra/.bashrc ]] && . /opt/zimbra/.bashrc' 'export PATH="/opt/zimbra/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"'
    cat
  } | sudo -u zimbra -H env NO_COLOR="${NO_COLOR:-}" ZIMBRA_IMPORT_NO_COLOR="${ZIMBRA_IMPORT_NO_COLOR:-}" ZIMBRA_EXPORT_NO_COLOR="${ZIMBRA_EXPORT_NO_COLOR:-}" \
      BACKUP_ROOT="$BACKUP_ROOT" IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-}" IMPORT_TMP_PASS="${IMPORT_TMP_PASS:-CHANGEme}" \
      IMPORT_PROGRESS_INTERVAL="${IMPORT_PROGRESS_INTERVAL:-50}" IMPORT_EACH_ITEM="${IMPORT_EACH_ITEM:-1}" \
      IMPORT_PARALLEL="${IMPORT_PARALLEL:-10}" IMPORT_PARALLEL_PROGRESS_INTERVAL="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}" \
      IMPORT_DOMAIN_PARALLEL="${IMPORT_DOMAIN_PARALLEL:-}" IMPORT_ACCOUNT_PARALLEL="${IMPORT_ACCOUNT_PARALLEL:-}" IMPORT_ADMIN_PARALLEL="${IMPORT_ADMIN_PARALLEL:-}" \
      IMPORT_DIST_PARALLEL="${IMPORT_DIST_PARALLEL:-}" IMPORT_ADLM_PARALLEL="${IMPORT_ADLM_PARALLEL:-}" IMPORT_ALIAS_PARALLEL="${IMPORT_ALIAS_PARALLEL:-}" \
      IMPORT_SIGNATURE_PARALLEL="${IMPORT_SIGNATURE_PARALLEL:-}" IMPORT_FILTER_PARALLEL="${IMPORT_FILTER_PARALLEL:-}" \
      EXPORT_STAGE_ID="${EXPORT_STAGE_ID:-}" ZIMBRA_IMPORT_INLINE="${ZIMBRA_IMPORT_INLINE:-}" ZIMBRA_EXPORT_INLINE="${ZIMBRA_EXPORT_INLINE:-1}" \
      ZIMBRA_STDERR_WAS_TTY="${ZIMBRA_STDERR_WAS_TTY:-0}" "${_zbuf[@]}" bash -s
}

preflight() {
  local t0=$SECONDS
  id zimbra &>/dev/null || die "User 'zimbra' not found — is Zimbra installed?"
  if ! run_as_zimbra_login "command -v zmprov >/dev/null 2>&1"; then
    [[ -x /opt/zimbra/bin/zmprov ]] || die "zmprov not found for user zimbra — expected under /opt/zimbra/bin"
  fi
  log "Preflight OK · $(fmt_duration $((SECONDS - t0)))"
}

# -----------------------------------------------------------------------------
# Stages
# -----------------------------------------------------------------------------

stage_prepare() {
  SECONDS=0
  log_stage_line "$STAGE_PREPARE" "Prepare" "verify backup tree under ${BACKUP_ROOT}"
  [[ -f "${BACKUP_ROOT}/emails.txt" ]] || die "Missing ${BACKUP_ROOT}/emails.txt"
  [[ -f "${BACKUP_ROOT}/domains.txt" ]] || die "Missing ${BACKUP_ROOT}/domains.txt"
  [[ -d "${BACKUP_ROOT}/userpass" ]] || die "Missing ${BACKUP_ROOT}/userpass/"
  mkdir -p "$STATE_DIR"
  chown zimbra:zimbra "$STATE_DIR" 2>/dev/null || true
  log_stage_status "$STAGE_PREPARE" "[IMPORT ${STAGE_PREPARE}] +${SECONDS}s | OK"
}

stage_domains() {
  export EXPORT_STAGE_ID="${STAGE_DOMAINS}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  log_stage_line "$STAGE_DOMAINS" "Domains" "zmprov cd — domains.txt · checkpoint resume"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-2}"
ck="${IMPORT_STATE_DIR}/checkpoint_02.txt"
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
mapfile -t lines < <(grep -v '^[[:space:]]*$' domains.txt || true)
total=${#lines[@]}
SECONDS=0
n=0
for dom in "${lines[@]}"; do
  if [[ -n "${SK[$dom]+x}" ]]; then
    ((++n)) || true
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$dom (checkpoint)"
    fi
    continue
  fi
  if zmprov gd "$dom" >/dev/null 2>&1; then
    :
  else
    zmprov cd "$dom" zimbraAuthMech zimbra
  fi
  printf '%s\n' "$dom" >> "$ck"
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "$st" "$n" "$total" "$rem" "$dom"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "$st" "$n" "$total" "domains"
    fi
  fi
done
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR
}

stage_accounts() {
  export EXPORT_STAGE_ID="${STAGE_ACCOUNTS}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  local ap
  ap="${IMPORT_ACCOUNT_PARALLEL:-${IMPORT_PARALLEL:-10}}"
  [[ "$ap" =~ ^[0-9]+$ ]] || ap=10
  (( ap < 1 )) && ap=1
  log_stage_line "$STAGE_ACCOUNTS" "Accounts + passwords" "zmprov ca / ma — parallel ${ap} · checkpoint resume"
  export IMPORT_ACCOUNT_PARALLEL="$ap"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-3}"
tmpPass="${IMPORT_TMP_PASS:-CHANGEme}"
ap="${IMPORT_ACCOUNT_PARALLEL:-10}"
[[ "$ap" =~ ^[0-9]+$ ]] || ap=10
(( ap < 1 )) && ap=1
pg="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"
[[ "$pg" =~ ^[0-9]+$ ]] || pg=5
(( pg < 1 )) && pg=1
ck="${IMPORT_STATE_DIR}/checkpoint_03.txt"
lck="${IMPORT_STATE_DIR}/checkpoint_03.lock"
cntf="${IMPORT_STATE_DIR}/checkpoint_03.count"
fail_mark="${IMPORT_STATE_DIR}/fail_03.mark"
: >"$lck" 2>/dev/null || true
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
nf=$(wc -l < "$ck" 2>/dev/null | tr -d ' ' || echo 0)
nf=${nf:-0}
echo "$nf" > "$cntf"
mapfile -t accts < <(grep -v '^[[:space:]]*$' emails.txt || true)
total=${#accts[@]}
SECONDS=0
import_one() {
  local acct="$1"
  if [[ ! -f "userpass/${acct}.shadow" ]]; then
    printf '%s\n' "WARN: missing userpass/${acct}.shadow — skip ${acct}" >&2
    return 0
  fi
  local shadowpass ud givenName displayName
  shadowpass=$(cat "userpass/${acct}.shadow")
  if zmprov ga "$acct" >/dev/null 2>&1; then
    zmprov ma "$acct" userPassword "$shadowpass"
  else
    ud="userdata/${acct}.txt"
    givenName=""
    displayName=""
    if [[ -f "$ud" ]]; then
      givenName=$(grep -i '^[[:space:]]*givenName:' "$ud" 2>/dev/null | head -1 | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      displayName=$(grep -i '^[[:space:]]*displayName:' "$ud" 2>/dev/null | head -1 | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ -z "$displayName" ]]; then
        displayName=$(grep -i '^[[:space:]]*cn:' "$ud" 2>/dev/null | head -1 | cut -d':' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      fi
    fi
    [[ -n "$displayName" ]] || displayName="${acct%%@*}"
    [[ -n "$givenName" ]] || givenName="$displayName"
    zmprov ca "$acct" "$tmpPass" displayName "$displayName" givenName "$givenName" cn "$displayName"
    zmprov ma "$acct" userPassword "$shadowpass"
  fi
}
if (( ap <= 1 )); then
  n=0
  for acct in "${accts[@]}"; do
    if [[ -n "${SK[$acct]+x}" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (checkpoint)"
      continue
    fi
    if [[ ! -f "userpass/${acct}.shadow" ]]; then
      printf '%s\n' "WARN: missing userpass/${acct}.shadow — skipping" >&2
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (no shadow)"
      continue
    fi
    import_one "$acct"
    printf '%s\n' "$acct" >> "$ck"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "accounts"
      fi
    fi
  done
else
  rm -f "$fail_mark"
  active=0
  acct_wait() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  for acct in "${accts[@]}"; do
    [[ -f "$fail_mark" ]] && break
    if [[ -n "${SK[$acct]+x}" ]]; then
      continue
    fi
    while (( active >= ap )); do
      acct_wait
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      if [[ ! -f "userpass/${acct}.shadow" ]]; then
        printf '%s\n' "WARN: missing userpass/${acct}.shadow — skipping" >&2
        exit 0
      fi
      import_one "$acct" || exit 1
      exec 200>>"$lck"
      flock 200
      printf '%s\n' "$acct" >> "$ck"
      read -r pc < "$cntf" || true
      pc=${pc:-0}
      pc=$((pc + 1))
      echo "$pc" > "$cntf"
      nd=$pc
      flock -u 200
      if (( pg > 0 && total > 0 && (pc % pg == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "accounts"
      fi
    ) &
    ((++active)) || true
  done
  set +e
  while (( active > 0 )); do
    wait -n
    w=$?
    ((active--)) || true
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  done
  set -e
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark"; exit 1; }
fi
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR IMPORT_ACCOUNT_PARALLEL
}

stage_admins() {
  export EXPORT_STAGE_ID="${STAGE_ADMINS}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  [[ -f "${BACKUP_ROOT}/admins.txt" ]] || { log_stage_note "$STAGE_ADMINS" "→ skip (no admins.txt)"; unset EXPORT_STAGE_ID; return 0; }
  local ap
  ap="${IMPORT_ADMIN_PARALLEL:-${IMPORT_PARALLEL:-10}}"
  [[ "$ap" =~ ^[0-9]+$ ]] || ap=10
  (( ap < 1 )) && ap=1
  log_stage_line "$STAGE_ADMINS" "Global admins" "zmprov ma zimbraIsAdminAccount — parallel ${ap} · checkpoint resume"
  export IMPORT_ADMIN_PARALLEL="$ap"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-4}"
ap="${IMPORT_ADMIN_PARALLEL:-10}"
[[ "$ap" =~ ^[0-9]+$ ]] || ap=10
(( ap < 1 )) && ap=1
pg="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"
[[ "$pg" =~ ^[0-9]+$ ]] || pg=5
(( pg < 1 )) && pg=1
ck="${IMPORT_STATE_DIR}/checkpoint_04.txt"
lck="${IMPORT_STATE_DIR}/checkpoint_04.lock"
cntf="${IMPORT_STATE_DIR}/checkpoint_04.count"
fail_mark="${IMPORT_STATE_DIR}/fail_04.mark"
: >"$lck" 2>/dev/null || true
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
nf=$(wc -l < "$ck" 2>/dev/null | tr -d ' ' || echo 0)
nf=${nf:-0}
echo "$nf" > "$cntf"
mapfile -t admins < <(grep -v '^[[:space:]]*$' admins.txt || true)
total=${#admins[@]}
SECONDS=0
admin_one() {
  local acct="$1"
  if ! zmprov ga "$acct" >/dev/null 2>&1; then
    printf '%s\n' "WARN: admin account ${acct} not found — skip" >&2
    return 1
  fi
  zmprov ma "$acct" zimbraIsAdminAccount TRUE
}
if (( ap <= 1 )); then
  n=0
  for acct in "${admins[@]}"; do
    [[ -z "${acct//[[:space:]]/}" ]] && continue
    if [[ -n "${SK[$acct]+x}" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (checkpoint)"
      continue
    fi
    if admin_one "$acct"; then
      printf '%s\n' "$acct" >> "$ck"
    fi
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "admins"
      fi
    fi
  done
else
  rm -f "$fail_mark"
  active=0
  adm_wait() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  for acct in "${admins[@]}"; do
    [[ -f "$fail_mark" ]] && break
    [[ -z "${acct//[[:space:]]/}" ]] && continue
    [[ -n "${SK[$acct]+x}" ]] && continue
    while (( active >= ap )); do
      adm_wait
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      admin_one "$acct" || exit 0
      exec 200>>"$lck"
      flock 200
      printf '%s\n' "$acct" >> "$ck"
      read -r pc < "$cntf" || true
      pc=${pc:-0}
      pc=$((pc + 1))
      echo "$pc" > "$cntf"
      nd=$pc
      flock -u 200
      if (( pg > 0 && total > 0 && (pc % pg == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "admins"
      fi
    ) &
    ((++active)) || true
  done
  set +e
  while (( active > 0 )); do
    wait -n
    w=$?
    ((active--)) || true
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  done
  set -e
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark"; exit 1; }
fi
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR IMPORT_ADMIN_PARALLEL
}

stage_distribution() {
  export EXPORT_STAGE_ID="${STAGE_DISTRIBUTION}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  [[ -f "${BACKUP_ROOT}/distributinlist.txt" ]] || { log_stage_note "$STAGE_DISTRIBUTION" "→ skip (no distributinlist.txt)"; unset EXPORT_STAGE_ID IMPORT_STATE_DIR; return 0; }
  log_stage_line "$STAGE_DISTRIBUTION" "Distribution lists" "zmprov cdl — checkpoint resume"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-5}"
ck="${IMPORT_STATE_DIR}/checkpoint_05.txt"
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
mapfile -t lists < <(grep -v '^[[:space:]]*$' distributinlist.txt || true)
total=${#lists[@]}
SECONDS=0
n=0
for list in "${lists[@]}"; do
  if [[ -n "${SK[$list]+x}" ]]; then
    ((++n)) || true
    rem=$((total - n))
    [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$list (checkpoint)"
    continue
  fi
  if zmprov gdl "$list" >/dev/null 2>&1; then
    :
  else
    zmprov cdl "$list"
  fi
  printf '%s\n' "$list" >> "$ck"
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "$st" "$n" "$total" "$rem" "$list"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "$st" "$n" "$total" "cdl"
    fi
  fi
done
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR
}

stage_distribution_members() {
  export EXPORT_STAGE_ID="${STAGE_DISTRIBUTION_MEMBERS}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  [[ -f "${BACKUP_ROOT}/distributinlist.txt" ]] || { log_stage_note "$STAGE_DISTRIBUTION_MEMBERS" "→ skip"; unset EXPORT_STAGE_ID IMPORT_STATE_DIR; return 0; }
  [[ -d "${BACKUP_ROOT}/distributinlist_members" ]] || { log_stage_note "$STAGE_DISTRIBUTION_MEMBERS" "→ skip (no distributinlist_members/)"; unset EXPORT_STAGE_ID IMPORT_STATE_DIR; return 0; }
  local ap
  ap="${IMPORT_ADLM_PARALLEL:-${IMPORT_PARALLEL:-10}}"
  [[ "$ap" =~ ^[0-9]+$ ]] || ap=10
  (( ap < 1 )) && ap=1
  log_stage_line "$STAGE_DISTRIBUTION_MEMBERS" "List members" "zmprov adlm — parallel ${ap} · checkpoint resume"
  export IMPORT_ADLM_PARALLEL="$ap"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-6}"
ap="${IMPORT_ADLM_PARALLEL:-10}"
[[ "$ap" =~ ^[0-9]+$ ]] || ap=10
(( ap < 1 )) && ap=1
pg="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"
[[ "$pg" =~ ^[0-9]+$ ]] || pg=5
(( pg < 1 )) && pg=1
ck="${IMPORT_STATE_DIR}/checkpoint_06.txt"
lck="${IMPORT_STATE_DIR}/checkpoint_06.lock"
cntf="${IMPORT_STATE_DIR}/checkpoint_06.count"
fail_mark="${IMPORT_STATE_DIR}/fail_06.mark"
: >"$lck" 2>/dev/null || true
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS=$'\t' read -r lst mem || [[ -n "$lst" ]]; do
    [[ -z "${lst//[[:space:]]/}" ]] && continue
    SK["${lst}"$'\t'"${mem}"]=1
  done < "$ck"
fi
nf=$(wc -l < "$ck" 2>/dev/null | tr -d ' ' || echo 0)
nf=${nf:-0}
echo "$nf" > "$cntf"
pair_lines=()
mapfile -t lists < <(grep -v '^[[:space:]]*$' distributinlist.txt || true)
for list in "${lists[@]}"; do
  mf="distributinlist_members/${list}.txt"
  [[ -f "$mf" ]] || continue
  while IFS= read -r j || [[ -n "$j" ]]; do
    [[ -z "${j//[[:space:]]/}" ]] && continue
    pair_lines+=("${list}"$'\t'"${j}")
  done < <(grep -v '^[[:space:]]*#' "$mf" | grep '@' || true)
done
total=${#pair_lines[@]}
SECONDS=0
adlm_one() {
  local list="$1" mem="$2"
  zmprov adlm "$list" "$mem"
}
if (( ap <= 1 )); then
  n=0
  for pl in "${pair_lines[@]}"; do
    list="${pl%%$'\t'*}"
    mem="${pl#*$'\t'}"
    if [[ -n "${SK[$pl]+x}" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$list (ck)"
      continue
    fi
    adlm_one "$list" "$mem"
    printf '%s\t%s\n' "$list" "$mem" >> "$ck"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$list"
    else
      if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "adlm"
      fi
    fi
  done
else
  rm -f "$fail_mark"
  active=0
  adlm_wait() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  for pl in "${pair_lines[@]}"; do
    [[ -f "$fail_mark" ]] && break
    list="${pl%%$'\t'*}"
    mem="${pl#*$'\t'}"
    [[ -n "${SK[$pl]+x}" ]] && continue
    while (( active >= ap )); do
      adlm_wait
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      adlm_one "$list" "$mem"
      exec 200>>"$lck"
      flock 200
      printf '%s\t%s\n' "$list" "$mem" >> "$ck"
      read -r pc < "$cntf" || true
      pc=${pc:-0}
      pc=$((pc + 1))
      echo "$pc" > "$cntf"
      nd=$pc
      flock -u 200
      if (( pg > 0 && total > 0 && (pc % pg == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "adlm"
      fi
    ) &
    ((++active)) || true
  done
  set +e
  while (( active > 0 )); do
    wait -n
    w=$?
    ((active--)) || true
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  done
  set -e
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark"; exit 1; }
fi
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR IMPORT_ADLM_PARALLEL
}

stage_aliases() {
  export EXPORT_STAGE_ID="${STAGE_ALIASES}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  local ap
  ap="${IMPORT_ALIAS_PARALLEL:-${IMPORT_PARALLEL:-10}}"
  [[ "$ap" =~ ^[0-9]+$ ]] || ap=10
  (( ap < 1 )) && ap=1
  log_stage_line "$STAGE_ALIASES" "Aliases" "zmprov aaa — parallel ${ap} · checkpoint resume"
  export IMPORT_ALIAS_PARALLEL="$ap"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-7}"
ap="${IMPORT_ALIAS_PARALLEL:-10}"
[[ "$ap" =~ ^[0-9]+$ ]] || ap=10
(( ap < 1 )) && ap=1
pg="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"
[[ "$pg" =~ ^[0-9]+$ ]] || pg=5
(( pg < 1 )) && pg=1
ck="${IMPORT_STATE_DIR}/checkpoint_07.txt"
lck="${IMPORT_STATE_DIR}/checkpoint_07.lock"
cntf="${IMPORT_STATE_DIR}/checkpoint_07.count"
fail_mark="${IMPORT_STATE_DIR}/fail_07.mark"
: >"$lck" 2>/dev/null || true
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
nf=$(wc -l < "$ck" 2>/dev/null | tr -d ' ' || echo 0)
nf=${nf:-0}
echo "$nf" > "$cntf"
mapfile -t accts < <(grep -v '^[[:space:]]*$' emails.txt || true)
total=${#accts[@]}
SECONDS=0
alias_import() {
  local acct="$1"
  local af="alias/${acct}.txt"
  [[ -f "$af" ]] || return 0
  local j
  while IFS= read -r j || [[ -n "$j" ]]; do
    [[ -z "${j//[[:space:]]/}" ]] && continue
    [[ "$j" != *@* ]] && continue
    zmprov aaa "$acct" "$j"
  done < <(grep '@' "$af" || true)
}
if (( ap <= 1 )); then
  n=0
  for acct in "${accts[@]}"; do
    if [[ -n "${SK[$acct]+x}" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (checkpoint)"
      continue
    fi
    af="alias/${acct}.txt"
    [[ -f "$af" ]] || { ((++n)) || true; rem=$((total - n)); [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (no alias file)"; continue; }
    alias_import "$acct"
    printf '%s\n' "$acct" >> "$ck"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "aliases"
      fi
    fi
  done
else
  rm -f "$fail_mark"
  active=0
  al_wait() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  for acct in "${accts[@]}"; do
    [[ -f "$fail_mark" ]] && break
    [[ -n "${SK[$acct]+x}" ]] && continue
    while (( active >= ap )); do
      al_wait
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      af="alias/${acct}.txt"
      if [[ -f "$af" ]]; then
        alias_import "$acct"
      fi
      exec 200>>"$lck"
      flock 200
      if [[ -f "$af" ]]; then
        printf '%s\n' "$acct" >> "$ck"
      fi
      read -r pc < "$cntf" || true
      pc=${pc:-0}
      pc=$((pc + 1))
      echo "$pc" > "$cntf"
      nd=$pc
      flock -u 200
      if (( pg > 0 && total > 0 && (pc % pg == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "aliases"
      fi
    ) &
    ((++active)) || true
  done
  set +e
  while (( active > 0 )); do
    wait -n
    w=$?
    ((active--)) || true
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  done
  set -e
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark"; exit 1; }
fi
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR IMPORT_ALIAS_PARALLEL
}

stage_signatures() {
  export EXPORT_STAGE_ID="${STAGE_SIGNATURES}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  local ap
  ap="${IMPORT_SIGNATURE_PARALLEL:-${IMPORT_PARALLEL:-10}}"
  [[ "$ap" =~ ^[0-9]+$ ]] || ap=10
  (( ap < 1 )) && ap=1
  log_stage_line "$STAGE_SIGNATURES" "Signatures" "zmprov ma signatures — parallel ${ap} · checkpoint resume"
  export IMPORT_SIGNATURE_PARALLEL="$ap"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-8}"
ap="${IMPORT_SIGNATURE_PARALLEL:-10}"
[[ "$ap" =~ ^[0-9]+$ ]] || ap=10
(( ap < 1 )) && ap=1
pg="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"
[[ "$pg" =~ ^[0-9]+$ ]] || pg=5
(( pg < 1 )) && pg=1
ck="${IMPORT_STATE_DIR}/checkpoint_08.txt"
lck="${IMPORT_STATE_DIR}/checkpoint_08.lock"
cntf="${IMPORT_STATE_DIR}/checkpoint_08.count"
fail_mark="${IMPORT_STATE_DIR}/fail_08.mark"
: >"$lck" 2>/dev/null || true
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
nf=$(wc -l < "$ck" 2>/dev/null | tr -d ' ' || echo 0)
nf=${nf:-0}
echo "$nf" > "$cntf"
mapfile -t accts < <(grep -v '^[[:space:]]*$' emails.txt || true)
total=${#accts[@]}
SECONDS=0
sig_import() {
  local acct="$1"
  local nf sf sig_name sig_html tmp firmaid
  nf="signatures/${acct}.name"
  sf="signatures/${acct}.signature"
  if [[ ! -f "$nf" ]] || [[ ! -f "$sf" ]]; then
    return 0
  fi
  sig_name=$(cat "$nf")
  sig_html=$(cat "$sf")
  zmprov ma "$acct" zimbraSignatureName "$sig_name"
  zmprov ma "$acct" zimbraPrefMailSignatureHTML "$sig_html"
  tmp="$(mktemp /tmp/zmigrate_sigid.XXXXXX)"
  zmprov ga "$acct" zimbraSignatureId > "$tmp"
  sed -i '1d' "$tmp" 2>/dev/null || sed -i '' '1d' "$tmp" 2>/dev/null || true
  firmaid=$(sed 's/zimbraSignatureId: //g' "$tmp" | tr -d '\r')
  rm -f "$tmp"
  if [[ -n "${firmaid//[[:space:]]/}" ]]; then
    zmprov ma "$acct" zimbraPrefDefaultSignatureId "$firmaid"
    zmprov ma "$acct" zimbraPrefForwardReplySignatureId "$firmaid"
  fi
}
if (( ap <= 1 )); then
  n=0
  for acct in "${accts[@]}"; do
    if [[ -n "${SK[$acct]+x}" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (checkpoint)"
      continue
    fi
    nf="signatures/${acct}.name"
    sf="signatures/${acct}.signature"
    if [[ ! -f "$nf" ]] || [[ ! -f "$sf" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (no export files)"
      continue
    fi
    sig_import "$acct"
    printf '%s\n' "$acct" >> "$ck"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "signatures"
      fi
    fi
  done
else
  rm -f "$fail_mark"
  active=0
  sg_wait() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  for acct in "${accts[@]}"; do
    [[ -f "$fail_mark" ]] && break
    [[ -n "${SK[$acct]+x}" ]] && continue
    while (( active >= ap )); do
      sg_wait
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      nf="signatures/${acct}.name"
      sf="signatures/${acct}.signature"
      if [[ -f "$nf" && -f "$sf" ]]; then
        sig_import "$acct"
      fi
      exec 200>>"$lck"
      flock 200
      if [[ -f "$nf" && -f "$sf" ]]; then
        printf '%s\n' "$acct" >> "$ck"
      fi
      read -r pc < "$cntf" || true
      pc=${pc:-0}
      pc=$((pc + 1))
      echo "$pc" > "$cntf"
      nd=$pc
      flock -u 200
      if (( pg > 0 && total > 0 && (pc % pg == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "signatures"
      fi
    ) &
    ((++active)) || true
  done
  set +e
  while (( active > 0 )); do
    wait -n
    w=$?
    ((active--)) || true
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  done
  set -e
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark"; exit 1; }
fi
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR IMPORT_SIGNATURE_PARALLEL
}

stage_filters() {
  export EXPORT_STAGE_ID="${STAGE_FILTERS}"
  export IMPORT_STATE_DIR="$STATE_DIR"
  local ap
  ap="${IMPORT_FILTER_PARALLEL:-${IMPORT_PARALLEL:-10}}"
  [[ "$ap" =~ ^[0-9]+$ ]] || ap=10
  (( ap < 1 )) && ap=1
  log_stage_line "$STAGE_FILTERS" "Sieve filters" "zmprov ma zimbraMailSieveScript — parallel ${ap} · checkpoint resume"
  export IMPORT_FILTER_PARALLEL="$ap"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
IMPORT_STATE_DIR="${IMPORT_STATE_DIR:-${BACKUP_ROOT}/.import_state}"
mkdir -p "$IMPORT_STATE_DIR"
ee="${IMPORT_EACH_ITEM:-1}"
int="${IMPORT_PROGRESS_INTERVAL:-50}"
st="${EXPORT_STAGE_ID:-9}"
ap="${IMPORT_FILTER_PARALLEL:-10}"
[[ "$ap" =~ ^[0-9]+$ ]] || ap=10
(( ap < 1 )) && ap=1
pg="${IMPORT_PARALLEL_PROGRESS_INTERVAL:-5}"
[[ "$pg" =~ ^[0-9]+$ ]] || pg=5
(( pg < 1 )) && pg=1
ck="${IMPORT_STATE_DIR}/checkpoint_09.txt"
lck="${IMPORT_STATE_DIR}/checkpoint_09.lock"
cntf="${IMPORT_STATE_DIR}/checkpoint_09.count"
fail_mark="${IMPORT_STATE_DIR}/fail_09.mark"
: >"$lck" 2>/dev/null || true
declare -A SK
if [[ -f "$ck" ]]; then
  while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L//[[:space:]]/}" ]] && continue
    SK["$L"]=1
  done < "$ck"
fi
nf=$(wc -l < "$ck" 2>/dev/null | tr -d ' ' || echo 0)
nf=${nf:-0}
echo "$nf" > "$cntf"
mapfile -t accts < <(grep -v '^[[:space:]]*$' emails.txt || true)
total=${#accts[@]}
SECONDS=0
if (( ap <= 1 )); then
  n=0
  for acct in "${accts[@]}"; do
    if [[ -n "${SK[$acct]+x}" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (checkpoint)"
      continue
    fi
    ff="filter/${acct}.filter"
    if [[ ! -f "$ff" ]]; then
      ((++n)) || true
      rem=$((total - n))
      [[ "$ee" == "1" ]] && p_inline "$st" "$n" "$total" "$rem" "$acct (no filter file)"
      continue
    fi
    sieve=$(cat "$ff")
    zmprov ma "$acct" zimbraMailSieveScript "$sieve"
    printf '%s\n' "$acct" >> "$ck"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "filters"
      fi
    fi
  done
else
  rm -f "$fail_mark"
  active=0
  fl_wait() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  for acct in "${accts[@]}"; do
    [[ -f "$fail_mark" ]] && break
    [[ -n "${SK[$acct]+x}" ]] && continue
    while (( active >= ap )); do
      fl_wait
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      ff="filter/${acct}.filter"
      if [[ -f "$ff" ]]; then
        sieve=$(cat "$ff")
        zmprov ma "$acct" zimbraMailSieveScript "$sieve"
      fi
      exec 200>>"$lck"
      flock 200
      if [[ -f "$ff" ]]; then
        printf '%s\n' "$acct" >> "$ck"
      fi
      read -r pc < "$cntf" || true
      pc=${pc:-0}
      pc=$((pc + 1))
      echo "$pc" > "$cntf"
      nd=$pc
      flock -u 200
      if (( pg > 0 && total > 0 && (pc % pg == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "filters"
      fi
    ) &
    ((++active)) || true
  done
  set +e
  while (( active > 0 )); do
    wait -n
    w=$?
    ((active--)) || true
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  done
  set -e
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark"; exit 1; }
fi
p_end
EOS
  unset EXPORT_STAGE_ID IMPORT_STATE_DIR IMPORT_FILTER_PARALLEL
}

run_stage() {
  local id="$1"
  case "$id" in
    "$STAGE_PREPARE") stage_prepare ;;
    "$STAGE_DOMAINS") stage_domains ;;
    "$STAGE_ACCOUNTS") stage_accounts ;;
    "$STAGE_ADMINS") stage_admins ;;
    "$STAGE_DISTRIBUTION") stage_distribution ;;
    "$STAGE_DISTRIBUTION_MEMBERS") stage_distribution_members ;;
    "$STAGE_ALIASES") stage_aliases ;;
    "$STAGE_SIGNATURES") stage_signatures ;;
    "$STAGE_FILTERS") stage_filters ;;
    *) die "Unknown stage: $id" ;;
  esac
}

stage_name() {
  case "$1" in
    "$STAGE_PREPARE") echo "Prepare / verify backup" ;;
    "$STAGE_DOMAINS") echo "Create domains" ;;
    "$STAGE_ACCOUNTS") echo "Accounts and passwords" ;;
    "$STAGE_ADMINS") echo "Global admin accounts" ;;
    "$STAGE_DISTRIBUTION") echo "Distribution lists" ;;
    "$STAGE_DISTRIBUTION_MEMBERS") echo "Distribution list members" ;;
    "$STAGE_ALIASES") echo "Aliases" ;;
    "$STAGE_SIGNATURES") echo "Signatures" ;;
    "$STAGE_FILTERS") echo "Sieve filters" ;;
    *) echo "Stage $1" ;;
  esac
}

validate_stage_id() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  ((n >= STAGE_PREPARE && n <= LAST_STAGE)) || return 1
  return 0
}

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME [--retry-stage N] [--reset-state]
       $SCRIPT_NAME --help

  Imports data from export backup under: $BACKUP_ROOT
  Override with: ZIMBRA_IMPORT_DIR=/path $SCRIPT_NAME
  (Also accepts ZIMBRA_EXPORT_DIR for the same path.)

  This script WRITES to Zimbra LDAP. Re-run to resume from the first incomplete stage.

  --retry-stage N   Re-run from stage N — valid: 1–${LAST_STAGE}. If already done,
                    you must confirm; its marker is removed.
  --reset-state     Remove import completion markers only — data already imported stays.

Stages:
  ${STAGE_PREPARE}=$(stage_name "$STAGE_PREPARE")
  ${STAGE_DOMAINS}=$(stage_name "$STAGE_DOMAINS")
  ${STAGE_ACCOUNTS}=$(stage_name "$STAGE_ACCOUNTS")
  ${STAGE_ADMINS}=$(stage_name "$STAGE_ADMINS")
  ${STAGE_DISTRIBUTION}=$(stage_name "$STAGE_DISTRIBUTION")
  ${STAGE_DISTRIBUTION_MEMBERS}=$(stage_name "$STAGE_DISTRIBUTION_MEMBERS")
  ${STAGE_ALIASES}=$(stage_name "$STAGE_ALIASES")
  ${STAGE_SIGNATURES}=$(stage_name "$STAGE_SIGNATURES")
  ${STAGE_FILTERS}=$(stage_name "$STAGE_FILTERS")

Environment:
  ZIMBRA_IMPORT_DIR        Backup root — default: /backups/zmigrate
  IMPORT_TMP_PASS          Temporary password for zmprov ca before hash apply — default: CHANGEme
  IMPORT_PROGRESS_INTERVAL Batch progress when IMPORT_EACH_ITEM=0 — default: 50
  IMPORT_EACH_ITEM         1 = per-row progress — default: 1
  IMPORT_PARALLEL          Default concurrent workers for heavy stages — default: 10 — set to 1 for sequential
  IMPORT_PARALLEL_PROGRESS_INTERVAL  Parallel mode: p_batch every N items — default: 5
  IMPORT_ACCOUNT_PARALLEL  Override for stage ${STAGE_ACCOUNTS} (default: IMPORT_PARALLEL)
  IMPORT_ADMIN_PARALLEL    Override for stage ${STAGE_ADMINS}
  IMPORT_ADLM_PARALLEL     Override for stage ${STAGE_DISTRIBUTION_MEMBERS}
  IMPORT_ALIAS_PARALLEL    Override for stage ${STAGE_ALIASES}
  IMPORT_SIGNATURE_PARALLEL  Override for stage ${STAGE_SIGNATURES}
  IMPORT_FILTER_PARALLEL   Override for stage ${STAGE_FILTERS}
  ZIMBRA_IMPORT_INLINE     1 = TTY one-line refresh — default: 1 (or ZIMBRA_EXPORT_INLINE)

Checkpoints (for resume mid-stage): \${BACKUP_ROOT}/.import_state/checkpoint_NN.txt (+ .lock / .count where used)
EOF
}

main() {
  local retry_from=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        usage
        exit 0
        ;;
      --reset-state)
        require_root
        clear_all_markers
        exit 0
        ;;
      --retry-stage)
        [[ -n "${2:-}" ]] || die "--retry-stage requires a number 1–${LAST_STAGE}"
        retry_from="$2"
        shift 2
        continue
        ;;
      *)
        usage
        exit 1
        ;;
    esac
    shift
  done

  require_root

  if [[ -n "$retry_from" ]]; then
    validate_stage_id "$retry_from" || die "Invalid stage: $retry_from — use 1–${LAST_STAGE}"
    log "Retry from stage ${retry_from} · $(stage_name "$retry_from")"
    if stage_is_done "$retry_from"; then
      if ! prompt_yes_no "Stage ${retry_from} is already complete. Remove its marker and re-run from here? Later stages may be duplicated."; then
        log "Aborted by user."
        exit 0
      fi
    fi
    local s
    for ((s = retry_from; s <= LAST_STAGE; s++)); do
      rm -f "$(marker_path "$s")"
      rm -f "${STATE_DIR}/checkpoint_$(printf '%02d' "$s").txt" "${STATE_DIR}/checkpoint_$(printf '%02d' "$s").lock" 2>/dev/null || true
    done
    log "Markers cleared: ${retry_from}–${LAST_STAGE}"
  fi

  log "=== Import · ${BACKUP_ROOT} · ${STATE_DIR} ==="

  preflight

  if ! prompt_yes_no "This will modify Zimbra (LDAP). Backup tree: ${BACKUP_ROOT}. Continue?"; then
    log "Aborted by user."
    exit 0
  fi

  require_backup_root

  if all_stages_done; then
    log "All import stages are already marked complete."
    if ! prompt_yes_no "Re-run the full import from stage 1? May duplicate aliases/list members etc."; then
      log "Aborted by user."
      exit 0
    fi
    clear_all_markers
  fi

  local start
  start="$(first_incomplete_stage)"
  if [[ -z "$start" ]]; then
    die "Internal error: no incomplete stage but not all done?"
  fi
  if [[ -n "$retry_from" ]] && ((start < retry_from)); then
    die "Cannot resume from stage ${retry_from}: stage ${start} is still incomplete."
  fi
  log "Resume: stage ${start} · $(stage_name "$start")"

  local s name t0
  for ((s = start; s <= LAST_STAGE; s++)); do
    name="$(stage_name "$s")"
    t0=$SECONDS
    run_stage "$s"
    mark_stage_done "$s"
    rm -f "${STATE_DIR}/checkpoint_$(printf '%02d' "$s").txt" \
      "${STATE_DIR}/checkpoint_$(printf '%02d' "$s").lock" \
      "${STATE_DIR}/checkpoint_$(printf '%02d' "$s").count" \
      "${STATE_DIR}/fail_$(printf '%02d' "$s").mark" 2>/dev/null || true
    log_stage_done_line "$s" "$LAST_STAGE" "$(fmt_duration $((SECONDS - t0)))" "$name"
  done

  log "=== Import finished · ${BACKUP_ROOT} ==="
}

main "$@"

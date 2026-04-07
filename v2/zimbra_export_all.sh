#!/usr/bin/env bash
#
# Zimbra full configuration export (resumable, with safety prompts)
# Run as root on the Zimbra server (or with sudo). Requires sudo -u zimbra.
#
# Safety: This script only runs zmprov read/list commands and writes files under BACKUP_ROOT.
# It does not modify Zimbra configuration, mailboxes, or LDAP beyond normal read load.
# Large deployments: many sequential zmprov calls add LDAP load; run in a maintenance window if unsure.
#
# Audited zmprov usage (read-only): gad, gaaa, gaa, gadl, gdlm, ga, zmprov -l ga <attr>
# No ma/md/dd/delete/modify/provision commands are used.
#
set -euo pipefail

# Capture TTY before stderr may be wrapped (sudo child also sees non-tty stderr)
ZIMBRA_STDERR_WAS_TTY=0
[[ -t 2 ]] && ZIMBRA_STDERR_WAS_TTY=1
export ZIMBRA_STDERR_WAS_TTY

# In-place progress (\r): unbuffered stderr when inline + original TTY
readonly ZIMBRA_EXPORT_INLINE="${ZIMBRA_EXPORT_INLINE:-1}"
if [[ -z "${ZIMBRA_EXPORT_NO_LINEBUF:-}" ]] && command -v stdbuf >/dev/null 2>&1; then
  if [[ "${ZIMBRA_EXPORT_INLINE}" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY}" == "1" ]]; then
    exec 2> >(stdbuf -o0 cat >&2)
  else
    exec 2> >(stdbuf -oL cat >&2)
  fi
fi

readonly SCRIPT_NAME="${0##*/}"
readonly BACKUP_ROOT="${ZIMBRA_EXPORT_DIR:-/backups/zmigrate}"
readonly STATE_DIR="${BACKUP_ROOT}/.export_state"
# Stage IDs must stay stable for resume markers (11 stages; dist. lists vs members are 5 and 6).
# If upgrading from a 10-stage build, run --reset-state once so markers match the new numbering.
readonly STAGE_PREPARE=1
readonly STAGE_DOMAINS=2
readonly STAGE_ADMINS=3
readonly STAGE_EMAILS=4
readonly STAGE_DISTRIBUTION=5
readonly STAGE_DISTRIBUTION_MEMBERS=6
readonly STAGE_PASSWORDS=7
readonly STAGE_USERDATA=8
readonly STAGE_ALIASES=9
readonly STAGE_SIGNATURES=10
readonly STAGE_FILTERS=11

readonly LAST_STAGE="${STAGE_FILTERS}"

# Batch interval when EXPORT_EACH_ITEM=0 (otherwise one log line per item)
readonly EXPORT_PROGRESS_INTERVAL="${EXPORT_PROGRESS_INTERVAL:-50}"
# 1 = live row progress for all stages; 0 = batch by EXPORT_PROGRESS_INTERVAL
readonly EXPORT_EACH_ITEM="${EXPORT_EACH_ITEM:-1}"

# -----------------------------------------------------------------------------
# Logging (no timestamps on screen; optional colors per stage when TTY and NO_COLOR unset)
# -----------------------------------------------------------------------------

use_color() {
  [[ -z "${NO_COLOR:-}" ]] && [[ -z "${ZIMBRA_EXPORT_NO_COLOR:-}" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]]
}

stage_color_begin() {
  local id="$1"
  use_color || return 0
  case "$id" in
    1) printf '\033[1;95m' ;;   # bright magenta
    2) printf '\033[1;94m' ;;   # bright blue
    3) printf '\033[1;93m' ;;   # bright yellow
    4) printf '\033[1;92m' ;;   # bright green
    5) printf '\033[1;96m' ;;   # bright cyan
    6) printf '\033[1;91m' ;;   # bright red
    7) printf '\033[0;35m' ;;   # magenta
    8) printf '\033[0;34m' ;;   # blue
    9) printf '\033[0;33m' ;;   # yellow
    10) printf '\033[0;32m' ;;  # green
    11) printf '\033[0;36m' ;;  # cyan
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
  printf '[STAGE %s] %s — %s' "$id" "$title" "$detail" >&2
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

log_stage_done_line() {
  local id="$1" last="$2" dur="$3" name="$4"
  stage_color_begin "$id"
  printf '[STAGE %s/%s] ✓ %s — %s ·' "$id" "$last" "$dur" "$name" >&2
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

# Human-readable duration from bash SECONDS (integer seconds)
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

# Non-empty line count (zmprov output is usually one item per line)
count_nonempty_lines() {
  local f="$1" n
  [[ -r "$f" ]] || { echo 0; return 0; }
  n=$(grep -cve '^[[:space:]]*$' "$f" 2>/dev/null) || n=0
  echo "$n"
}

count_files_in_dir() {
  local d="$1" pat="${2:-*}"
  [[ -d "$d" ]] || { echo 0; return 0; }
  find "$d" -mindepth 1 -maxdepth 1 -type f -name "$pat" 2>/dev/null | wc -l | tr -d ' '
}

# Accounts in emails.txt that already have userpass/<acct>.shadow (for stage 7 resume)
count_pw_exports_done() {
  local f="$BACKUP_ROOT/emails.txt" acct n=0
  [[ -r "$f" ]] || { echo 0; return 0; }
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -z "${acct//[[:space:]]/}" ]] && continue
    [[ -f "$BACKUP_ROOT/userpass/${acct}.shadow" ]] && ((++n)) || true
  done < "$f"
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
  log_err "Interrupted — SIGINT — export may be incomplete; re-run to resume from the last incomplete stage."
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
    ) 2>/dev/null || true
  fi
  log "State: resume markers cleared"
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
# Privileges / zimbra user
# -----------------------------------------------------------------------------

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run this script as root (e.g. sudo $SCRIPT_NAME)."
  fi
}

require_backup_root() {
  [[ -d "$BACKUP_ROOT" ]] || die "Backup directory missing: $BACKUP_ROOT — run stage 1 first or set ZIMBRA_EXPORT_DIR"
}

# Injected into zimbra subshells: same-line refresh on TTY; full lines if no TTY or ZIMBRA_EXPORT_INLINE=0
ZIMBRA_PROGRESS_HELPERS=$(
  cat <<'EOS_HELP'
c_for() {
  [[ -n "${NO_COLOR:-}" ]] || [[ -n "${ZIMBRA_EXPORT_NO_COLOR:-}" ]] && return 0
  [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" != "1" ]] && return 0
  case "$1" in
    1) printf '\033[1;95m' ;; 2) printf '\033[1;94m' ;; 3) printf '\033[1;93m' ;; 4) printf '\033[1;92m' ;;
    5) printf '\033[1;96m' ;; 6) printf '\033[1;91m' ;; 7) printf '\033[0;35m' ;; 8) printf '\033[0;34m' ;;
    9) printf '\033[0;33m' ;; 10) printf '\033[0;32m' ;; 11) printf '\033[0;36m' ;; *) printf '\033[0m' ;;
  esac
}
c_reset() {
  [[ -n "${NO_COLOR:-}" ]] || [[ -n "${ZIMBRA_EXPORT_NO_COLOR:-}" ]] && return 0
  [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" != "1" ]] && return 0
  printf '\033[0m'
}
p_inline() {
  local st="$1" n="$2" t="$3" r="$4" lb="$5"
  local a b
  a=$(c_for "$st")
  b=$(c_reset)
  if [[ "${ZIMBRA_EXPORT_INLINE:-1}" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]]; then
    printf '\r\033[K%s[STAGE %s] +%ss | %d/%d done | %d left | %s%s' "$a" "$st" "$SECONDS" "$n" "$t" "$r" "$lb" "$b" >&2
  else
    printf '%s[STAGE %s] +%ss | %d/%d done | %d left | %s%s\n' "$a" "$st" "$SECONDS" "$n" "$t" "$r" "$lb" "$b" >&2
  fi
}
p_batch() {
  local st="$1" n="$2" t="$3" tag="$4"
  local a b
  a=$(c_for "$st")
  b=$(c_reset)
  if [[ "${ZIMBRA_EXPORT_INLINE:-1}" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]]; then
    printf '\r\033[K%s[STAGE %s] +%ss | %s %d/%d%s' "$a" "$st" "$SECONDS" "$tag" "$n" "$t" "$b" >&2
  else
    printf '%s[STAGE %s] +%ss | %s %d/%d%s\n' "$a" "$st" "$SECONDS" "$tag" "$n" "$t" "$b" >&2
  fi
}
p_end() {
  [[ "${ZIMBRA_EXPORT_INLINE:-1}" == "1" ]] && [[ "${ZIMBRA_STDERR_WAS_TTY:-0}" == "1" ]] && printf '\n' >&2
}
EOS_HELP
)

# Login shell as zimbra with Zimbra bin in PATH (no cd — safe before backup dir exists)
run_as_zimbra_login() {
  local cmd="$1"
  sudo -u zimbra -H bash -lc "set -euo pipefail; export PATH=\"/opt/zimbra/bin:\${PATH}\"; $cmd"
}

run_as_zimbra() {
  local cmd="$1"
  require_backup_root
  {
    printf '%s\n' "$ZIMBRA_PROGRESS_HELPERS"
    printf '%s\n' 'set -euo pipefail' 'export PATH="/opt/zimbra/bin:${PATH:-}"'
    printf 'cd %q\n' "$BACKUP_ROOT"
    printf '%s\n' "$cmd"
  } | sudo -u zimbra -H env NO_COLOR="${NO_COLOR:-}" ZIMBRA_EXPORT_NO_COLOR="${ZIMBRA_EXPORT_NO_COLOR:-}" ZIMBRA_EXPORT_INLINE="${ZIMBRA_EXPORT_INLINE:-1}" ZIMBRA_STDERR_WAS_TTY="${ZIMBRA_STDERR_WAS_TTY:-0}" bash -s
}

# Run multi-line script as zimbra (stdin). Caller: run_as_zimbra_stdin <<'EOS' ... EOS
# Prepends Zimbra PATH and optional /opt/zimbra/.bashrc so zmprov matches interactive "su - zimbra".
# Optional: EXPORT_TOTAL / EXPORT_PROGRESS_INTERVAL / EXPORT_STAGE_ID / EXPORT_EACH_ITEM for heredoc scripts.
run_as_zimbra_stdin() {
  require_backup_root
  local _zbuf=()
  # Child bash stderr is often a pipe (not a TTY) → libc block-buffers; unbuffer for live progress.
  if [[ -z "${ZIMBRA_EXPORT_NO_LINEBUF:-}" ]] && command -v stdbuf >/dev/null 2>&1; then
    _zbuf=(stdbuf -o0 -e0)
  fi
  {
    printf '%s\n' "$ZIMBRA_PROGRESS_HELPERS"
    printf '%s\n' '[[ -r /opt/zimbra/.bashrc ]] && . /opt/zimbra/.bashrc' 'export PATH="/opt/zimbra/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"'
    cat
  } | sudo -u zimbra -H env NO_COLOR="${NO_COLOR:-}" ZIMBRA_EXPORT_NO_COLOR="${ZIMBRA_EXPORT_NO_COLOR:-}" BACKUP_ROOT="$BACKUP_ROOT" EXPORT_TOTAL="${EXPORT_TOTAL:-0}" EXPORT_PROGRESS_INTERVAL="${EXPORT_PROGRESS_INTERVAL:-50}" EXPORT_PASSWORD_PROGRESS_INTERVAL="${EXPORT_PASSWORD_PROGRESS_INTERVAL:-}" EXPORT_USERDATA_PARALLEL="${EXPORT_USERDATA_PARALLEL:-10}" EXPORT_USERDATA_PROGRESS_INTERVAL="${EXPORT_USERDATA_PROGRESS_INTERVAL:-}" EXPORT_ALIAS_PARALLEL="${EXPORT_ALIAS_PARALLEL:-10}" EXPORT_ALIAS_PROGRESS_INTERVAL="${EXPORT_ALIAS_PROGRESS_INTERVAL:-}" EXPORT_SIGNATURE_PARALLEL="${EXPORT_SIGNATURE_PARALLEL:-10}" EXPORT_SIGNATURE_PROGRESS_INTERVAL="${EXPORT_SIGNATURE_PROGRESS_INTERVAL:-}" EXPORT_FILTER_PARALLEL="${EXPORT_FILTER_PARALLEL:-10}" EXPORT_FILTER_PROGRESS_INTERVAL="${EXPORT_FILTER_PROGRESS_INTERVAL:-}" EXPORT_STAGE_ID="${EXPORT_STAGE_ID:-}" EXPORT_EACH_ITEM="${EXPORT_EACH_ITEM:-1}" EXPORT_PASSWORD_EACH="${EXPORT_PASSWORD_EACH:-}" EXPORT_PASSWORD_PARALLEL="${EXPORT_PASSWORD_PARALLEL:-10}" EXPORT_PW_SKIPPED="${EXPORT_PW_SKIPPED:-0}" ZIMBRA_EXPORT_INLINE="${ZIMBRA_EXPORT_INLINE:-1}" ZIMBRA_STDERR_WAS_TTY="${ZIMBRA_STDERR_WAS_TTY:-0}" "${_zbuf[@]}" bash -s
}

preflight() {
  local t0=$SECONDS
  id zimbra &>/dev/null || die "User 'zimbra' not found — is Zimbra installed?"
  if ! run_as_zimbra_login "command -v zmprov >/dev/null 2>&1"; then
    if [[ -x /opt/zimbra/bin/zmprov ]]; then
      :
    else
      die "zmprov not found for user zimbra — expected under /opt/zimbra/bin — try: su - zimbra -c 'which zmprov'"
    fi
  fi
  log "Preflight OK · $(fmt_duration $((SECONDS - t0)))"
}

# -----------------------------------------------------------------------------
# Stages
# -----------------------------------------------------------------------------

stage_prepare() {
  SECONDS=0
  log_stage_line "$STAGE_PREPARE" "Prepare dirs" "${BACKUP_ROOT} · ${STATE_DIR}"
  mkdir -p "$BACKUP_ROOT"
  chown zimbra:zimbra "$BACKUP_ROOT"
  mkdir -p "$STATE_DIR"
  chown zimbra:zimbra "$STATE_DIR" 2>/dev/null || true
  log_stage_status "$STAGE_PREPARE" "[STAGE ${STAGE_PREPARE}] +${SECONDS}s | 1/1 | OK"
}

stage_domains() {
  export EXPORT_STAGE_ID="${STAGE_DOMAINS}"
  log_stage_line "$STAGE_DOMAINS" "Domains" "zmprov gad → domains.txt"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
ee="${EXPORT_EACH_ITEM:-1}"
int="${EXPORT_PROGRESS_INTERVAL:-50}"
SECONDS=0
mapfile -t raw < <(zmprov gad)
lines=()
for r in "${raw[@]}"; do
  [[ -z "${r//[[:space:]]/}" ]] && continue
  lines+=("$r")
done
total=${#lines[@]}
: > domains.txt
n=0
for line in "${lines[@]}"; do
  printf '%s\n' "$line" >> domains.txt
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "${EXPORT_STAGE_ID}" "$n" "$total" "$rem" "$line"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "${EXPORT_STAGE_ID}" "$n" "$total" "domains"
    fi
  fi
done
p_end
EOS
  local n
  n=$(count_nonempty_lines "$BACKUP_ROOT/domains.txt")
  log_stage_note "$STAGE_DOMAINS" "→ ${n} domains"
  unset EXPORT_STAGE_ID
}

stage_admins() {
  export EXPORT_STAGE_ID="${STAGE_ADMINS}"
  log_stage_line "$STAGE_ADMINS" "Admins" "zmprov gaaa → admins.txt"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
ee="${EXPORT_EACH_ITEM:-1}"
int="${EXPORT_PROGRESS_INTERVAL:-50}"
SECONDS=0
mapfile -t raw < <(zmprov gaaa)
lines=()
for r in "${raw[@]}"; do
  [[ -z "${r//[[:space:]]/}" ]] && continue
  lines+=("$r")
done
total=${#lines[@]}
: > admins.txt
n=0
for line in "${lines[@]}"; do
  printf '%s\n' "$line" >> admins.txt
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "${EXPORT_STAGE_ID}" "$n" "$total" "$rem" "$line"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "${EXPORT_STAGE_ID}" "$n" "$total" "admins"
    fi
  fi
done
p_end
EOS
  local n
  n=$(count_nonempty_lines "$BACKUP_ROOT/admins.txt")
  log_stage_note "$STAGE_ADMINS" "→ ${n} admins"
  unset EXPORT_STAGE_ID
}

stage_emails() {
  export EXPORT_STAGE_ID="${STAGE_EMAILS}"
  log_stage_line "$STAGE_EMAILS" "Mail accounts" "zmprov -l gaa → emails.txt"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
ee="${EXPORT_EACH_ITEM:-1}"
int="${EXPORT_PROGRESS_INTERVAL:-50}"
SECONDS=0
mapfile -t raw < <(zmprov -l gaa)
lines=()
for r in "${raw[@]}"; do
  [[ -z "${r//[[:space:]]/}" ]] && continue
  lines+=("$r")
done
total=${#lines[@]}
: > emails.txt
n=0
for line in "${lines[@]}"; do
  printf '%s\n' "$line" >> emails.txt
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "${EXPORT_STAGE_ID}" "$n" "$total" "$rem" "$line"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "${EXPORT_STAGE_ID}" "$n" "$total" "accounts"
    fi
  fi
done
p_end
EOS
  local n
  n=$(count_nonempty_lines "$BACKUP_ROOT/emails.txt")
  log_stage_note "$STAGE_EMAILS" "→ ${n} accounts"
  unset EXPORT_STAGE_ID
}

stage_distribution() {
  export EXPORT_STAGE_ID="${STAGE_DISTRIBUTION}"
  log_stage_line "$STAGE_DISTRIBUTION" "Dist. lists" "zmprov gadl → distributinlist.txt"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
ee="${EXPORT_EACH_ITEM:-1}"
int="${EXPORT_PROGRESS_INTERVAL:-50}"
SECONDS=0
mapfile -t raw < <(zmprov gadl)
lists=()
for r in "${raw[@]}"; do
  [[ -z "${r//[[:space:]]/}" ]] && continue
  lists+=("$r")
done
total=${#lists[@]}
: > distributinlist.txt
n=0
for list in "${lists[@]}"; do
  printf '%s\n' "$list" >> distributinlist.txt
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "${EXPORT_STAGE_ID}" "$n" "$total" "$rem" "$list"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "${EXPORT_STAGE_ID}" "$n" "$total" "gadl"
    fi
  fi
done
p_end
EOS
  local n_lists
  n_lists=$(count_nonempty_lines "$BACKUP_ROOT/distributinlist.txt")
  log_stage_note "$STAGE_DISTRIBUTION" "→ ${n_lists} lists"
  unset EXPORT_STAGE_ID
}

stage_distribution_members() {
  require_backup_root
  [[ -f "$BACKUP_ROOT/distributinlist.txt" ]] || die "Missing ${BACKUP_ROOT}/distributinlist.txt — run stage ${STAGE_DISTRIBUTION} first"
  export EXPORT_STAGE_ID="${STAGE_DISTRIBUTION_MEMBERS}"
  log_stage_line "$STAGE_DISTRIBUTION_MEMBERS" "Dist. list members" "zmprov gdlm → distributinlist_members/*.txt"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
ee="${EXPORT_EACH_ITEM:-1}"
int="${EXPORT_PROGRESS_INTERVAL:-50}"
SECONDS=0
mapfile -t lists < <(grep -v '^[[:space:]]*$' distributinlist.txt || true)
total=${#lists[@]}
mkdir -p distributinlist_members
n=0
for list in "${lists[@]}"; do
  zmprov gdlm "$list" > "distributinlist_members/${list}.txt"
  ((++n))
  rem=$((total - n))
  if [[ "$ee" == "1" ]]; then
    p_inline "${EXPORT_STAGE_ID}" "$n" "$total" "$rem" "$list"
  else
    if (( int > 0 && total > 0 && (n % int == 0 || n == total) )); then
      p_batch "${EXPORT_STAGE_ID}" "$n" "$total" "gdlm"
    fi
  fi
done
p_end
EOS
  local n_members
  n_members=$(count_files_in_dir "$BACKUP_ROOT/distributinlist_members" "*.txt")
  log_stage_note "$STAGE_DISTRIBUTION_MEMBERS" "→ ${n_members} member files"
  unset EXPORT_STAGE_ID
}

stage_passwords() {
  local total nf pe done_already pw_parallel
  total=$(count_nonempty_lines "${BACKUP_ROOT}/emails.txt")
  pe="${EXPORT_PASSWORD_EACH:-${EXPORT_EACH_ITEM:-1}}"
  done_already=$(count_pw_exports_done)
  pw_parallel="${EXPORT_PASSWORD_PARALLEL:-10}"
  [[ "$pw_parallel" =~ ^[0-9]+$ ]] || pw_parallel=10
  (( pw_parallel < 1 )) && pw_parallel=1
  if (( pw_parallel > 1 )); then
    if [[ "$pe" == "1" ]]; then
      log_stage_line "$STAGE_PASSWORDS" "Password hashes" "${total} accounts → userpass/*.shadow · parallel ${pw_parallel}"
    else
      log_stage_line "$STAGE_PASSWORDS" "Password hashes" "${total} accounts → userpass · parallel ${pw_parallel} · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  else
    if [[ "$pe" == "1" ]]; then
      log_stage_line "$STAGE_PASSWORDS" "Password hashes" "${total} accounts → userpass/*.shadow"
    else
      log_stage_line "$STAGE_PASSWORDS" "Password hashes" "${total} accounts → userpass · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  fi
  if (( total > 0 && done_already > 0 )); then
    if (( done_already >= total )); then
      log_stage_note "$STAGE_PASSWORDS" "Resume · ${done_already}/${total} already in userpass — nothing to fetch"
    else
      log_stage_note "$STAGE_PASSWORDS" "Resume · ${done_already}/${total} already in userpass — skipping those"
    fi
  fi
  export EXPORT_TOTAL="$total" EXPORT_STAGE_ID="${STAGE_PASSWORDS}" EXPORT_PASSWORD_EACH="${pe}"
  export EXPORT_PASSWORD_PARALLEL="$pw_parallel" EXPORT_PW_SKIPPED="$done_already"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
mkdir -p userpass
total="${EXPORT_TOTAL:-0}"
interval="${EXPORT_PROGRESS_INTERVAL:-50}"
ee="${EXPORT_PASSWORD_EACH:-${EXPORT_EACH_ITEM:-1}}"
st="${EXPORT_STAGE_ID:-7}"
pw_parallel="${EXPORT_PASSWORD_PARALLEL:-10}"
sk="${EXPORT_PW_SKIPPED:-0}"
[[ "$pw_parallel" =~ ^[0-9]+$ ]] || pw_parallel=10
(( pw_parallel < 1 )) && pw_parallel=1
# Parallel password stage: use EXPORT_PASSWORD_PROGRESS_INTERVAL, else default 5 (not 50) so progress feels live.
pw_interval="${EXPORT_PASSWORD_PROGRESS_INTERVAL:-}"
if [[ -z "$pw_interval" ]] || ! [[ "$pw_interval" =~ ^[0-9]+$ ]]; then
  if (( pw_parallel > 1 )); then
    pw_interval=5
  else
    pw_interval="$interval"
  fi
fi
(( pw_interval < 1 )) && pw_interval=1
SECONDS=0
if (( pw_parallel <= 1 )); then
  n_done=0
  n_fetched=0
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -z "$acct" ]] && continue
    if [[ -f "userpass/${acct}.shadow" ]]; then
      ((++n_done)) || true
      continue
    fi
    tmp="$(mktemp /tmp/zmigrate_pw.XXXXXX)"
    if ! zmprov -l ga "$acct" userPassword > "$tmp"; then rm -f "$tmp"; exit 1; fi
    grep userPassword: "$tmp" | awk '{print $2}' > "${tmp}.out" || true
    rm -f "$tmp"
    mv -f "${tmp}.out" "userpass/${acct}.shadow"
    ((++n_done)) || true
    ((++n_fetched)) || true
    rem=$((total - n_done))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n_done" "$total" "$rem" "$acct"
    else
      if (( n_fetched > 0 && interval > 0 && (n_fetched % interval == 0 || n_done == total) )); then
        p_batch "$st" "$n_done" "$total" "passwords"
      fi
    fi
  done < emails.txt
  if [[ "$ee" != "1" ]] && (( total > 0 && n_done == total && n_fetched == 0 )); then
    p_batch "$st" "$n_done" "$total" "passwords"
  fi
else
  lockf="${BACKUP_ROOT}/.pw_stage7.lock"
  cntf="${BACKUP_ROOT}/.pw_stage7.fetched"
  fail_mark="${BACKUP_ROOT}/.pw_stage7.fail"
  rm -f "$fail_mark" "$cntf"
  echo 0 > "$cntf"
  : > "$lockf"
  active=0
  pw_wait_one() {
    set +e
    wait -n
    local w=$?
    set -e
    # Do not use (( w != 0 )) && touch — when w=0, ((...)) is false (status 1) and set -e aborts the script.
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -f "$fail_mark" ]] && break
    [[ -z "$acct" ]] && continue
    if [[ -f "userpass/${acct}.shadow" ]]; then
      continue
    fi
    while (( active >= pw_parallel )); do
      pw_wait_one
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      tmp="$(mktemp /tmp/zmigrate_pw.XXXXXX)"
      if ! zmprov -l ga "$acct" userPassword > "$tmp"; then rm -f "$tmp"; exit 1; fi
      grep userPassword: "$tmp" | awk '{print $2}' > "${tmp}.out" || true
      rm -f "$tmp"
      mv -f "${tmp}.out" "userpass/${acct}.shadow"
      exec 200>>"$lockf"
      flock 200
      read -r nf < "$cntf" || true
      nf=${nf:-0}
      nf=$((nf + 1))
      echo "$nf" > "$cntf"
      nd=$((sk + nf))
      flock -u 200
      rem=$((total - nd))
      if (( pw_interval > 0 && total > 0 && (nf % pw_interval == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "passwords"
      fi
    ) &
    ((++active)) || true
  done < emails.txt
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
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark" "$cntf" "$lockf"; exit 1; }
  rm -f "$cntf" "$lockf"
  if [[ "$ee" != "1" ]] && (( total > 0 && sk >= total )); then
    p_batch "$st" "$sk" "$total" "passwords"
  fi
fi
p_end
EOS
  nf=$(count_files_in_dir "$BACKUP_ROOT/userpass" "*.shadow")
  log_stage_note "$STAGE_PASSWORDS" "→ ${nf} .shadow files"
  unset EXPORT_TOTAL EXPORT_STAGE_ID EXPORT_PASSWORD_EACH EXPORT_PASSWORD_PARALLEL EXPORT_PW_SKIPPED
}

stage_userdata() {
  local total nf ee ud_parallel
  total=$(count_nonempty_lines "${BACKUP_ROOT}/emails.txt")
  ee="${EXPORT_EACH_ITEM:-1}"
  ud_parallel="${EXPORT_USERDATA_PARALLEL:-10}"
  [[ "$ud_parallel" =~ ^[0-9]+$ ]] || ud_parallel=10
  (( ud_parallel < 1 )) && ud_parallel=1
  if (( ud_parallel > 1 )); then
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_USERDATA" "Names" "${total} accounts → userdata/*.txt · parallel ${ud_parallel}"
    else
      log_stage_line "$STAGE_USERDATA" "Names" "${total} accounts → userdata · parallel ${ud_parallel} · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  else
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_USERDATA" "Names" "${total} accounts → userdata/*.txt"
    else
      log_stage_line "$STAGE_USERDATA" "Names" "${total} accounts → userdata · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  fi
  export EXPORT_TOTAL="$total" EXPORT_STAGE_ID="${STAGE_USERDATA}" EXPORT_USERDATA_PARALLEL="$ud_parallel"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
mkdir -p userdata
total="${EXPORT_TOTAL:-0}"
interval="${EXPORT_PROGRESS_INTERVAL:-50}"
ee="${EXPORT_EACH_ITEM:-1}"
st="${EXPORT_STAGE_ID:-8}"
ud_parallel="${EXPORT_USERDATA_PARALLEL:-10}"
[[ "$ud_parallel" =~ ^[0-9]+$ ]] || ud_parallel=10
(( ud_parallel < 1 )) && ud_parallel=1
ud_interval="${EXPORT_USERDATA_PROGRESS_INTERVAL:-}"
if [[ -z "$ud_interval" ]] || ! [[ "$ud_interval" =~ ^[0-9]+$ ]]; then
  if (( ud_parallel > 1 )); then
    ud_interval=5
  else
    ud_interval="$interval"
  fi
fi
(( ud_interval < 1 )) && ud_interval=1
SECONDS=0
if (( ud_parallel <= 1 )); then
  n=0
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -z "$acct" ]] && continue
    tmp="$(mktemp /tmp/zmigrate_ud.XXXXXX)"
    if ! zmprov ga "$acct" > "$tmp"; then rm -f "$tmp"; exit 1; fi
    grep -i Name: "$tmp" > "userdata/${acct}.txt" || true
    rm -f "$tmp"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( total > 0 && interval > 0 && (n % interval == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "names"
      fi
    fi
  done < emails.txt
else
  lockf="${BACKUP_ROOT}/.ud_stage8.lock"
  cntf="${BACKUP_ROOT}/.ud_stage8.fetched"
  fail_mark="${BACKUP_ROOT}/.ud_stage8.fail"
  rm -f "$fail_mark" "$cntf"
  echo 0 > "$cntf"
  : > "$lockf"
  active=0
  ud_wait_one() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -f "$fail_mark" ]] && break
    [[ -z "$acct" ]] && continue
    while (( active >= ud_parallel )); do
      ud_wait_one
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      tmp="$(mktemp /tmp/zmigrate_ud.XXXXXX)"
      if ! zmprov ga "$acct" > "$tmp"; then rm -f "$tmp"; exit 1; fi
      grep -i Name: "$tmp" > "userdata/${acct}.txt" || true
      rm -f "$tmp"
      exec 200>>"$lockf"
      flock 200
      read -r nf < "$cntf" || true
      nf=${nf:-0}
      nf=$((nf + 1))
      echo "$nf" > "$cntf"
      nd=$nf
      flock -u 200
      if (( ud_interval > 0 && total > 0 && (nf % ud_interval == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "names"
      fi
    ) &
    ((++active)) || true
  done < emails.txt
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
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark" "$cntf" "$lockf"; exit 1; }
  rm -f "$cntf" "$lockf"
fi
p_end
EOS
  nf=$(count_files_in_dir "$BACKUP_ROOT/userdata" "*.txt")
  log_stage_note "$STAGE_USERDATA" "→ ${nf} files"
  unset EXPORT_TOTAL EXPORT_STAGE_ID EXPORT_USERDATA_PARALLEL
}

stage_aliases() {
  local total nf ee al_parallel
  total=$(count_nonempty_lines "${BACKUP_ROOT}/emails.txt")
  ee="${EXPORT_EACH_ITEM:-1}"
  al_parallel="${EXPORT_ALIAS_PARALLEL:-10}"
  [[ "$al_parallel" =~ ^[0-9]+$ ]] || al_parallel=10
  (( al_parallel < 1 )) && al_parallel=1
  if (( al_parallel > 1 )); then
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_ALIASES" "Aliases" "${total} accounts → alias/*.txt · parallel ${al_parallel}"
    else
      log_stage_line "$STAGE_ALIASES" "Aliases" "${total} accounts → alias · parallel ${al_parallel} · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  else
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_ALIASES" "Aliases" "${total} accounts → alias/*.txt"
    else
      log_stage_line "$STAGE_ALIASES" "Aliases" "${total} accounts → alias · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  fi
  export EXPORT_TOTAL="$total" EXPORT_STAGE_ID="${STAGE_ALIASES}" EXPORT_ALIAS_PARALLEL="$al_parallel"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
mkdir -p alias
total="${EXPORT_TOTAL:-0}"
interval="${EXPORT_PROGRESS_INTERVAL:-50}"
ee="${EXPORT_EACH_ITEM:-1}"
st="${EXPORT_STAGE_ID:-9}"
al_parallel="${EXPORT_ALIAS_PARALLEL:-10}"
[[ "$al_parallel" =~ ^[0-9]+$ ]] || al_parallel=10
(( al_parallel < 1 )) && al_parallel=1
al_interval="${EXPORT_ALIAS_PROGRESS_INTERVAL:-}"
if [[ -z "$al_interval" ]] || ! [[ "$al_interval" =~ ^[0-9]+$ ]]; then
  if (( al_parallel > 1 )); then
    al_interval=5
  else
    al_interval="$interval"
  fi
fi
(( al_interval < 1 )) && al_interval=1
SECONDS=0
if (( al_parallel <= 1 )); then
  n=0
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -z "$acct" ]] && continue
    tmp="$(mktemp /tmp/zmigrate_al.XXXXXX)"
    if ! zmprov ga "$acct" > "$tmp"; then rm -f "$tmp"; exit 1; fi
    grep zimbraMailAlias "$tmp" | awk '{print $2}' > "alias/${acct}.txt" || true
    rm -f "$tmp"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( total > 0 && interval > 0 && (n % interval == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "aliases"
      fi
    fi
  done < emails.txt
else
  lockf="${BACKUP_ROOT}/.al_stage9.lock"
  cntf="${BACKUP_ROOT}/.al_stage9.fetched"
  fail_mark="${BACKUP_ROOT}/.al_stage9.fail"
  rm -f "$fail_mark" "$cntf"
  echo 0 > "$cntf"
  : > "$lockf"
  active=0
  al_wait_one() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -f "$fail_mark" ]] && break
    [[ -z "$acct" ]] && continue
    while (( active >= al_parallel )); do
      al_wait_one
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      tmp="$(mktemp /tmp/zmigrate_al.XXXXXX)"
      if ! zmprov ga "$acct" > "$tmp"; then rm -f "$tmp"; exit 1; fi
      grep zimbraMailAlias "$tmp" | awk '{print $2}' > "alias/${acct}.txt" || true
      rm -f "$tmp"
      exec 200>>"$lockf"
      flock 200
      read -r nf < "$cntf" || true
      nf=${nf:-0}
      nf=$((nf + 1))
      echo "$nf" > "$cntf"
      nd=$nf
      flock -u 200
      if (( al_interval > 0 && total > 0 && (nf % al_interval == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "aliases"
      fi
    ) &
    ((++active)) || true
  done < emails.txt
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
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark" "$cntf" "$lockf"; exit 1; }
  rm -f "$cntf" "$lockf"
fi
p_end
EOS
  nf=$(count_files_in_dir "$BACKUP_ROOT/alias" "*.txt")
  log_stage_note "$STAGE_ALIASES" "→ ${nf} files"
  unset EXPORT_TOTAL EXPORT_STAGE_ID EXPORT_ALIAS_PARALLEL
}

stage_signatures() {
  local total nsig nname sig_parallel ee
  total=$(count_nonempty_lines "${BACKUP_ROOT}/emails.txt")
  ee="${EXPORT_EACH_ITEM:-1}"
  sig_parallel="${EXPORT_SIGNATURE_PARALLEL:-10}"
  [[ "$sig_parallel" =~ ^[0-9]+$ ]] || sig_parallel=10
  (( sig_parallel < 1 )) && sig_parallel=1
  if (( sig_parallel > 1 )); then
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_SIGNATURES" "Signatures" "${total} accounts → *.signature · *.name · parallel ${sig_parallel}"
    else
      log_stage_line "$STAGE_SIGNATURES" "Signatures" "${total} accounts → signatures · parallel ${sig_parallel} · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  else
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_SIGNATURES" "Signatures" "${total} accounts → *.signature · *.name"
    else
      log_stage_line "$STAGE_SIGNATURES" "Signatures" "${total} accounts → signatures · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  fi
  export EXPORT_TOTAL="$total" EXPORT_STAGE_ID="${STAGE_SIGNATURES}" EXPORT_SIGNATURE_PARALLEL="$sig_parallel"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
mkdir -p signatures
total="${EXPORT_TOTAL:-0}"
interval="${EXPORT_PROGRESS_INTERVAL:-50}"
ee="${EXPORT_EACH_ITEM:-1}"
st="${EXPORT_STAGE_ID:-10}"
sig_parallel="${EXPORT_SIGNATURE_PARALLEL:-10}"
[[ "$sig_parallel" =~ ^[0-9]+$ ]] || sig_parallel=10
(( sig_parallel < 1 )) && sig_parallel=1
sig_interval="${EXPORT_SIGNATURE_PROGRESS_INTERVAL:-}"
if [[ -z "$sig_interval" ]] || ! [[ "$sig_interval" =~ ^[0-9]+$ ]]; then
  if (( sig_parallel > 1 )); then
    sig_interval=5
  else
    sig_interval="$interval"
  fi
fi
(( sig_interval < 1 )) && sig_interval=1
SECONDS=0
if (( sig_parallel <= 1 )); then
  n=0
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -z "$acct" ]] && continue
    tmp="$(mktemp /tmp/zmigrate_sig.XXXXXX)"
    zmprov ga "$acct" zimbraPrefMailSignatureHTML > "$tmp"
    sed -i -e '1d' "$tmp"
    sed 's/zimbraPrefMailSignatureHTML: //g' "$tmp" > "signatures/${acct}.signature"
    rm -f "$tmp"
    tmp="$(mktemp /tmp/zmigrate_name.XXXXXX)"
    zmprov ga "$acct" zimbraSignatureName > "$tmp"
    sed -i -e '1d' "$tmp"
    sed 's/zimbraSignatureName: //g' "$tmp" > "signatures/${acct}.name"
    rm -f "$tmp"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( total > 0 && interval > 0 && (n % interval == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "signatures"
      fi
    fi
  done < emails.txt
else
  lockf="${BACKUP_ROOT}/.sig_stage10.lock"
  cntf="${BACKUP_ROOT}/.sig_stage10.fetched"
  fail_mark="${BACKUP_ROOT}/.sig_stage10.fail"
  rm -f "$fail_mark" "$cntf"
  echo 0 > "$cntf"
  : > "$lockf"
  active=0
  sig_wait_one() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -f "$fail_mark" ]] && break
    [[ -z "$acct" ]] && continue
    while (( active >= sig_parallel )); do
      sig_wait_one
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      tmp="$(mktemp /tmp/zmigrate_sig.XXXXXX)"
      zmprov ga "$acct" zimbraPrefMailSignatureHTML > "$tmp"
      sed -i -e '1d' "$tmp"
      sed 's/zimbraPrefMailSignatureHTML: //g' "$tmp" > "signatures/${acct}.signature"
      rm -f "$tmp"
      tmp="$(mktemp /tmp/zmigrate_name.XXXXXX)"
      zmprov ga "$acct" zimbraSignatureName > "$tmp"
      sed -i -e '1d' "$tmp"
      sed 's/zimbraSignatureName: //g' "$tmp" > "signatures/${acct}.name"
      rm -f "$tmp"
      exec 200>>"$lockf"
      flock 200
      read -r nf < "$cntf" || true
      nf=${nf:-0}
      nf=$((nf + 1))
      echo "$nf" > "$cntf"
      nd=$nf
      flock -u 200
      if (( sig_interval > 0 && total > 0 && (nf % sig_interval == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "signatures"
      fi
    ) &
    ((++active)) || true
  done < emails.txt
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
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark" "$cntf" "$lockf"; exit 1; }
  rm -f "$cntf" "$lockf"
fi
p_end
EOS
  nsig=$(count_files_in_dir "$BACKUP_ROOT/signatures" "*.signature")
  nname=$(count_files_in_dir "$BACKUP_ROOT/signatures" "*.name")
  log_stage_note "$STAGE_SIGNATURES" "→ ${nsig} .signature · ${nname} .name"
  unset EXPORT_TOTAL EXPORT_STAGE_ID EXPORT_SIGNATURE_PARALLEL
}

stage_filters() {
  local total nf fl_parallel ee
  total=$(count_nonempty_lines "${BACKUP_ROOT}/emails.txt")
  ee="${EXPORT_EACH_ITEM:-1}"
  fl_parallel="${EXPORT_FILTER_PARALLEL:-10}"
  [[ "$fl_parallel" =~ ^[0-9]+$ ]] || fl_parallel=10
  (( fl_parallel < 1 )) && fl_parallel=1
  if (( fl_parallel > 1 )); then
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_FILTERS" "Sieve filters" "${total} accounts → filter/*.filter · parallel ${fl_parallel}"
    else
      log_stage_line "$STAGE_FILTERS" "Sieve filters" "${total} accounts → filter · parallel ${fl_parallel} · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  else
    if [[ "$ee" == "1" ]]; then
      log_stage_line "$STAGE_FILTERS" "Sieve filters" "${total} accounts → filter/*.filter"
    else
      log_stage_line "$STAGE_FILTERS" "Sieve filters" "${total} accounts → filter · batch ${EXPORT_PROGRESS_INTERVAL}"
    fi
  fi
  export EXPORT_TOTAL="$total" EXPORT_STAGE_ID="${STAGE_FILTERS}" EXPORT_FILTER_PARALLEL="$fl_parallel"
  run_as_zimbra_stdin <<'EOS'
set -euo pipefail
cd "$BACKUP_ROOT"
mkdir -p filter
total="${EXPORT_TOTAL:-0}"
interval="${EXPORT_PROGRESS_INTERVAL:-50}"
ee="${EXPORT_EACH_ITEM:-1}"
st="${EXPORT_STAGE_ID:-11}"
fl_parallel="${EXPORT_FILTER_PARALLEL:-10}"
[[ "$fl_parallel" =~ ^[0-9]+$ ]] || fl_parallel=10
(( fl_parallel < 1 )) && fl_parallel=1
fl_interval="${EXPORT_FILTER_PROGRESS_INTERVAL:-}"
if [[ -z "$fl_interval" ]] || ! [[ "$fl_interval" =~ ^[0-9]+$ ]]; then
  if (( fl_parallel > 1 )); then
    fl_interval=5
  else
    fl_interval="$interval"
  fi
fi
(( fl_interval < 1 )) && fl_interval=1
SECONDS=0
if (( fl_parallel <= 1 )); then
  n=0
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -z "$acct" ]] && continue
    tmp="$(mktemp /tmp/zmigrate_flt.XXXXXX)"
    zmprov ga "$acct" zimbraMailSieveScript > "$tmp"
    sed -i -e '1d' "$tmp"
    sed 's/zimbraMailSieveScript: //g' "$tmp" > "filter/${acct}.filter"
    rm -f "$tmp"
    ((++n))
    rem=$((total - n))
    if [[ "$ee" == "1" ]]; then
      p_inline "$st" "$n" "$total" "$rem" "$acct"
    else
      if (( total > 0 && interval > 0 && (n % interval == 0 || n == total) )); then
        p_batch "$st" "$n" "$total" "filters"
      fi
    fi
  done < emails.txt
else
  lockf="${BACKUP_ROOT}/.flt_stage11.lock"
  cntf="${BACKUP_ROOT}/.flt_stage11.fetched"
  fail_mark="${BACKUP_ROOT}/.flt_stage11.fail"
  rm -f "$fail_mark" "$cntf"
  echo 0 > "$cntf"
  : > "$lockf"
  active=0
  fl_wait_one() {
    set +e
    wait -n
    local w=$?
    set -e
    if (( w != 0 )); then
      touch "$fail_mark"
    fi
  }
  while IFS= read -r acct || [[ -n "$acct" ]]; do
    [[ -f "$fail_mark" ]] && break
    [[ -z "$acct" ]] && continue
    while (( active >= fl_parallel )); do
      fl_wait_one
      ((active--)) || true
    done
    [[ -f "$fail_mark" ]] && break
    (
      set -euo pipefail
      tmp="$(mktemp /tmp/zmigrate_flt.XXXXXX)"
      zmprov ga "$acct" zimbraMailSieveScript > "$tmp"
      sed -i -e '1d' "$tmp"
      sed 's/zimbraMailSieveScript: //g' "$tmp" > "filter/${acct}.filter"
      rm -f "$tmp"
      exec 200>>"$lockf"
      flock 200
      read -r nf < "$cntf" || true
      nf=${nf:-0}
      nf=$((nf + 1))
      echo "$nf" > "$cntf"
      nd=$nf
      flock -u 200
      if (( fl_interval > 0 && total > 0 && (nf % fl_interval == 0 || nd == total) )); then
        p_batch "$st" "$nd" "$total" "filters"
      fi
    ) &
    ((++active)) || true
  done < emails.txt
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
  [[ -f "$fail_mark" ]] && { rm -f "$fail_mark" "$cntf" "$lockf"; exit 1; }
  rm -f "$cntf" "$lockf"
fi
p_end
EOS
  nf=$(count_files_in_dir "$BACKUP_ROOT/filter" "*.filter")
  log_stage_note "$STAGE_FILTERS" "→ ${nf} .filter files"
  unset EXPORT_TOTAL EXPORT_STAGE_ID EXPORT_FILTER_PARALLEL
}

run_stage() {
  local id="$1"
  case "$id" in
    "$STAGE_PREPARE") stage_prepare ;;
    "$STAGE_DOMAINS") stage_domains ;;
    "$STAGE_ADMINS") stage_admins ;;
    "$STAGE_EMAILS") stage_emails ;;
    "$STAGE_DISTRIBUTION") stage_distribution ;;
    "$STAGE_DISTRIBUTION_MEMBERS") stage_distribution_members ;;
    "$STAGE_PASSWORDS") stage_passwords ;;
    "$STAGE_USERDATA") stage_userdata ;;
    "$STAGE_ALIASES") stage_aliases ;;
    "$STAGE_SIGNATURES") stage_signatures ;;
    "$STAGE_FILTERS") stage_filters ;;
    *) die "Unknown stage: $id" ;;
  esac
}

stage_name() {
  case "$1" in
    "$STAGE_PREPARE") echo "Prepare directories" ;;
    "$STAGE_DOMAINS") echo "Domains" ;;
    "$STAGE_ADMINS") echo "Admin accounts" ;;
    "$STAGE_EMAILS") echo "Mail accounts" ;;
    "$STAGE_DISTRIBUTION") echo "Distribution lists" ;;
    "$STAGE_DISTRIBUTION_MEMBERS") echo "Distribution list members" ;;
    "$STAGE_PASSWORDS") echo "User password hashes" ;;
    "$STAGE_USERDATA") echo "User display names" ;;
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

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME [--retry-stage N] [--reset-state]
       $SCRIPT_NAME --help

  Exports Zimbra LDAP/mailbox-related settings under: $BACKUP_ROOT
  Override with: ZIMBRA_EXPORT_DIR=/path $SCRIPT_NAME

  Resume: re-run the script; it continues from the first incomplete stage.
  If every stage is done, you are asked before overwriting.

  --retry-stage N   Re-run from stage N — valid: 1–${LAST_STAGE}. If already done,
                    you must confirm; its marker is removed.
  --reset-state     Remove stage completion markers only — export files stay on disk.

Stages:
  ${STAGE_PREPARE}=$(stage_name "$STAGE_PREPARE")
  ${STAGE_DOMAINS}=$(stage_name "$STAGE_DOMAINS")
  ${STAGE_ADMINS}=$(stage_name "$STAGE_ADMINS")
  ${STAGE_EMAILS}=$(stage_name "$STAGE_EMAILS")
  ${STAGE_DISTRIBUTION}=$(stage_name "$STAGE_DISTRIBUTION")
  ${STAGE_DISTRIBUTION_MEMBERS}=$(stage_name "$STAGE_DISTRIBUTION_MEMBERS")
  ${STAGE_PASSWORDS}=$(stage_name "$STAGE_PASSWORDS")
  ${STAGE_USERDATA}=$(stage_name "$STAGE_USERDATA")
  ${STAGE_ALIASES}=$(stage_name "$STAGE_ALIASES")
  ${STAGE_SIGNATURES}=$(stage_name "$STAGE_SIGNATURES")
  ${STAGE_FILTERS}=$(stage_name "$STAGE_FILTERS")

Environment:
  ZIMBRA_EXPORT_DIR        Backup root — default: /backups/zmigrate
  EXPORT_PROGRESS_INTERVAL Used when EXPORT_EACH_ITEM=0 — batch step — default: 50
  EXPORT_EACH_ITEM         1 = live progress for all stages — default: 1
  EXPORT_PASSWORD_EACH     Optional override for stage ${STAGE_PASSWORDS} — same as EXPORT_EACH_ITEM
                           Stage ${STAGE_PASSWORDS} skips accounts that already have userpass/<account>.shadow
  EXPORT_PASSWORD_PARALLEL Concurrent zmprov jobs in stage ${STAGE_PASSWORDS} — default: 10 — set to 1 for sequential
  EXPORT_PASSWORD_PROGRESS_INTERVAL  Stage ${STAGE_PASSWORDS} parallel mode: print progress every N new fetches — default: 5 — use 1 for near real-time
  EXPORT_USERDATA_PARALLEL  Stage ${STAGE_USERDATA} (names): concurrent zmprov ga jobs — default: 10 — set to 1 for sequential
  EXPORT_USERDATA_PROGRESS_INTERVAL  Stage ${STAGE_USERDATA} parallel mode: progress every N accounts — default: 5
  EXPORT_ALIAS_PARALLEL  Stage ${STAGE_ALIASES}: concurrent zmprov ga jobs — default: 10 — set to 1 for sequential
  EXPORT_ALIAS_PROGRESS_INTERVAL  Stage ${STAGE_ALIASES} parallel mode: progress every N accounts — default: 5
  EXPORT_SIGNATURE_PARALLEL  Stage ${STAGE_SIGNATURES}: concurrent account workers — default: 10 — set to 1 for sequential
  EXPORT_SIGNATURE_PROGRESS_INTERVAL  Stage ${STAGE_SIGNATURES} parallel mode: progress every N accounts — default: 5
  EXPORT_FILTER_PARALLEL  Stage ${STAGE_FILTERS}: concurrent account workers — default: 10 — set to 1 for sequential
  EXPORT_FILTER_PROGRESS_INTERVAL  Stage ${STAGE_FILTERS} parallel mode: progress every N accounts — default: 5
  ZIMBRA_EXPORT_INLINE     1 = one-line TTY refresh with \\r — 0 = newline each update — default: 1
  ZIMBRA_EXPORT_NO_LINEBUF Set to 1 to disable stderr stdbuf — inline refresh may break
  NO_COLOR                 Set to disable ANSI colors — standard
  ZIMBRA_EXPORT_NO_COLOR   Set to disable stage colors even on a TTY
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
      if ! prompt_yes_no "Stage ${retry_from} is already complete. Remove its marker and re-run from here? Stages ${retry_from}–${LAST_STAGE} may be overwritten."; then
        log "Aborted by user."
        exit 0
      fi
    fi
    local s
    for ((s = retry_from; s <= LAST_STAGE; s++)); do
      rm -f "$(marker_path "$s")"
    done
    log "Markers cleared: ${retry_from}–${LAST_STAGE}"
  fi

  log "=== Export · ${BACKUP_ROOT} · ${STATE_DIR} ==="

  preflight

  if all_stages_done; then
    log "All export stages are already marked complete."
    if ! prompt_yes_no "Re-run the full export from stage 1? Existing files may be overwritten."; then
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
    die "Cannot resume from stage ${retry_from}: stage ${start} is still incomplete. Complete earlier stages first."
  fi
  log "Resume: stage ${start} · $(stage_name "$start")"

  local s name t0
  for ((s = start; s <= LAST_STAGE; s++)); do
    name="$(stage_name "$s")"
    t0=$SECONDS
    run_stage "$s"
    mark_stage_done "$s"
    log_stage_done_line "$s" "$LAST_STAGE" "$(fmt_duration $((SECONDS - t0)))" "$name"
  done

  log "=== Done · ${BACKUP_ROOT} ==="
}

main "$@"

#!/bin/bash
# The only way to run simulator tests (CI, agents, people). See README.md, "Build and test".
#
# One run at a time on the whole machine (a lock directory, ~/Library/Caches/sim-test.lock, that is not specific to
# this project so other projects can use the same lock), on dedicated simulators nothing else touches, only after a
# preflight that the machine is quiet enough for the numbers to mean anything, and with the result written to disk
# where any session can read it (`scripts/ui-test.sh last`).
#
# Exit codes: 0 pass, 1 test failures, 2 build (or simulator setup) failure, 64 usage,
#             75 the machine was busy or the run was invalid. 75 is NOT a test failure: wait and run it again.
#
# bash 3.2 compatible (the macOS system bash): no associative arrays, mapfile or ${var,,}.

# shellcheck disable=SC2012  # ls on our own timestamped folder names is fine
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PY="$SCRIPT_DIR/ui-test-report.py"

# ---- Settings (environment overrides are for CI and the self-test) ----------------------------------------------

PROJECT=${UITEST_PROJECT:-bridgewatch}
LOCK_DIR=${UITEST_LOCK_DIR:-$HOME/Library/Caches/sim-test.lock}
STATE_ROOT=${UITEST_STATE_ROOT:-$HOME/Library/Application Support/bridgewatch-ci}
RESULTS_ROOT=${UITEST_RESULTS_ROOT:-$STATE_ROOT/results}
PERF_HISTORY=${UITEST_PERF_HISTORY:-$STATE_ROOT/perf-history.tsv}
CACHE_ROOT=${UITEST_CACHE_ROOT:-$HOME/Library/Caches/bridgewatch-ci}
DEVICES_DIR=${UITEST_DEVICES_DIR:-$HOME/Library/Developer/CoreSimulator/Devices}
MIN_FREE_GB=${UITEST_MIN_FREE_GB:-6}
MIN_IDLE_PCT=${UITEST_MIN_IDLE_PCT:-40}
ABORT_FREE_GB=${UITEST_ABORT_FREE_GB:-2}
CLEAN_DD_FREE_GB=${UITEST_CLEAN_DD_FREE_GB:-8}
WATCHDOG_INTERVAL=${UITEST_WATCHDOG_INTERVAL:-30}
PERF_GAP=${UITEST_PERF_GAP:-30}
KEEP_RUNS=${UITEST_KEEP_RUNS:-30}
SCHEME=BoatAR
UI_TARGET=BoatARUITests
SMOKE_FILE="$REPO_ROOT/BoatARUITests/smoke-tests.txt"
MAP_FILE="$REPO_ROOT/BoatARUITests/test-map.txt"
CHAOS_FILE="$REPO_ROOT/BoatARUITests/chaos-tests.txt"
APP_BUNDLE_ID=com.bsowens.BoatAR
APP_PROCESS=BoatAR
PERF_TESTS="testCameraPerformance testListPerformance testListScrollPerformance testMapPerformance"

# Reserved simulators: nothing else may use these names. "kind|name|device type|runtime".
SIM_PRO="pro|BW Test iPhone 18 Pro|iPhone 18 Pro|27.0"
SIM_DUO="duo|BW Test iPhone Duo|iPhone Duo|27.1"

log() { printf '[ui-test %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

usage() {
  cat <<'EOF'
Usage: scripts/ui-test.sh <tier> [options]

Tiers:
  smoke                    the smoke set (BoatARUITests/smoke-tests.txt) on one simulator (iPhone 18 Pro class)
  full                     every UI test on both simulators (iPhone 18 Pro class + iPhone Duo class),
                           plus the Release-configuration build
  chaos [--seed N]         opt-in chaos tests (monkey + scenarios, BoatARUITests/chaos-tests.txt) on both simulators;
                           see docs/CHAOS-FINDINGS.md. Long (the monkey alone is ~15 min); no Release build
  perf                     the four opt-in performance tests, one xcodebuild each, ~30 s apart, on the
                           iPhone 18 Pro class simulator; appends to perf-history.tsv
  only <Class/test> [...]  just those tests (BoatARUITests/testName), on one simulator, or both with --both
  changed [<base-ref>]     tests mapped from the paths changed against <base-ref> (default origin/main) by
                           BoatARUITests/test-map.txt, plus smoke
  last [tier]              print the newest summary.md (of that tier)
  status                   who holds the machine lock, CPU idle, free disk
  hold [--wait <min>] -- <command...>
                           take the machine lock (same preflight) for as long as <command> runs, then release it:
                           for work on the simulators that is not a test run (e.g. exploratory testing)
  selftest                 check the script's own logic (no simulators, no xcodebuild)

Options:
  --dry-run                print the plan and the preflight verdict; run nothing, change nothing
  --wait <minutes>         wait up to N minutes for the lock and a quiet machine instead of failing at once (default 0)
  --keep-booted            leave the test simulators booted afterwards (default: shut them down)
  --results-dir <path>     keep results under <path> instead of ~/Library/Application Support/bridgewatch-ci/results
  --both                   with `only`: run on both simulators
  --chaos                  run the tests with BOATAR_CHAOS=1 (the chaos tier does this itself); e.g.
                           `only BoatARUITests/testChaosMonkey --chaos --seed 7`
  --seed <n>               the chaos monkey's seed (BOATAR_CHAOS_SEED) to replay a run; needs the chaos tier or --chaos

Exit codes: 0 pass, 1 test failures, 2 build failure, 64 usage, 75 machine busy or run invalid (not a test failure:
wait and run again).
Busy means: CPU under UITEST_MIN_IDLE_PCT idle (default 40; measured with top, NOT the load average, which macOS
background daemons inflate), under UITEST_MIN_FREE_GB free disk (default 6), or another xcodebuild running.
Environment: UITEST_MIN_IDLE_PCT, UITEST_MIN_FREE_GB, UITEST_EXPORT_ATTACHMENTS=1
(keep every attachment, e.g. the screenshot tour's, under <run folder>/attachments).
Chaos: BOATAR_CHAOS_SEED and BOATAR_CHAOS_ACTIONS (default 400) in the environment reach the tests when chaos is on.
Crashes: every tier that runs tests collects the app's .ips crash reports made during the run into <run folder>/crashes
and fails the run if there are any (UITEST_CRASH_DIRS, colon-separated, replaces the folders searched).
EOF
}

# ---- Machine readings --------------------------------------------------------------------------------------------

get_load() {
  if [ -n "${UITEST_FAKE_LOAD:-}" ]; then echo "$UITEST_FAKE_LOAD"; return; fi
  sysctl -n vm.loadavg | awk '{print $2}'
}

get_ncpu() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# CPU idle percentage from the SECOND sample of top (the first is the average since boot). Takes about 3 s.
get_idle() {
  if [ -n "${UITEST_FAKE_IDLE:-}" ]; then echo "$UITEST_FAKE_IDLE"; return; fi
  run_timeout 30 top -l 2 -n 0 -s 3 | grep 'CPU usage' | tail -1 | sed -n -E 's/.* ([0-9.]+)% idle.*/\1/p'
}

# The three busiest processes right now, "pct name" per line (what else is using the CPU).
top_consumers() {
  if [ -n "${UITEST_FAKE_TOP:-}" ]; then printf '%s\n' "$UITEST_FAKE_TOP"; return; fi
  ps -Ao pcpu,comm -r | sed 1d | head -3 | awk '{ p = $1; $1 = ""; sub(/^ /, ""); n = split($0, a, "/"); print p " " a[n] }'
}

get_free_gb() {
  if [ -n "${UITEST_FAKE_FREE_GB:-}" ]; then echo "$UITEST_FAKE_FREE_GB"; return; fi
  df -Pk "$HOME" | awk 'NR==2 {printf "%.1f", $4 / 1048576}'
}

# float_gt A B: A > B
float_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

xcodebuild_pids() {
  if [ -n "${UITEST_FAKE_XCODEBUILD:-}" ]; then
    [ "$UITEST_FAKE_XCODEBUILD" = "none" ] || echo "$UITEST_FAKE_XCODEBUILD"
    return
  fi
  # Only real builds and test runs: other tools call `xcodebuild -sdk ... -find clang` or `-version` for a split second.
  local pid
  for pid in $(pgrep -x xcodebuild 2>/dev/null); do
    case " $(ps -o args= -p "$pid" 2>/dev/null) " in
      *" -scheme "* | *" -project "* | *" -workspace "* | *" -target "* | *" -xctestrun "*) echo "$pid" ;;
    esac
  done
}

# is_descendant PID ROOT: PID is ROOT or runs somewhere below it.
is_descendant() {
  local pid=$1 root=$2 hops=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 30 ]; do
    [ "$pid" = "$root" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  return 1
}

# foreign_xcodebuild_pids: xcodebuild processes that are not ours (not below this script).
foreign_xcodebuild_pids() {
  local pid
  for pid in $(xcodebuild_pids); do
    is_descendant "$pid" "$$" || echo "$pid"
  done
}

# booted_udids: the simulators that are booted right now.
booted_udids() {
  if [ -n "${UITEST_FAKE_BOOTED:-}" ]; then
    # shellcheck disable=SC2086
    [ "$UITEST_FAKE_BOOTED" = "none" ] || printf '%s\n' $UITEST_FAKE_BOOTED
    return
  fi
  local json
  json=$(run_timeout 20 xcrun simctl list -j devices) || return 0
  printf '%s' "$json" | python3 -I "$PY" sim-booted
}

# run_timeout SECONDS CMD...: stdout passes through; 124 when it ran out of time.
run_timeout() {
  local secs=$1 pid watcher rc
  shift
  "$@" &
  pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid"
  rc=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}

# ---- Preflight ---------------------------------------------------------------------------------------------------

# preflight: 0 when the machine is fit to run on; otherwise 1 with PREFLIGHT_REASON set (one line).
PREFLIGHT_REASON=""
PREFLIGHT_IDLE=""
preflight() {
  local free idle pids
  PREFLIGHT_REASON=""
  PREFLIGHT_IDLE=""
  if [ ! -e "$DEVICES_DIR" ]; then
    PREFLIGHT_REASON="CoreSimulator Devices directory is missing or its symlink target is gone: $DEVICES_DIR"
    return 1
  fi
  if [ ! -d "$DEVICES_DIR" ] || [ ! -w "$DEVICES_DIR" ]; then
    PREFLIGHT_REASON="CoreSimulator Devices directory is not a writable directory: $DEVICES_DIR"
    return 1
  fi
  free=$(get_free_gb)
  if float_gt "$MIN_FREE_GB" "$free"; then
    PREFLIGHT_REASON="only ${free} GB free disk, need ${MIN_FREE_GB} GB"
    return 1
  fi
  pids=$(xcodebuild_pids | tr '\n' ' ')
  if [ -n "${pids// /}" ]; then
    PREFLIGHT_REASON="another xcodebuild is running (pid ${pids% })"
    return 1
  fi
  idle=$(get_idle)
  PREFLIGHT_IDLE=$idle
  if [ -z "$idle" ]; then
    PREFLIGHT_REASON="could not read the CPU usage from top"
    return 1
  fi
  if float_gt "$MIN_IDLE_PCT" "$idle"; then
    PREFLIGHT_REASON="CPU is only ${idle}% idle, need ${MIN_IDLE_PCT}% (busiest: $(top_consumers | head -3 | tr '\n' ',' | sed 's/,$//; s/,/, /g'))"
    return 1
  fi
  if [ -z "${UITEST_SKIP_XCODE_CHECK:-}" ]; then
    if ! run_timeout 20 xcodebuild -version >/dev/null 2>&1; then
      PREFLIGHT_REASON="xcodebuild did not answer within 20 s"
      return 1
    fi
    if ! run_timeout 20 xcrun simctl list -j devicetypes >/dev/null 2>&1; then
      PREFLIGHT_REASON="simctl did not answer within 20 s"
      return 1
    fi
  fi
  return 0
}

# Mid-run check, called every WATCHDOG_INTERVAL seconds; returns 1 (abort the run as invalid) when
#  - free disk is under ABORT_FREE_GB for three checks in a row, or
#  - an xcodebuild that is not ours is running, or a simulator that was not booted at the start and is not one of
#    ours is booted, for two checks in a row.
# CPU idle is not checked here: while the tests run, we are what uses the CPU. Load average is not used anywhere.
WD_DISK_BAD=0
WD_FOREIGN_BAD=0
WD_REASON=""
BASELINE_BOOTED=""   # UDIDs booted when the run started (other projects' simulators): ignored
RESERVED_UDIDS=""    # our own simulators
watchdog_step() {
  local free foreign u
  free=$(get_free_gb)
  if float_gt "$ABORT_FREE_GB" "$free"; then
    WD_DISK_BAD=$((WD_DISK_BAD + 1))
    WD_REASON="free disk fell to ${free} GB (under ${ABORT_FREE_GB} GB)"
  else
    WD_DISK_BAD=0
  fi
  foreign=$(foreign_xcodebuild_pids | tr '\n' ' ')
  if [ -n "${foreign// /}" ]; then
    WD_REASON="another xcodebuild appeared (pid ${foreign% })"
  else
    for u in $(booted_udids); do
      case " $BASELINE_BOOTED $RESERVED_UDIDS " in
        *" $u "*) ;;
        *) foreign="$u"; WD_REASON="a simulator that is not ours was booted ($u)"; break ;;
      esac
    done
  fi
  if [ -n "${foreign// /}" ]; then WD_FOREIGN_BAD=$((WD_FOREIGN_BAD + 1)); else WD_FOREIGN_BAD=0; fi
  [ "$WD_DISK_BAD" -lt 3 ] && [ "$WD_FOREIGN_BAD" -lt 2 ]
}

# ---- Machine-wide lock -------------------------------------------------------------------------------------------

HAVE_LOCK=0

lock_holder() {
  local pid project tier started
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  project=$(cat "$LOCK_DIR/project" 2>/dev/null)
  tier=$(cat "$LOCK_DIR/tier" 2>/dev/null)
  started=$(cat "$LOCK_DIR/started" 2>/dev/null)
  echo "pid ${pid:-?}, project ${project:-?}, tier ${tier:-?}, since ${started:-?}"
}

# lock_acquire: 0 got it; 1 held by a live process (LOCK_REASON says who).
LOCK_REASON=""
lock_acquire() {
  local tier=$1 pid
  mkdir -p "$(dirname "$LOCK_DIR")"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -z "$pid" ]; then
      # The holder is between mkdir and writing its pid file.
      sleep 1
      pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    fi
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      LOCK_REASON="the machine lock is held by $(lock_holder)"
      return 1
    fi
    log "stale lock ($(lock_holder)): that process is gone, taking over"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_REASON="lost the race for the machine lock to $(lock_holder)"
      return 1
    fi
  fi
  echo "$$" >"$LOCK_DIR/pid"
  echo "$PROJECT" >"$LOCK_DIR/project"
  echo "$tier" >"$LOCK_DIR/tier"
  now_utc >"$LOCK_DIR/started"
  HAVE_LOCK=1
  return 0
}

lock_release() {
  if [ "$HAVE_LOCK" = 1 ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  HAVE_LOCK=0
}

# ---- Planning: which tests, which simulators ---------------------------------------------------------------------

# Test entries: "Class/testName" lines, comments and blanks ignored.
read_list() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }

# Every test function in a UI test source file, as BoatARUITests/<name> (they are all extensions of one class).
file_tests() {
  grep -o 'func test[A-Za-z0-9_]*' "$REPO_ROOT/BoatARUITests/$1" | sed "s|func |BoatARUITests/|"
}

# map_changed_paths MAPFILE < paths: the tests mapped from those paths, one per line, or the single word ALL.
# Map lines: "<glob> <target>[,<target>...]"; a target is `file:<Source.swift>`, `Class/test` or `all`. The glob is a
# shell pattern in which `*` also matches `/`. A path matching nothing in the map adds nothing (smoke covers it).
map_changed_paths() {
  local map=$1 path glob targets target rest
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r line; do
      glob=${line%%[[:space:]]*}
      rest=${line#"$glob"}
      targets=${rest//[[:space:]]/}
      # shellcheck disable=SC2254
      case "$path" in
        $glob)
          for target in ${targets//,/ }; do
            case "$target" in
              all) echo ALL ;;
              file:*) file_tests "${target#file:}" ;;
              *) echo "$target" ;;
            esac
          done
          ;;
      esac
    done < <(read_list "$map")
  done
}

# ---- Simulators --------------------------------------------------------------------------------------------------

SIM_UDID=""
# sim_lookup "kind|name|type|runtime": sets SIM_UDID to the reserved simulator's UDID, or "" when there is none.
sim_lookup() {
  local spec=$1 name runtime json
  IFS='|' read -r _ name _ runtime <<EOF
$spec
EOF
  SIM_UDID=""
  [ -n "${UITEST_SKIP_SIMCTL:-}" ] && return 0
  json=$(run_timeout 60 xcrun simctl list -j devices) || return 1
  SIM_UDID=$(printf '%s' "$json" | python3 -I "$PY" sim-find --name "$name" --runtime-version "$runtime")
}

# sim_ensure SPEC: finds the reserved simulator or creates it. Never touches any other simulator.
sim_ensure() {
  local spec=$1 name type runtime catalog ids
  IFS='|' read -r _ name type runtime <<EOF
$spec
EOF
  sim_lookup "$spec" || return 1
  [ -n "$SIM_UDID" ] && return 0
  log "creating simulator \"$name\" ($type, iOS $runtime)"
  catalog=$(run_timeout 60 xcrun simctl list -j runtimes devicetypes) || return 1
  ids=$(printf '%s' "$catalog" | python3 -I "$PY" sim-spec --type-name "$type" --runtime-version "$runtime") || return 1
  # shellcheck disable=SC2086
  SIM_UDID=$(run_timeout 120 xcrun simctl create "$name" $ids) || return 1
  [ -n "$SIM_UDID" ]
}

# ---- Results -----------------------------------------------------------------------------------------------------

prune_results() {
  local root=$1 keep=$2 dir count=0
  [ -n "$root" ] && [ -d "$root" ] || return 0
  # Newest first: the names start with a UTC timestamp.
  for dir in $(ls -1d "$root"/[0-9]*T[0-9]*Z-* 2>/dev/null | sort -r); do
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then rm -rf "$dir"; fi
  done
}

# ---- Argument parsing --------------------------------------------------------------------------------------------

TIER=""
BASE_REF=origin/main
ONLY_TESTS=()
DRY_RUN=0
WAIT_MIN=0
KEEP_BOOTED=0
BOTH=0
CHAOS=0
CHAOS_SEED=""
LAST_TIER=""

HOLD_CMD=()
parse_args() {
  [ $# -ge 1 ] || { usage >&2; exit 64; }
  TIER=$1
  shift
  case "$TIER" in
    smoke | full | chaos | perf | only | changed | last | status | hold | selftest) ;;
    -h | --help | help) usage; exit 0 ;;
    *) echo "unknown tier: $TIER" >&2; usage >&2; exit 64 ;;
  esac
  while [ $# -gt 0 ]; do
    if [ "$TIER" = hold ] && [ "$1" = -- ]; then
      shift
      HOLD_CMD=("$@")
      break
    fi
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --keep-booted) KEEP_BOOTED=1 ;;
      --both) BOTH=1 ;;
      --chaos) CHAOS=1 ;;
      --seed)
        [ $# -ge 2 ] && [ "$2" -ge 0 ] 2>/dev/null || { echo "--seed needs a number" >&2; exit 64; }
        CHAOS_SEED=$2
        shift
        ;;
      --wait)
        [ $# -ge 2 ] && [ "$2" -ge 0 ] 2>/dev/null || { echo "--wait needs a number of minutes" >&2; exit 64; }
        WAIT_MIN=$2
        shift
        ;;
      --results-dir)
        [ $# -ge 2 ] || { echo "--results-dir needs a path" >&2; exit 64; }
        RESULTS_ROOT=$2
        shift
        ;;
      -h | --help) usage; exit 0 ;;
      -*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
      *)
        case "$TIER" in
          only) ONLY_TESTS+=("$1") ;;
          changed) BASE_REF=$1 ;;
          last) LAST_TIER=$1 ;;
          *) echo "unexpected argument: $1" >&2; exit 64 ;;
        esac
        ;;
    esac
    shift
  done
  if [ "$TIER" = hold ] && [ ${#HOLD_CMD[@]} -eq 0 ]; then
    echo "hold needs a command after --" >&2
    exit 64
  fi
  if [ "$TIER" = only ] && [ ${#ONLY_TESTS[@]} -eq 0 ]; then
    echo "only needs at least one Class/testName" >&2
    exit 64
  fi
  [ "$TIER" = chaos ] && CHAOS=1
  if [ -n "$CHAOS_SEED" ] && [ "$CHAOS" = 0 ]; then
    echo "--seed needs the chaos tier or --chaos" >&2
    exit 64
  fi
}

# ---- Plan --------------------------------------------------------------------------------------------------------

PLAN_SIMS=()          # SIM_* specs
PLAN_TESTS=()         # "Class/test" entries; empty means every UI test
PLAN_RELEASE=0
PLAN_NOTES=()
DD_NAME=smoke

make_plan() {
  local entry
  PLAN_SIMS=("$SIM_PRO")
  PLAN_TESTS=()
  PLAN_RELEASE=0
  case "$TIER" in
    smoke)
      while IFS= read -r entry; do PLAN_TESTS+=("$entry"); done < <(read_list "$SMOKE_FILE")
      ;;
    full)
      PLAN_SIMS=("$SIM_PRO" "$SIM_DUO")
      PLAN_RELEASE=1
      DD_NAME=full
      ;;
    chaos)
      PLAN_SIMS=("$SIM_PRO" "$SIM_DUO")
      DD_NAME=chaos
      while IFS= read -r entry; do PLAN_TESTS+=("$entry"); done < <(read_list "$CHAOS_FILE")
      ;;
    perf)
      DD_NAME=perf
      for entry in $PERF_TESTS; do PLAN_TESTS+=("BoatARUITests/$entry"); done
      ;;
    only)
      for entry in "${ONLY_TESTS[@]}"; do PLAN_TESTS+=("$entry"); done
      [ "$BOTH" = 1 ] && PLAN_SIMS=("$SIM_PRO" "$SIM_DUO")
      ;;
    changed)
      plan_changed
      ;;
  esac
}

plan_changed() {
  local base=$BASE_REF merge_base files mapped entry
  git -C "$REPO_ROOT" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1 \
    || git -C "$REPO_ROOT" fetch -q origin "${base#origin/}" >/dev/null 2>&1
  if ! git -C "$REPO_ROOT" rev-parse --verify -q "$base^{commit}" >/dev/null 2>&1; then
    PLAN_NOTES+=("base ref $base not found: running smoke only")
    while IFS= read -r entry; do PLAN_TESTS+=("$entry"); done < <(read_list "$SMOKE_FILE")
    return
  fi
  merge_base=$(git -C "$REPO_ROOT" merge-base "$base" HEAD 2>/dev/null || echo "$base")
  files=$(git -C "$REPO_ROOT" diff --name-only "$merge_base" HEAD)
  mapped=$(printf '%s\n' "$files" | map_changed_paths "$MAP_FILE")
  PLAN_NOTES+=("changed against $base: $(printf '%s\n' "$files" | grep -c .) file(s)")
  if printf '%s\n' "$mapped" | grep -qx ALL; then
    PLAN_NOTES+=("a changed path maps to every test")
    return
  fi
  while IFS= read -r entry; do PLAN_TESTS+=("$entry"); done < <({ printf '%s\n' "$mapped"; read_list "$SMOKE_FILE"; } | grep . | awk '!seen[$0]++')
}

# chaos_env: when chaos is on, the opt-in switch (and the seed and action count, from --seed or the caller's
# environment) as TEST_RUNNER_ variables: xcodebuild hands those to the test runner without the prefix. Exported, so
# every xcodebuild this script starts passes them on.
chaos_env() {
  local seed
  [ "$CHAOS" = 1 ] || return 0
  export TEST_RUNNER_BOATAR_CHAOS=1
  seed=${CHAOS_SEED:-${BOATAR_CHAOS_SEED:-}}
  if [ -n "$seed" ]; then export TEST_RUNNER_BOATAR_CHAOS_SEED=$seed; fi
  if [ -n "${BOATAR_CHAOS_ACTIONS:-}" ]; then export TEST_RUNNER_BOATAR_CHAOS_ACTIONS=$BOATAR_CHAOS_ACTIONS; fi
  NOTES+=("chaos: on, seed ${seed:-random}${BOATAR_CHAOS_ACTIONS:+, $BOATAR_CHAOS_ACTIONS actions}")
}

# ---- Execution state ---------------------------------------------------------------------------------------------

RUN_DIR=""
WORK=""
LOG=""
DD=""
WD_PID=""
FINALIZED=0
VERDICT=""
STARTED=""
IDLE_START=""
TOP_START=""
SIM_INFO=()
RESULT_FILES=()
PERF_LINES=()
NOTES=()
BOOTED_UDIDS=()
UDID_pro=""
# shellcheck disable=SC2034  # read through eval "udid=\$UDID_$kind"
UDID_duo=""

git_commit() { git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown; }
git_branch() {
  echo "${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}}"
}

kill_xcodebuild() {
  local pid
  pid=$(cat "$WORK/xcodebuild.pid" 2>/dev/null)
  [ -n "$pid" ] || return 0
  pkill -TERM -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
}

start_watchdog() {
  (
    while sleep "$WATCHDOG_INTERVAL"; do
      if ! watchdog_step; then
        echo "$WD_REASON" >"$WORK/invalid"
        kill_xcodebuild
        break
      fi
    done
  ) >/dev/null 2>&1 &
  WD_PID=$!
}

stop_watchdog() {
  if [ -n "$WD_PID" ]; then
    kill "$WD_PID" 2>/dev/null
    wait "$WD_PID" 2>/dev/null
    WD_PID=""
  fi
}

# finalize VERDICT: writes summary.json/summary.md, the latest-<tier> link, prunes old runs. Once.
finalize() {
  local verdict=$1 args r s p n
  [ "$FINALIZED" = 0 ] && [ -n "$RUN_DIR" ] || return 0
  FINALIZED=1
  VERDICT=$verdict
  args=(--out-dir "$RUN_DIR" --commit "$(git_commit)" --branch "$(git_branch)" --tier "$TIER"
    --started "$STARTED" --finished "$(now_utc)" --verdict "$verdict")
  for r in "${RESULT_FILES[@]}"; do args+=(--result "$r"); done
  for s in "${SIM_INFO[@]}"; do args+=(--sim "$s"); done
  for p in "${PERF_LINES[@]}"; do args+=(--perf-line "$p"); done
  for n in "${NOTES[@]}"; do args+=(--note "$n"); done
  [ -d "$RUN_DIR/crashes" ] && args+=(--crashes-dir "$RUN_DIR/crashes")
  [ -n "$IDLE_START" ] && args+=(--idle-start "$IDLE_START")
  while IFS= read -r n; do [ -n "$n" ] && args+=(--top-start "$n"); done <<EOF
$TOP_START
EOF
  while IFS= read -r n; do [ -n "$n" ] && args+=(--top-end "$n"); done <<EOF
$(top_consumers)
EOF
  python3 -I "$PY" summarize "${args[@]}" || log "could not write summary files"
  ln -sfn "$(basename "$RUN_DIR")" "$RESULTS_ROOT/latest-$TIER"
  prune_results "$RESULTS_ROOT" "$KEEP_RUNS"
  # Whatever the verdict (CI reads the "results:" line to find the folder).
  cat "$RUN_DIR/summary.md" 2>/dev/null
  echo "results: $RUN_DIR"
}

cleanup() {
  local rc=$? u
  trap - EXIT INT TERM
  stop_watchdog
  [ -n "$WORK" ] && kill_xcodebuild
  if [ "$FINALIZED" = 0 ] && [ -n "$RUN_DIR" ]; then
    NOTES+=("interrupted before it finished")
    finalize invalid
  fi
  if [ "$KEEP_BOOTED" = 0 ]; then
    for u in "${BOOTED_UDIDS[@]}"; do xcrun simctl shutdown "$u" >/dev/null 2>&1; done
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
  lock_release
  exit "$rc"
}

# run_xcodebuild ARGS...: appends to the log, keeps the pid where the watchdog can find it.
run_xcodebuild() {
  local rc
  echo "+ xcodebuild $*" >>"$LOG"
  # The build stamps this into the app's Info.plist (GitSHA): git itself can fail to answer inside the build.
  GIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true) xcodebuild "$@" >>"$LOG" 2>&1 &
  echo $! >"$WORK/xcodebuild.pid"
  wait $!
  rc=$?
  rm -f "$WORK/xcodebuild.pid"
  return "$rc"
}

invalidated() { [ -f "$WORK/invalid" ]; }

# extract_result NAME RESULT_BUNDLE: reads one simulator run's result bundle; sets EXTRACT_OUT to the parsed result
# file (empty when there is none) and exports the failed tests' screenshots. Not for use inside $( ).
EXTRACT_OUT=""
extract_result() {
  local name=$1 bundle=$2 slug out
  EXTRACT_OUT=""
  slug=$(printf '%s' "$name" | tr -c 'A-Za-z0-9\n' _)
  out="$WORK/result-$slug-$(date +%s).json"
  [ -d "$bundle" ] || return 1
  rm -rf "$WORK/x"
  mkdir -p "$WORK/x"
  run_timeout 180 xcrun xcresulttool get test-results summary --path "$bundle" --compact >"$WORK/x/summary.json" 2>>"$LOG"
  run_timeout 180 xcrun xcresulttool get test-results tests --path "$bundle" --compact >"$WORK/x/tests.json" 2>>"$LOG"
  python3 -I "$PY" parse-result --sim "$name" --summary "$WORK/x/summary.json" --tests "$WORK/x/tests.json" --out "$out" || return 1
  if [ "$(python3 -I "$PY" get --file "$out" --key failed)" -gt 0 ]; then
    # Not --only-failures: Xcode 27 marks no attachment as belonging to a failure. Each failed test's attachments are
    # exported on their own (the screen recordings are 8 MB each); the report script picks the screenshots out.
    local id n=0 exported=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      n=$((n + 1))
      if run_timeout 300 xcrun xcresulttool export attachments --path "$bundle" --test-id "$id" --output-path "$WORK/x/attach/$n" >>"$LOG" 2>&1; then
        exported=$((exported + 1))
      fi
    done <<EOF2
$(python3 -I "$PY" failed-tests --file "$out" | sort -u)
EOF2
    if [ "$exported" -gt 0 ]; then
      python3 -I "$PY" parse-result --sim "$name" --summary "$WORK/x/summary.json" --tests "$WORK/x/tests.json" \
        --attach-dir "$WORK/x/attach" --failures-dir "$RUN_DIR/failures" --out "$out"
    else
      NOTES+=("could not export failure screenshots from the result bundle ($name)")
    fi
  fi
  if [ -n "${UITEST_EXPORT_ATTACHMENTS:-}" ]; then
    # Everything the tests attached (screenshot tours), kept with the run.
    run_timeout 600 xcrun xcresulttool export attachments --path "$bundle" --output-path "$RUN_DIR/attachments/$slug" >>"$LOG" 2>&1 \
      || NOTES+=("could not export attachments ($name)")
  fi
  RESULT_FILES+=("$out")
  EXTRACT_OUT=$out
}

TESTS_FAILED=0
INFRA_PROBLEM=0
# Nothing here puts a time limit on a test, and chaos runs are long: keep Xcode's per-test timeouts off for them.
TEST_TIMEOUT_ARGS=()

# run_tests NAME UDID [-only-testing args...] -- run test-without-building and record the result.
run_tests() {
  local name=$1 udid=$2 bundle out rc total
  shift 2
  bundle="$WORK/$(printf '%s' "$name" | tr -c 'A-Za-z0-9\n' _).xcresult"
  rm -rf "$bundle"
  log "testing on $name"
  run_xcodebuild test-without-building -scheme "$SCHEME" -destination "id=$udid" -derivedDataPath "$DD" \
    -resultBundlePath "$bundle" -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO \
    ${TEST_TIMEOUT_ARGS[@]+"${TEST_TIMEOUT_ARGS[@]}"} "$@"
  rc=$?
  invalidated && return 75
  extract_result "$name" "$bundle"
  out=$EXTRACT_OUT
  if [ ! -f "$out" ]; then
    NOTES+=("$name: xcodebuild exited $rc and left no readable result (see xcodebuild.log)")
    INFRA_PROBLEM=1
    return 0
  fi
  total=$(python3 -I "$PY" get --file "$out" --key total)
  if [ "$rc" -ne 0 ] && [ "${total:-0}" -eq 0 ]; then
    NOTES+=("$name: xcodebuild exited $rc and ran no tests (see xcodebuild.log)")
    INFRA_PROBLEM=1
  fi
  if [ "$(python3 -I "$PY" get --file "$out" --key failed)" -gt 0 ]; then TESTS_FAILED=1; fi
  rm -rf "$bundle"
  return 0
}

print_plan() {
  local spec name entry
  echo "tier:        $TIER"
  echo "commit:      $(git_commit) ($(git_branch))"
  for spec in "${PLAN_SIMS[@]}"; do
    IFS='|' read -r _ name _ _ <<EOF
$spec
EOF
    sim_lookup "$spec" >/dev/null 2>&1
    echo "simulator:   $name ($([ -n "$SIM_UDID" ] && echo "$SIM_UDID" || echo "would be created"))"
  done
  [ "$CHAOS" = 1 ] && echo "chaos:       on, seed ${CHAOS_SEED:-${BOATAR_CHAOS_SEED:-random}}${BOATAR_CHAOS_ACTIONS:+, $BOATAR_CHAOS_ACTIONS actions}"
  [ "$PLAN_RELEASE" = 1 ] && echo "also:        Release build (generic/platform=iOS, no signing)"
  if [ ${#PLAN_TESTS[@]} -eq 0 ]; then
    echo "tests:       every UI test (-only-testing:$UI_TARGET)"
  else
    echo "tests:       ${#PLAN_TESTS[@]}"
    for entry in "${PLAN_TESTS[@]}"; do echo "  $entry"; done
  fi
  for entry in ${PLAN_NOTES[@]+"${PLAN_NOTES[@]}"}; do echo "note:        $entry"; done
  echo "lock:        $LOCK_DIR ($([ -d "$LOCK_DIR" ] && lock_holder || echo free))"
  echo "cpu/disk:    $(get_idle)% idle (need $MIN_IDLE_PCT%), $(get_free_gb) GB free (need $MIN_FREE_GB)"
  echo "results:     $RESULTS_ROOT/<UTC timestamp>-<sha>-$TIER"
}

# ---- Crash reports -----------------------------------------------------------------------------------------------

CRASH_SINCE=0
CRASH_COUNT=0

# crash_dirs: the folders searched for the app's .ips reports (and their Retired/ subfolders, which the finder adds
# itself): the host's, and each reserved simulator's own. UITEST_CRASH_DIRS (colon-separated) replaces the list.
crash_dirs() {
  local u
  if [ -n "${UITEST_CRASH_DIRS:-}" ]; then printf '%s\n' "$UITEST_CRASH_DIRS" | tr ':' '\n'; return; fi
  echo "$HOME/Library/Logs/DiagnosticReports"
  for u in $RESERVED_UDIDS; do
    echo "$DEVICES_DIR/$u/data/Library/Logs/CrashReporter"
    echo "$DEVICES_DIR/$u/data/Library/Logs/DiagnosticReports"
  done
}

# collect_crashes: copies the app's .ips reports newer than CRASH_SINCE into $RUN_DIR/crashes; sets CRASH_COUNT.
collect_crashes() {
  local args=() d
  CRASH_COUNT=0
  [ -n "$RUN_DIR" ] || return 0
  while IFS= read -r d; do [ -n "$d" ] && args+=(--dir "$d"); done <<EOF
$(crash_dirs)
EOF
  CRASH_COUNT=$(python3 -I "$PY" find-crashes --since "$CRASH_SINCE" --dest "$RUN_DIR/crashes" --bundle-id "$APP_BUNDLE_ID" \
    --process "$APP_PROCESS" ${args[@]+"${args[@]}"}) || CRASH_COUNT=0
  [ "$CRASH_COUNT" -gt 0 ] 2>/dev/null || CRASH_COUNT=0
  if [ "$CRASH_COUNT" -gt 0 ]; then
    NOTES+=("the app crashed $CRASH_COUNT time(s) during the run (reports in crashes/)")
    log "the app crashed $CRASH_COUNT time(s): see $RUN_DIR/crashes"
  fi
}

# decide_verdict: sets VERDICT_DECIDED from what the tests, the infrastructure and the crash search found.
# A crash fails the run even when every test passed.
VERDICT_DECIDED=""
decide_verdict() {
  if [ "$TESTS_FAILED" = 1 ]; then VERDICT_DECIDED=fail
  elif [ "$CRASH_COUNT" -gt 0 ]; then VERDICT_DECIDED=fail
  elif [ "$INFRA_PROBLEM" = 1 ]; then VERDICT_DECIDED=invalid
  else VERDICT_DECIDED=pass
  fi
}

# ---- Main run ----------------------------------------------------------------------------------------------------

only_testing_args() {
  ONLY_ARGS=()
  local entry
  if [ ${#PLAN_TESTS[@]} -eq 0 ]; then
    ONLY_ARGS=("-only-testing:$UI_TARGET")
    return
  fi
  for entry in "${PLAN_TESTS[@]}"; do
    case "$entry" in
      */*/*) ONLY_ARGS+=("-only-testing:$entry") ;;
      *) ONLY_ARGS+=("-only-testing:$UI_TARGET/$entry") ;;
    esac
  done
}

wait_for_machine() {
  local deadline reason
  deadline=$(($(date +%s) + WAIT_MIN * 60))
  while :; do
    if lock_acquire "$TIER"; then
      if preflight; then return 0; fi
      reason=$PREFLIGHT_REASON
      lock_release
    else
      reason=$LOCK_REASON
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "BUSY (not a test failure): $reason"
      return 75
    fi
    log "waiting: $reason"
    sleep 15
  done
}

# hold: the lock and the preflight of a run, for an arbitrary command. The lock is released by the trap however we end.
run_hold() {
  local rc
  trap lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  wait_for_machine || exit 75
  log "lock held for: ${HOLD_CMD[*]}"
  "${HOLD_CMD[@]}"
  rc=$?
  lock_release
  log "lock released (command exit $rc)"
  exit "$rc"
}

run_tier() {
  local spec kind name type runtime ts rc entry udid first_udid
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  wait_for_machine || exit 75

  ts=$(date -u +%Y%m%dT%H%M%SZ)
  RUN_DIR="$RESULTS_ROOT/$ts-$(git_commit)-$TIER"
  mkdir -p "$RUN_DIR/failures" "$CACHE_ROOT"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/ui-test.XXXXXX")
  LOG="$RUN_DIR/xcodebuild.log"
  : >"$LOG"
  STARTED=$(now_utc)
  CRASH_SINCE=$(date +%s)
  chaos_env
  for entry in ${PLAN_NOTES[@]+"${PLAN_NOTES[@]}"}; do NOTES+=("$entry"); done
  log "run folder: $RUN_DIR"

  DD="$CACHE_ROOT/dd-$DD_NAME"
  if float_gt "$CLEAN_DD_FREE_GB" "$(get_free_gb)"; then
    log "under ${CLEAN_DD_FREE_GB} GB free: deleting $DD"
    rm -rf "$DD"
    NOTES+=("DerivedData deleted (low disk): the build ran from scratch")
  fi

  # What the machine was doing when we started, kept in the summary so a suspicious result can be judged afterwards.
  IDLE_START=$PREFLIGHT_IDLE
  TOP_START=$(top_consumers)
  BASELINE_BOOTED=$(booted_udids | tr '\n' ' ')

  for spec in "${PLAN_SIMS[@]}"; do
    IFS='|' read -r kind name type runtime <<EOF
$spec
EOF
    if ! sim_ensure "$spec"; then
      NOTES+=("could not find or create \"$name\" ($type, iOS $runtime)")
      finalize build-failed
      exit 2
    fi
    eval "UDID_$kind=$SIM_UDID"
    SIM_INFO+=("$name|$SIM_UDID|iOS $runtime")
    BOOTED_UDIDS+=("$SIM_UDID")
    RESERVED_UDIDS="$RESERVED_UDIDS $SIM_UDID"
  done
  first_udid=$UDID_pro
  start_watchdog

  log "building for testing"
  run_xcodebuild build-for-testing -scheme "$SCHEME" -destination "id=$first_udid" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO
  rc=$?
  if invalidated; then
    NOTES+=("aborted by the watchdog: $(cat "$WORK/invalid")")
    finalize invalid
    exit 75
  fi
  if [ "$rc" -ne 0 ]; then
    NOTES+=("build-for-testing failed (exit $rc): see xcodebuild.log")
    finalize build-failed
    exit 2
  fi
  if [ "$PLAN_RELEASE" = 1 ]; then
    log "building the Release configuration"
    run_xcodebuild -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' \
      -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO
    rc=$?
    if invalidated; then
      NOTES+=("aborted by the watchdog: $(cat "$WORK/invalid")")
      finalize invalid
      exit 75
    fi
    if [ "$rc" -ne 0 ]; then
      NOTES+=("Release build failed (exit $rc): see xcodebuild.log")
      finalize build-failed
      exit 2
    fi
  fi

  [ "$CHAOS" = 1 ] && TEST_TIMEOUT_ARGS=(-test-timeouts-enabled NO)
  only_testing_args
  if [ "$TIER" = perf ]; then
    run_perf
  else
    for spec in "${PLAN_SIMS[@]}"; do
      IFS='|' read -r kind name _ _ <<EOF
$spec
EOF
      eval "udid=\$UDID_$kind"
      run_tests "$name" "$udid" "${ONLY_ARGS[@]}"
      if invalidated; then break; fi
    done
  fi

  stop_watchdog
  if invalidated; then
    NOTES+=("aborted by the watchdog: $(cat "$WORK/invalid")")
    finalize invalid
    exit 75
  fi
  collect_crashes
  decide_verdict
  finalize "$VERDICT_DECIDED"
  case "$VERDICT" in pass) exit 0 ;; fail) exit 1 ;; *) exit 75 ;; esac
}

run_perf() {
  local test first=1 bundle metrics out sim_name line
  IFS='|' read -r _ sim_name _ _ <<EOF
$SIM_PRO
EOF
  for test in $PERF_TESTS; do
    if [ "$first" = 0 ]; then
      log "pausing ${PERF_GAP} s before the next performance test"
      sleep "$PERF_GAP"
    fi
    first=0
    bundle="$WORK/perf-$test.xcresult"
    rm -rf "$bundle"
    log "performance: $test"
    TEST_RUNNER_BOATAR_PERF=1 run_xcodebuild test-without-building -scheme "$SCHEME" -destination "id=$UDID_pro" \
      -derivedDataPath "$DD" -resultBundlePath "$bundle" -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO \
      "-only-testing:$UI_TARGET/BoatARUITests/$test"
    invalidated && return
    extract_result "$sim_name" "$bundle"
    out=$EXTRACT_OUT
    if [ -f "$out" ] && [ "$(python3 -I "$PY" get --file "$out" --key failed)" -gt 0 ]; then TESTS_FAILED=1; fi
    if [ ! -f "$out" ]; then INFRA_PROBLEM=1; fi
    metrics="$WORK/metrics-$test.json"
    if run_timeout 180 xcrun xcresulttool get test-results metrics --path "$bundle" --compact >"$metrics" 2>>"$LOG"; then
      line=$(python3 -I "$PY" perf-line --metrics "$metrics" --test "$test" --date "$(date -u +%Y-%m-%d)" --commit "$(git_commit)") \
        && { PERF_LINES+=("$line"); mkdir -p "$(dirname "$PERF_HISTORY")"; printf '%s\n' "$line" >>"$PERF_HISTORY"; } \
        || NOTES+=("$test: no CPU/memory numbers in the result")
    else
      NOTES+=("$test: could not read performance metrics")
    fi
    rm -rf "$bundle"
  done
}

# ---- last / status -----------------------------------------------------------------------------------------------

cmd_last() {
  local dir
  if [ -n "$LAST_TIER" ] && [ -f "$RESULTS_ROOT/latest-$LAST_TIER/summary.md" ]; then
    dir="$RESULTS_ROOT/latest-$LAST_TIER"
  else
    [ -n "$LAST_TIER" ] && { echo "no results for tier $LAST_TIER in $RESULTS_ROOT" >&2; return 1; }
    dir=$(ls -1d "$RESULTS_ROOT"/[0-9]*T[0-9]*Z-* 2>/dev/null | sort | tail -1)
    [ -n "$dir" ] || { echo "no results in $RESULTS_ROOT" >&2; return 1; }
  fi
  echo "($dir)"
  cat "$dir/summary.md"
}

cmd_status() {
  local pid
  if [ -d "$LOCK_DIR" ]; then
    pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "lock:        HELD by $(lock_holder)"
    else
      echo "lock:        stale ($(lock_holder)): the next run takes it over"
    fi
  else
    echo "lock:        free ($LOCK_DIR)"
  fi
  echo "cpu idle:    $(get_idle)% (need $MIN_IDLE_PCT%; busiest: $(top_consumers | tr '\n' ',' | sed 's/,$//; s/,/, /g'))"
  echo "load avg:    $(get_load) on $(get_ncpu) CPUs (information only: not used, background daemons inflate it)"
  echo "free disk:   $(get_free_gb) GB (need $MIN_FREE_GB)"
  echo "xcodebuild:  $(xcodebuild_pids | tr '\n' ' ' | sed 's/ $//' | sed 's/^$/not running/')"
  if preflight; then echo "preflight:   ok"; else echo "preflight:   would fail: $PREFLIGHT_REASON"; fi
}

# ---- Self-test ---------------------------------------------------------------------------------------------------

ST_PASS=0
ST_FAIL=0
st_check() { # name, expected exit status (0 = condition true), command...
  local name=$1 want=$2 rc
  shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    ST_PASS=$((ST_PASS + 1))
    echo "ok   $name"
  else
    ST_FAIL=$((ST_FAIL + 1))
    echo "FAIL $name (exit $rc, wanted $want)"
  fi
}
st_eq() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    ST_PASS=$((ST_PASS + 1))
    echo "ok   $1"
  else
    ST_FAIL=$((ST_FAIL + 1))
    echo "FAIL $1: wanted [$2], got [$3]"
  fi
}

# Targets in the committed map that name no test (a renamed or deleted test would otherwise silently drop out).
map_target_problems() {
  local t
  for t in $(read_list "$MAP_FILE" | awk '{print $2}' | tr ',' ' '); do
    if [ "$t" = all ]; then continue; fi
    if [ "${t#file:}" != "$t" ]; then
      [ -n "$(file_tests "${t#file:}")" ] || echo "no tests in $t"
    else
      grep -q "func ${t#*/}" "$REPO_ROOT"/BoatARUITests/*.swift || echo "missing $t"
    fi
  done
}

selftest() {
  local T d pid out rc n me
  T=$(mktemp -d "${TMPDIR:-/tmp}/ui-test-selftest.XXXXXX")
  me=$SCRIPT_DIR/ui-test.sh
  echo "selftest in $T"

  # Lock.
  LOCK_DIR="$T/lock"
  st_check "lock: acquire" 0 lock_acquire smoke
  st_eq "lock: holds our pid" "$$" "$(cat "$LOCK_DIR/pid")"
  st_eq "lock: project recorded" "$PROJECT" "$(cat "$LOCK_DIR/project")"
  st_check "lock: a second acquire while held is refused" 1 lock_acquire full
  lock_release
  st_check "lock: released (directory gone)" 1 test -d "$LOCK_DIR"
  ( : ) &
  pid=$!
  wait "$pid"
  mkdir "$LOCK_DIR" && echo "$pid" >"$LOCK_DIR/pid" && echo other >"$LOCK_DIR/project"
  out=$(lock_acquire smoke 2>&1)
  rc=$?
  st_eq "lock: stale lock (dead pid) taken over" 0 "$rc"
  case "$out" in *"stale lock"*) st_eq "lock: takeover is logged" 1 1 ;; *) st_eq "lock: takeover is logged" 1 0 ;; esac
  st_eq "lock: now ours" "$$" "$(cat "$LOCK_DIR/pid")"
  HAVE_LOCK=1
  lock_release
  st_check "lock: released after takeover" 1 test -d "$LOCK_DIR"

  # Preflight.
  d="$T/devices"
  mkdir -p "$d"
  DEVICES_DIR=$d
  UITEST_SKIP_XCODE_CHECK=1
  UITEST_FAKE_IDLE=70.8
  UITEST_FAKE_LOAD=500   # a huge load average with an idle CPU (background daemons) must not matter
  UITEST_FAKE_FREE_GB=50
  UITEST_FAKE_XCODEBUILD=none
  UITEST_FAKE_TOP="221.8 mediaanalysisd
54.0 swift-test"
  st_check "preflight: quiet CPU passes even with load average 500" 0 preflight
  st_eq "preflight: idle recorded" 70.8 "$PREFLIGHT_IDLE"
  UITEST_FAKE_IDLE=12.5
  preflight
  st_eq "preflight: 12.5% idle refused, names the busiest" "CPU is only 12.5% idle, need 40% (busiest: 221.8 mediaanalysisd, 54.0 swift-test)" "$PREFLIGHT_REASON"
  UITEST_FAKE_IDLE=40
  st_check "preflight: exactly the minimum idle passes" 0 preflight
  UITEST_FAKE_FREE_GB=3.2
  preflight
  st_eq "preflight: 3.2 GB free refused" "only 3.2 GB free disk, need 6 GB" "$PREFLIGHT_REASON"
  UITEST_FAKE_FREE_GB=50
  UITEST_FAKE_XCODEBUILD=4242
  preflight
  st_eq "preflight: running xcodebuild refused" "another xcodebuild is running (pid 4242)" "$PREFLIGHT_REASON"
  UITEST_FAKE_XCODEBUILD=none
  ln -s "$T/gone" "$T/dangling"
  DEVICES_DIR="$T/dangling"
  st_check "preflight: dangling Devices symlink refused" 1 preflight
  DEVICES_DIR="$T/missing"
  st_check "preflight: missing Devices directory refused" 1 preflight
  ln -s "$d" "$T/linked"
  DEVICES_DIR="$T/linked"
  st_check "preflight: Devices symlink to a real directory passes" 0 preflight
  chmod 555 "$d"
  DEVICES_DIR=$d
  st_check "preflight: unwritable Devices directory refused" 1 preflight
  chmod 755 "$d"
  DEVICES_DIR=$d

  # Watchdog: disk (three in a row), a foreign xcodebuild or simulator (two in a row); never CPU or load.
  UITEST_FAKE_FREE_GB=1
  WD_DISK_BAD=0
  watchdog_step
  st_eq "watchdog: one low-disk reading tolerated" 1 "$WD_DISK_BAD"
  UITEST_FAKE_FREE_GB=50
  watchdog_step
  st_eq "watchdog: a good reading resets the count" 0 "$WD_DISK_BAD"
  UITEST_FAKE_FREE_GB=1
  watchdog_step && watchdog_step
  st_check "watchdog: third low-disk reading aborts" 1 watchdog_step
  st_eq "watchdog: reason names the disk" "free disk fell to 1 GB (under 2 GB)" "$WD_REASON"
  UITEST_FAKE_FREE_GB=50
  UITEST_FAKE_IDLE=1
  UITEST_FAKE_LOAD=900
  WD_DISK_BAD=0
  UITEST_FAKE_BOOTED=none
  st_check "watchdog: 1% idle and load 900 do not abort a run" 0 watchdog_step
  UITEST_FAKE_IDLE=70.8
  UITEST_FAKE_XCODEBUILD=4242
  WD_FOREIGN_BAD=0
  watchdog_step
  st_eq "watchdog: a foreign xcodebuild is tolerated once" 1 "$WD_FOREIGN_BAD"
  st_check "watchdog: a foreign xcodebuild twice in a row aborts" 1 watchdog_step
  st_eq "watchdog: reason names it" "another xcodebuild appeared (pid 4242)" "$WD_REASON"
  UITEST_FAKE_XCODEBUILD=none
  watchdog_step
  st_eq "watchdog: the count resets when it is gone" 0 "$WD_FOREIGN_BAD"
  sleep 30 &
  st_check "own process tree: a child counts as ours" 0 is_descendant "$!" "$$"
  st_check "own process tree: an unrelated pid is foreign" 1 is_descendant 1 "$$"
  kill $! 2>/dev/null
  BASELINE_BOOTED="AAAA-HSN"
  RESERVED_UDIDS=" PRO-1 DUO-2"
  UITEST_FAKE_BOOTED="AAAA-HSN PRO-1"
  st_check "watchdog: baseline and reserved simulators booted is fine" 0 watchdog_step
  UITEST_FAKE_BOOTED="AAAA-HSN PRO-1 ZZZZ-NEW"
  watchdog_step
  st_check "watchdog: a newly booted foreign simulator twice in a row aborts" 1 watchdog_step
  st_eq "watchdog: reason names the simulator" "a simulator that is not ours was booted (ZZZZ-NEW)" "$WD_REASON"
  UITEST_FAKE_BOOTED=none

  # Changed paths -> tests.
  printf '%s\n' '# comment' 'App/Train*  file:TrainUITests.swift' 'App/CameraScreen.swift  BoatARUITests/testCameraShowsAccuracyPillWhenCompassIsPoor,file:SightlineUITests.swift' \
    'BoatAR.xcodeproj/*  all' >"$T/map.txt"
  out=$(printf '%s\n' App/TrainDetailView.swift | map_changed_paths "$T/map.txt" | tr '\n' ' ')
  case "$out" in *"BoatARUITests/testListShowsTrainsUnderTheBoats"*) st_eq "map: train view -> the train tests" 1 1 ;; *) st_eq "map: train view -> the train tests" 1 0 ;; esac
  out=$(printf '%s\n' App/CameraScreen.swift | map_changed_paths "$T/map.txt" | tr '\n' ' ')
  case "$out" in
    *"testCameraShowsAccuracyPill"*"testListPutsBoatsOutOfSightUnderTheirOwnHeading"*) st_eq "map: explicit test plus file: expansion" 1 1 ;;
    *) st_eq "map: explicit test plus file: expansion" 1 0 ;;
  esac
  st_eq "map: unmapped app file adds nothing (smoke covers it)" "" "$(printf '%s\n' App/Theme.swift | map_changed_paths "$T/map.txt")"
  st_eq "map: project file -> ALL" ALL "$(printf '%s\n' BoatAR.xcodeproj/project.pbxproj | map_changed_paths "$T/map.txt" | head -1)"
  st_eq "map: the committed map's targets all resolve to tests" "" "$(map_target_problems)"
  st_eq "smoke list: every entry is an existing test" "" "$(while IFS= read -r e; do
    grep -q "func ${e#*/}" "$REPO_ROOT"/BoatARUITests/*.swift || echo "missing $e"; done < <(read_list "$SMOKE_FILE"))"

  # Summary generation from canned xcresulttool output.
  mkdir -p "$T/canned/attach"
  cat >"$T/canned/summary.json" <<'EOF'
{"result":"Failed","totalTestCount":3,"passedTests":1,"failedTests":1,"skippedTests":1,"testFailures":[{"testName":"testRowOpensDetailSheet()","failureText":"XCTAssertTrue failed","testIdentifierString":"BoatARUITests/testRowOpensDetailSheet()"}]}
EOF
  cat >"$T/canned/tests.json" <<'EOF'
{"testNodes":[{"nodeType":"UI test bundle","name":"BoatARUITests","children":[{"nodeType":"Test Suite","name":"BoatARUITests","children":[
 {"nodeType":"Test Case","name":"testRowOpensDetailSheet()","nodeIdentifier":"BoatARUITests/testRowOpensDetailSheet()","result":"Failed","children":[
  {"nodeType":"Failure Message","name":"BoatARUITests.swift:228: XCTAssertEqual failed: (\"ANNABEL\") is not equal to (\"ANNABEL K\")"}]},
 {"nodeType":"Test Case","name":"testNoOfflineBannerWhileLive()","nodeIdentifier":"BoatARUITests/testNoOfflineBannerWhileLive()","result":"Passed"}]}]}]}
EOF
  printf 'png' >"$T/canned/attach/shot1.png"
  printf '%s' '[{"testIdentifier":"BoatARUITests/testRowOpensDetailSheet()","attachments":[{"exportedFileName":"shot1.png","isAssociatedWithFailure":true}]}]' >"$T/canned/attach/manifest.json"
  mkdir -p "$T/run"
  python3 -I "$PY" parse-result --sim "BW Test iPhone 18 Pro" --summary "$T/canned/summary.json" --tests "$T/canned/tests.json" \
    --manifest "$T/canned/attach/manifest.json" --attach-dir "$T/canned/attach" --failures-dir "$T/run/failures" --out "$T/res1.json"
  st_eq "parse: failed count" 1 "$(python3 -I "$PY" get --file "$T/res1.json" --key failed)"
  st_eq "parse: total count" 3 "$(python3 -I "$PY" get --file "$T/res1.json" --key total)"
  st_eq "parse: failure screenshot exported" 1 "$(find "$T/run/failures" -name '*.png' | wc -l | tr -d ' ')"
  printf '%s\n' '{"result":"Passed","totalTestCount":2,"passedTests":2,"failedTests":0,"skippedTests":0}' >"$T/canned/summary2.json"
  python3 -I "$PY" parse-result --sim "BW Test iPhone Duo" --summary "$T/canned/summary2.json" --tests /nonexistent --out "$T/res2.json"
  python3 -I "$PY" summarize --out-dir "$T/run" --commit abc1234 --branch chore/x --tier full --started 2026-11-16T10:00:00Z \
    --finished 2026-11-16T10:20:00Z --verdict fail --sim "BW Test iPhone 18 Pro|UDID-1|iOS 27.0" --sim "BW Test iPhone Duo|UDID-2|iOS 27.1" \
    --result "$T/res1.json" --result "$T/res2.json" --note "a note"
  st_eq "summary.json: verdict" fail "$(python3 -I "$PY" get --file "$T/run/summary.json" --key verdict)"
  st_eq "summary.json: failure has file:line" "BoatARUITests.swift:228" "$(python3 -I -c "
import json,sys
f=json.load(open('$T/run/summary.json'))['failures'][0]; print('%s:%s' % (f['file'],f['line']))")"
  st_eq "summary.json: counts per simulator" "3 2" "$(python3 -I -c "
import json
c=json.load(open('$T/run/summary.json'))['counts']; print(c['BW Test iPhone 18 Pro']['total'], c['BW Test iPhone Duo']['total'])")"
  st_check "summary.md: names the failing test and simulator" 0 grep -q 'testRowOpensDetailSheet.*BW Test iPhone 18 Pro (BoatARUITests.swift:228)' "$T/run/summary.md"
  python3 -I "$PY" summarize --out-dir "$T/run2" --commit abc1234 --branch b --tier smoke --started s --finished f --verdict invalid \
    --note "CPU busy" --idle-start 33.5 --top-start "221.8 mediaanalysisd" --top-start "54.0 swift-test" --top-end "90.1 xcodebuild"
  st_check "summary.md: invalid is labelled as not a test failure" 0 grep -q 'not a test failure' "$T/run2/summary.md"
  st_check "summary.md: idle at start recorded" 0 grep -q 'CPU idle at start: 33.5%' "$T/run2/summary.md"
  st_check "summary.md: busiest processes at start and end recorded" 0 grep -q 'at end: 90.1 xcodebuild' "$T/run2/summary.md"
  st_eq "summary.json: machine block" "33.5 2 1" "$(python3 -I -c "
import json
m=json.load(open('$T/run2/summary.json'))['machine']; print(m['cpu_idle_at_start_pct'], len(m['top_cpu_at_start']), len(m['top_cpu_at_end']))")"
  printf '%s' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"U1","state":"Booted"},{"udid":"U2","state":"Shutdown"}]}}' >"$T/devs.json"
  st_eq "sim-booted: only booted UDIDs" U1 "$(python3 -I "$PY" sim-booted <"$T/devs.json")"
  printf '%s' '[{"testIdentifier":"X","testRuns":[{"metrics":[{"displayName":"CPU Time","unitOfMeasurement":"s","measurements":[1,2,3,4,5]},{"displayName":"Memory Peak","unitOfMeasurement":"kB","measurements":[100000,120000]}]}]}]' >"$T/metrics.json"
  st_eq "perf line: avg, rsd, peak MB" "2026-11-16	abc1234	testX	3.000	52.7	120.0" \
    "$(python3 -I "$PY" perf-line --metrics "$T/metrics.json" --test testX --date 2026-11-16 --commit abc1234)"

  # Retention.
  mkdir -p "$T/results"
  n=0
  while [ "$n" -lt 35 ]; do
    mkdir "$T/results/$(printf '202611%02dT100000Z' $((n + 1)))-abc-smoke"
    n=$((n + 1))
  done
  ln -s 20261101T100000Z-abc-smoke "$T/results/latest-smoke"
  prune_results "$T/results" 30
  st_eq "retention: 30 run folders kept" 30 "$(ls -1d "$T"/results/[0-9]*T*Z-* | wc -l | tr -d ' ')"
  st_check "retention: the newest is kept" 0 test -d "$T/results/20261135T100000Z-abc-smoke"
  st_check "retention: the oldest is gone" 1 test -d "$T/results/20261101T100000Z-abc-smoke"

  # Chaos tier: plan, environment forwarding, options.
  out=$(parse_args chaos --seed 7 && make_plan && printf 'sims=%s\n' "${PLAN_SIMS[*]}" && printf 'dd=%s\n' "$DD_NAME" \
    && printf 'release=%s\n' "$PLAN_RELEASE" && printf 'tests=%s\n' "${PLAN_TESTS[*]}")
  case "$out" in *"BW Test iPhone 18 Pro|iPhone 18 Pro|27.0 pro|BW Test iPhone Duo"* | *"pro|BW Test iPhone 18 Pro"*"duo|BW Test iPhone Duo"*) st_eq "chaos plan: both simulators" 1 1 ;; *) st_eq "chaos plan: both simulators" 1 0 ;; esac
  case "$out" in *"dd=chaos"*) st_eq "chaos plan: own DerivedData key" 1 1 ;; *) st_eq "chaos plan: own DerivedData key" 1 0 ;; esac
  case "$out" in *"release=0"*) st_eq "chaos plan: no Release build" 1 1 ;; *) st_eq "chaos plan: no Release build" 1 0 ;; esac
  st_eq "chaos plan: tests are the file's" "tests=$(read_list "$CHAOS_FILE" | tr '\n' ' ' | sed 's/ $//')" "$(printf '%s\n' "$out" | grep '^tests=')"
  st_check "chaos list: every entry is an existing test" 0 test -z "$(while IFS= read -r e; do
    grep -q "func ${e#*/}" "$REPO_ROOT"/BoatARUITests/*.swift || echo "missing $e"; done < <(read_list "$CHAOS_FILE"))"
  out=$(unset BOATAR_CHAOS_SEED BOATAR_CHAOS_ACTIONS TEST_RUNNER_BOATAR_CHAOS TEST_RUNNER_BOATAR_CHAOS_SEED TEST_RUNNER_BOATAR_CHAOS_ACTIONS
    NOTES=()
    parse_args chaos --seed 7 && chaos_env && echo "env=$TEST_RUNNER_BOATAR_CHAOS/$TEST_RUNNER_BOATAR_CHAOS_SEED/${TEST_RUNNER_BOATAR_CHAOS_ACTIONS:-none} ${NOTES[*]}")
  st_eq "chaos env: --seed forwarded, no actions" "env=1/7/none chaos: on, seed 7" "$out"
  out=$(unset TEST_RUNNER_BOATAR_CHAOS_SEED TEST_RUNNER_BOATAR_CHAOS_ACTIONS
    NOTES=()
    BOATAR_CHAOS_SEED=9 BOATAR_CHAOS_ACTIONS=50
    parse_args only BoatARUITests/testChaosMonkey --chaos && chaos_env && echo "env=$TEST_RUNNER_BOATAR_CHAOS/$TEST_RUNNER_BOATAR_CHAOS_SEED/$TEST_RUNNER_BOATAR_CHAOS_ACTIONS ${NOTES[*]}")
  st_eq "chaos env: only --chaos forwards the caller's seed and actions" "env=1/9/50 chaos: on, seed 9, 50 actions" "$out"
  out=$(unset BOATAR_CHAOS_SEED TEST_RUNNER_BOATAR_CHAOS TEST_RUNNER_BOATAR_CHAOS_SEED
    NOTES=()
    parse_args chaos && chaos_env && echo "${NOTES[*]} seed=${TEST_RUNNER_BOATAR_CHAOS_SEED:-unset}")
  st_eq "chaos env: no seed is recorded as random" "chaos: on, seed random seed=unset" "$out"
  out=$(unset TEST_RUNNER_BOATAR_CHAOS
    parse_args smoke && chaos_env && echo "env=${TEST_RUNNER_BOATAR_CHAOS:-unset}")
  st_eq "chaos env: other tiers leave it off" "env=unset" "$out"
  st_eq "chaos plan: only + --chaos plans one simulator" "sims=$SIM_PRO" "$(parse_args only BoatARUITests/testChaosMonkey --chaos --seed 7; make_plan; echo "sims=${PLAN_SIMS[*]}")"

  # Crash finder: one report for the app after the start, one before it, one for another app.
  mkdir -p "$T/crash/host" "$T/crash/sim" "$T/crashrun"
  printf '%s\n%s\n' '{"app_name":"BoatAR","bundleID":"com.bsowens.BoatAR","timestamp":"2026-11-18 10:00:00.00 -0500","bug_type":"309"}' \
    '{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"faultingThread":1,"usedImages":[{"name":"BoatAR"}],"threads":[{"frames":[]},{"triggered":true,"frames":[{"symbol":"closure in MapView.body","imageIndex":0}]}]}' \
    >"$T/crash/host/BoatAR-2026-11-18-100000.ips"
  cp "$T/crash/host/BoatAR-2026-11-18-100000.ips" "$T/crash/sim/BoatAR-old.ips"
  touch -t 202001010000 "$T/crash/sim/BoatAR-old.ips"
  printf '%s\n%s\n' '{"app_name":"Other","bundleID":"com.example.Other"}' '{"exception":{"type":"EXC_CRASH"}}' >"$T/crash/host/Other-2026-11-18-100001.ips"
  printf '%s\n' 'not an ips' >"$T/crash/host/notes.txt"
  CRASH_SINCE=$(($(date +%s) - 600))
  RUN_DIR="$T/crashrun"
  UITEST_CRASH_DIRS="$T/crash/host:$T/crash/sim:$T/crash/missing"
  collect_crashes 2>/dev/null
  st_eq "crashes: exactly one found" 1 "$CRASH_COUNT"
  st_eq "crashes: it is copied, and only it" "BoatAR-2026-11-18-100000.ips" "$(ls "$T/crashrun/crashes")"
  st_eq "crashes: the note says so" "the app crashed 1 time(s) during the run (reports in crashes/)" "${NOTES[${#NOTES[@]}-1]}"
  TESTS_FAILED=0
  INFRA_PROBLEM=0
  decide_verdict
  st_eq "crashes: every test passed but the verdict is fail" fail "$VERDICT_DECIDED"
  CRASH_COUNT=0
  decide_verdict
  st_eq "verdict: no crash, no failure -> pass" pass "$VERDICT_DECIDED"
  INFRA_PROBLEM=1
  decide_verdict
  st_eq "verdict: infrastructure problem alone -> invalid" invalid "$VERDICT_DECIDED"
  INFRA_PROBLEM=0
  python3 -I "$PY" summarize --out-dir "$T/crashrun" --commit abc1234 --branch b --tier chaos --started s --finished f --verdict fail \
    --crashes-dir "$T/crashrun/crashes" --note "the app crashed 1 time(s) during the run (reports in crashes/)"
  st_check "summary.md: Crashes heading lists the report" 0 grep -q 'BoatAR-2026-11-18-100000.ips' "$T/crashrun/summary.md"
  st_check "summary.md: crash line has exception and top frame" 0 grep -q 'EXC_BAD_ACCESS/SIGSEGV, closure in MapView.body' "$T/crashrun/summary.md"
  st_check "summary.md: headline says the app crashed" 0 grep -q 'the app crashed' "$T/crashrun/summary.md"
  st_eq "summary.json: crash count" 1 "$(python3 -I -c "
import json; print(len(json.load(open('$T/crashrun/summary.json'))['crashes']))")"
  UITEST_CRASH_DIRS="$T/crash/sim"
  RUN_DIR="$T/crashrun2"
  mkdir -p "$RUN_DIR"
  collect_crashes 2>/dev/null
  st_eq "crashes: none newer than the start -> 0, no folder" "0 absent" "$CRASH_COUNT $([ -d "$RUN_DIR/crashes" ] && echo present || echo absent)"
  unset UITEST_CRASH_DIRS
  RUN_DIR=""
  NOTES=()

  # Exit codes, through the real entry point with injected readings.
  run_me() { UITEST_LOCK_DIR="$T/lock2" UITEST_DEVICES_DIR="$d" UITEST_SKIP_XCODE_CHECK=1 UITEST_SKIP_SIMCTL=1 UITEST_FAKE_XCODEBUILD=none \
    UITEST_RESULTS_ROOT="$T/results" UITEST_FAKE_FREE_GB=50 UITEST_FAKE_BOOTED=none "$@" "$me" "${RUN_ARGS[@]}"; }
  RUN_ARGS=(bogus)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: unknown tier -> 64" 64 "$?"
  RUN_ARGS=(chaos --bogus)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: unknown option -> 64" 64 "$?"
  RUN_ARGS=(smoke --seed 3)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: --seed without chaos -> 64" 64 "$?"
  RUN_ARGS=(chaos --seed x)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: bad --seed -> 64" 64 "$?"
  RUN_ARGS=(chaos --dry-run --seed 7)
  out=$(run_me env UITEST_FAKE_IDLE=80 2>&1)
  st_eq "exit codes: chaos dry run -> 0" 0 "$?"
  case "$out" in *"BW Test iPhone Duo"*"chaos:       on, seed 7"*) st_eq "chaos dry run: names both simulators and the seed" 1 1 ;; *) st_eq "chaos dry run: names both simulators and the seed" 1 0 ;; esac
  RUN_ARGS=(smoke --wait x)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: bad --wait -> 64" 64 "$?"
  RUN_ARGS=(smoke --dry-run)
  run_me env UITEST_FAKE_IDLE=5 >/dev/null 2>&1
  st_eq "exit codes: dry run on a busy CPU -> 75" 75 "$?"
  RUN_ARGS=(smoke)
  run_me env UITEST_FAKE_IDLE=5 >/dev/null 2>&1
  st_eq "exit codes: real run on a busy CPU -> 75, before any xcodebuild" 75 "$?"
  st_check "exit codes: a refused run leaves no lock behind" 1 test -d "$T/lock2"
  RUN_ARGS=(smoke --dry-run)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: dry run on a quiet machine -> 0" 0 "$?"
  mkdir "$T/lock2" && echo "$$" >"$T/lock2/pid"
  RUN_ARGS=(smoke)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "exit codes: lock held by a live process -> 75" 75 "$?"
  rm -rf "$T/lock2"
  RUN_ARGS=(last smoke)
  run_me env >/dev/null 2>&1
  st_eq "last: no results for the tier -> 1" 1 "$?"
  RUN_ARGS=(status)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "status: exits 0" 0 "$?"

  RUN_ARGS=(hold --wait 0)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "hold: no command -> 64" 64 "$?"
  RUN_ARGS=(hold -- /usr/bin/true)
  run_me env UITEST_FAKE_IDLE=5 >/dev/null 2>&1
  st_eq "hold: busy CPU -> 75, command not run" 75 "$?"
  RUN_ARGS=(hold -- /bin/sh -c 'test -f "$UITEST_LOCK_DIR/pid" && exit 7')
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "hold: the lock is held while the command runs, exit status passes through" 7 "$?"
  st_check "hold: released afterwards" 1 test -d "$T/lock2"
  mkdir "$T/lock2" && echo "$$" >"$T/lock2/pid"
  RUN_ARGS=(hold -- /usr/bin/true)
  run_me env UITEST_FAKE_IDLE=80 >/dev/null 2>&1
  st_eq "hold: lock held by a live process -> 75" 75 "$?"
  rm -rf "$T/lock2"

  rm -rf "$T"
  echo "selftest: $ST_PASS passed, $ST_FAIL failed"
  [ "$ST_FAIL" -eq 0 ]
}

# ---- Entry point -------------------------------------------------------------------------------------------------

main() {
  parse_args "$@"
  cd "$REPO_ROOT" || exit 64
  case "$TIER" in
    last) cmd_last; exit $? ;;
    status) cmd_status; exit 0 ;;
    selftest) selftest; exit $? ;;
    hold) run_hold ;;
  esac
  make_plan
  if [ "$DRY_RUN" = 1 ]; then
    print_plan
    if preflight; then
      echo "preflight:   ok: a real run would start"
      exit 0
    fi
    echo "preflight:   WOULD NOT RUN: $PREFLIGHT_REASON (exit 75)"
    exit 75
  fi
  run_tier
}

if [ "${UITEST_SOURCE_ONLY:-}" != 1 ]; then
  main "$@"
fi

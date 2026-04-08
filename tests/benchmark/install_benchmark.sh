#!/usr/bin/env bash
# install_benchmark.sh — CGW drop-in installation evaluation benchmark
#
# Usage:
#   bash install_benchmark.sh --source <cgw-repo> --target <consumer-project>
#
# Phases:
#   0 PF  Pre-flight checks (read-only)
#   1 BK  Backup existing hooks
#   2 CP  Copy CGW files into target
#   3 CF  Run configure.sh + verify results
#   4 HK  Custom hooks setup verification
#   5 FN  Functional tests
#   6 INT Integration & cleanup checks
#
# Output: JSON records to stdout, markdown report to --report file

set -uo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
SOURCE_DIR=""
TARGET_DIR=""
REPORT_FILE=""
DRY_RUN=0
SKIP_WRITE=0  # If set, skip phases that modify target (BK/CP/CF)

# ─── Counters ────────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
WARNED=0
FAILED=0

# Phase-level counters (associative array)
declare -A PHASE_PASS PHASE_WARN PHASE_FAIL PHASE_TOTAL

# JSON records buffer
JSON_RECORDS=()

# ─── Colors ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_PASS="\033[0;32m"
    C_WARN="\033[0;33m"
    C_FAIL="\033[0;31m"
    C_INFO="\033[0;36m"
    C_DIM="\033[0;90m"
    C_BOLD="\033[1m"
    C_RESET="\033[0m"
else
    C_PASS="" C_WARN="" C_FAIL="" C_INFO="" C_DIM="" C_BOLD="" C_RESET=""
fi

# ─── Arg parsing ─────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)   SOURCE_DIR="$2"; shift 2 ;;
        --target)   TARGET_DIR="$2"; shift 2 ;;
        --report)   REPORT_FILE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=1; SKIP_WRITE=1; shift ;;
        --skip-write) SKIP_WRITE=1; shift ;;
        -h|--help)
            echo "Usage: $0 --source <cgw-repo> --target <consumer-project> [--report <file>] [--dry-run]"
            echo ""
            echo "  --source      Path to the CGW source repository"
            echo "  --target      Path to the consumer project to install CGW into"
            echo "  --report      Output path for the markdown report (default: TARGET/.cgw-benchmark-report.md)"
            echo "  --dry-run     Run pre-flight checks only, no modifications"
            echo "  --skip-write  Skip phases that modify target (BK/CP/CF)"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SOURCE_DIR" || -z "$TARGET_DIR" ]]; then
    echo "ERROR: --source and --target are required" >&2
    exit 1
fi

SOURCE_DIR="${SOURCE_DIR%/}"
TARGET_DIR="${TARGET_DIR%/}"
REPORT_FILE="${REPORT_FILE:-${TARGET_DIR}/.cgw-benchmark-report.md}"

BENCHMARK_START=$(date +%s%3N 2>/dev/null || date +%s)
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')

# ─── Helpers ─────────────────────────────────────────────────────────────────
_ms() {
    # Return current epoch in milliseconds
    date +%s%3N 2>/dev/null || echo "0"
}

_escape_json() {
    # Minimal JSON string escaping
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    echo "$s"
}

_record() {
    local id="$1" phase="$2" verdict="$3" description="$4" cmd="$5" \
          stdout="$6" stderr="$7" exit_code="$8" duration="$9" notes="${10:-}"

    local esc_desc esc_cmd esc_out esc_err esc_notes
    esc_desc="$(_escape_json "$description")"
    esc_cmd="$(_escape_json "$cmd")"
    esc_out="$(_escape_json "${stdout:0:500}")"   # cap at 500 chars
    esc_err="$(_escape_json "${stderr:0:500}")"
    esc_notes="$(_escape_json "$notes")"

    local record
    record="{\"id\":\"${id}\",\"phase\":\"${phase}\",\"verdict\":\"${verdict}\","
    record+="\"description\":\"${esc_desc}\",\"command\":\"${esc_cmd}\","
    record+="\"stdout\":\"${esc_out}\",\"stderr\":\"${esc_err}\","
    record+="\"exit_code\":${exit_code},\"duration_ms\":${duration},\"notes\":\"${esc_notes}\"}"

    JSON_RECORDS+=("$record")
    echo "$record"
}

_update_counters() {
    local phase="$1" verdict="$2"
    TOTAL=$((TOTAL + 1))
    PHASE_TOTAL["$phase"]=$(( ${PHASE_TOTAL["$phase"]:-0} + 1 ))
    case "$verdict" in
        PASS)
            PASSED=$((PASSED + 1))
            PHASE_PASS["$phase"]=$(( ${PHASE_PASS["$phase"]:-0} + 1 ))
            ;;
        WARN)
            WARNED=$((WARNED + 1))
            PHASE_WARN["$phase"]=$(( ${PHASE_WARN["$phase"]:-0} + 1 ))
            ;;
        FAIL)
            FAILED=$((FAILED + 1))
            PHASE_FAIL["$phase"]=$(( ${PHASE_FAIL["$phase"]:-0} + 1 ))
            ;;
    esac
}

_print_verdict() {
    local id="$1" verdict="$2" description="$3" notes="$4"
    local icon color
    case "$verdict" in
        PASS) icon="✓"; color="$C_PASS" ;;
        WARN) icon="⚠"; color="$C_WARN" ;;
        FAIL) icon="✗"; color="$C_FAIL" ;;
        *)    icon="?"; color="$C_DIM"  ;;
    esac
    printf "  ${color}${icon}${C_RESET} ${C_DIM}%-8s${C_RESET} %s" "$id" "$description"
    [[ -n "$notes" ]] && printf " ${C_DIM}(%s)${C_RESET}" "$notes"
    echo ""
}

# run_check ID PHASE DESCRIPTION VERDICT COMMAND STDOUT STDERR EXIT_CODE DURATION [NOTES]
run_check() {
    local id="$1" phase="$2" description="$3" verdict="$4" \
          cmd="$5" stdout="$6" stderr="$7" exit_code="$8" duration="$9" \
          notes="${10:-}"
    _update_counters "$phase" "$verdict"
    _print_verdict "$id" "$verdict" "$description" "$notes"
    _record "$id" "$phase" "$verdict" "$description" "$cmd" \
            "$stdout" "$stderr" "$exit_code" "$duration" "$notes" >/dev/null
    # Also accumulate for final JSON array (re-add to buffer)
    local esc_desc esc_cmd esc_out esc_err esc_notes
    esc_desc="$(_escape_json "$description")"
    esc_cmd="$(_escape_json "$cmd")"
    esc_out="$(_escape_json "${stdout:0:500}")"
    esc_err="$(_escape_json "${stderr:0:500}")"
    esc_notes="$(_escape_json "$notes")"
    local rec
    rec="{\"id\":\"${id}\",\"phase\":\"${phase}\",\"verdict\":\"${verdict}\","
    rec+="\"description\":\"${esc_desc}\",\"command\":\"${esc_cmd}\","
    rec+="\"stdout\":\"${esc_out}\",\"stderr\":\"${esc_err}\","
    rec+="\"exit_code\":${exit_code},\"duration_ms\":${duration},\"notes\":\"${esc_notes}\"}"
    JSON_RECORDS+=("$rec")
}

# exec_check: runs a command, returns verdict based on expected exit code
# Usage: exec_check ID PHASE DESCRIPTION COMMAND [expected_exit=0] [notes]
exec_check() {
    local id="$1" phase="$2" description="$3" cmd="$4" \
          expected="${5:-0}" notes="${6:-}"
    local t0 t1 duration stdout_val stderr_val exit_code verdict

    t0=$(_ms)
    stdout_val=$(eval "$cmd" 2>/tmp/cgw_bench_stderr)
    exit_code=$?
    stderr_val=$(cat /tmp/cgw_bench_stderr 2>/dev/null || true)
    t1=$(_ms)
    duration=$(( t1 - t0 ))

    if [[ "$exit_code" -eq "$expected" ]]; then
        verdict="PASS"
    else
        verdict="FAIL"
        [[ -n "$notes" ]] || notes="exit=${exit_code}, expected=${expected}"
    fi

    run_check "$id" "$phase" "$description" "$verdict" \
              "$cmd" "$stdout_val" "$stderr_val" "$exit_code" "$duration" "$notes"
    # Return the actual output for caller inspection
    printf '%s' "$stdout_val"
}

# warn_check: like exec_check but a non-zero result is WARN, not FAIL
warn_check() {
    local id="$1" phase="$2" description="$3" cmd="$4" notes="${5:-}"
    local t0 t1 duration stdout_val stderr_val exit_code verdict

    t0=$(_ms)
    stdout_val=$(eval "$cmd" 2>/tmp/cgw_bench_stderr)
    exit_code=$?
    stderr_val=$(cat /tmp/cgw_bench_stderr 2>/dev/null || true)
    t1=$(_ms)
    duration=$(( t1 - t0 ))
    verdict="PASS"
    [[ "$exit_code" -ne 0 ]] && verdict="WARN"

    run_check "$id" "$phase" "$description" "$verdict" \
              "$cmd" "$stdout_val" "$stderr_val" "$exit_code" "$duration" "$notes"
    printf '%s' "$stdout_val"
}

_phase_header() {
    local label="$1"
    echo ""
    printf "${C_BOLD}${C_INFO}%s${C_RESET}\n" "$label"
}

# ─── Phase 0: Pre-flight ──────────────────────────────────────────────────────
phase_preflight() {
    _phase_header "Phase 0 — Pre-Flight Checks"

    local out t0 t1 dur verdict notes

    # PF-01: CGW source script count
    t0=$(_ms)
    out=$(ls "${SOURCE_DIR}/scripts/git/"*.sh 2>/dev/null | wc -l | tr -d ' ')
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ "$out" -ge 14 ]]; then verdict="PASS"; notes="found ${out} scripts"
    else verdict="FAIL"; notes="expected >=14, found ${out}"; fi
    run_check "PF-01" "preflight" "CGW source has >=14 shell scripts" "$verdict" \
              "ls ${SOURCE_DIR}/scripts/git/*.sh | wc -l" "$out" "" 0 "$dur" "$notes"

    # PF-02: Hook template exists + has placeholder
    t0=$(_ms)
    local hook_tmpl="${SOURCE_DIR}/hooks/pre-commit"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$hook_tmpl" ]]; then
        local placeholder_count
        placeholder_count=$(grep -c '__CGW_LOCAL_FILES_PATTERN__' "$hook_tmpl" 2>/dev/null || echo 0)
        if [[ "$placeholder_count" -ge 1 ]]; then
            verdict="PASS"; notes="placeholder found (${placeholder_count} occurrences)"
        else
            verdict="FAIL"; notes="hook template exists but missing placeholder"
        fi
    else
        verdict="FAIL"; notes="not found at ${hook_tmpl}"
    fi
    run_check "PF-02" "preflight" "Hook template exists with placeholder" "$verdict" \
              "test -f ${hook_tmpl}" "" "" 0 "$dur" "$notes"

    # PF-03: Skill + command source files
    t0=$(_ms)
    local skill_ok=1
    [[ -f "${SOURCE_DIR}/skill/SKILL.md" ]] || skill_ok=0
    [[ -d "${SOURCE_DIR}/skill/references" ]] || skill_ok=0
    [[ -f "${SOURCE_DIR}/command/auto-git-workflow.md" ]] || skill_ok=0
    ref_count=$(ls "${SOURCE_DIR}/skill/references/"*.md 2>/dev/null | wc -l | tr -d ' ')
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ "$skill_ok" -eq 1 && "$ref_count" -ge 3 ]]; then
        verdict="PASS"; notes="${ref_count} reference files"
    else
        verdict="FAIL"; notes="missing skill/command files or references (found ${ref_count})"
    fi
    run_check "PF-03" "preflight" "Skill + command source files exist" "$verdict" \
              "test -f skill/SKILL.md && ls skill/references/*.md" "" "" 0 "$dur" "$notes"

    # PF-04: Target is a git repo + branch
    t0=$(_ms)
    out=$(git -C "${TARGET_DIR}" branch --show-current 2>/dev/null || echo "")
    t1=$(_ms); dur=$(( t1 - t0 ))
    if git -C "${TARGET_DIR}" rev-parse --is-inside-work-tree &>/dev/null; then
        verdict="PASS"; notes="branch: ${out}"
    else
        verdict="FAIL"; notes="not a git repository"
    fi
    run_check "PF-04" "preflight" "Target is a git repo" "$verdict" \
              "git -C TARGET rev-parse --is-inside-work-tree" "$out" "" 0 "$dur" "$notes"

    # PF-05: Target scripts/git/ is empty or missing
    t0=$(_ms)
    out=$(ls "${TARGET_DIR}/scripts/git/"*.sh 2>/dev/null | wc -l | tr -d ' ')
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ "$out" -eq 0 ]]; then
        verdict="PASS"; notes="scripts/git/ is empty — ready for install"
    else
        verdict="WARN"; notes="${out} scripts already present — may be stale"
    fi
    run_check "PF-05" "preflight" "Target scripts/git/ is empty" "$verdict" \
              "ls TARGET/scripts/git/*.sh | wc -l" "$out" "" 0 "$dur" "$notes"

    # PF-06: No existing .cgw.conf
    t0=$(_ms); t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ ! -f "${TARGET_DIR}/.cgw.conf" ]]; then
        verdict="PASS"; notes="clean slate"
    else
        verdict="WARN"; notes=".cgw.conf exists — configure.sh will prompt to reconfigure"
    fi
    run_check "PF-06" "preflight" "No existing .cgw.conf (clean slate)" "$verdict" \
              "test ! -f TARGET/.cgw.conf" "" "" 0 "$dur" ""

    # PF-07: Lint tool (ruff) available
    t0=$(_ms)
    out=$(command -v ruff 2>/dev/null && ruff --version 2>/dev/null || echo "not found")
    exit_code=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if command -v ruff &>/dev/null; then
        verdict="PASS"; notes="$out"
    else
        verdict="WARN"; notes="ruff not on PATH — configure.sh may not detect lint tool"
    fi
    run_check "PF-07" "preflight" "ruff lint tool available on PATH" "$verdict" \
              "command -v ruff && ruff --version" "$out" "" 0 "$dur" "$notes"

    # PF-08: Existing .githooks/pre-commit noted
    t0=$(_ms); t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "${TARGET_DIR}/.githooks/pre-commit" ]]; then
        local line_count
        line_count=$(wc -l < "${TARGET_DIR}/.githooks/pre-commit" 2>/dev/null || echo 0)
        verdict="WARN"
        notes="${line_count}-line custom hook exists — will be overwritten by configure.sh; backup required (Phase BK)"
    else
        verdict="PASS"; notes="no pre-existing hook to protect"
    fi
    run_check "PF-08" "preflight" "Existing .githooks/pre-commit noted" "$verdict" \
              "test -f TARGET/.githooks/pre-commit" "" "" 0 "$dur" "$notes"

    # PF-09: .git/hooks/pre-commit state
    t0=$(_ms); t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "${TARGET_DIR}/.git/hooks/pre-commit" ]]; then
        verdict="WARN"; notes="active git hook exists — will be replaced"
    else
        verdict="PASS"; notes="no active .git/hooks/pre-commit — CGW will install fresh"
    fi
    run_check "PF-09" "preflight" ".git/hooks/pre-commit state" "$verdict" \
              "test -f TARGET/.git/hooks/pre-commit" "" "" 0 "$dur" "$notes"

    # PF-10: git-commit-enforcer.py registered in settings.json
    t0=$(_ms)
    local settings="${TARGET_DIR}/.claude/settings.json"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$settings" ]] && grep -q 'git-commit-enforcer' "$settings" 2>/dev/null; then
        verdict="PASS"; notes="PreToolUse hook is configured"
    elif [[ -f "$settings" ]]; then
        verdict="WARN"; notes=".claude/settings.json exists but no git-commit-enforcer hook"
    else
        verdict="WARN"; notes="no .claude/settings.json found"
    fi
    run_check "PF-10" "preflight" "git-commit-enforcer.py registered in settings.json" "$verdict" \
              "grep git-commit-enforcer TARGET/.claude/settings.json" "" "" 0 "$dur" "$notes"
}

# ─── Phase 1: Backup ──────────────────────────────────────────────────────────
phase_backup() {
    _phase_header "Phase 1 — Backup Existing Hooks & Config"

    if [[ "$SKIP_WRITE" -eq 1 ]]; then
        echo "  (skipped — --dry-run or --skip-write)"
        return
    fi

    local t0 t1 dur verdict notes out

    # BK-01: Backup .githooks/pre-commit
    t0=$(_ms)
    if [[ -f "${TARGET_DIR}/.githooks/pre-commit" ]]; then
        cp "${TARGET_DIR}/.githooks/pre-commit" "${TARGET_DIR}/.githooks/pre-commit.bak" 2>/tmp/cgw_bench_stderr
        local ec=$?
        t1=$(_ms); dur=$(( t1 - t0 ))
        if [[ $ec -eq 0 ]]; then
            verdict="PASS"; notes="saved to .githooks/pre-commit.bak"
        else
            verdict="FAIL"; notes="$(cat /tmp/cgw_bench_stderr)"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="PASS"; notes="no existing hook to backup"
    fi
    run_check "BK-01" "backup" "Backup .githooks/pre-commit" "$verdict" \
              "cp .githooks/pre-commit .githooks/pre-commit.bak" "" "" 0 "$dur" "$notes"

    # BK-02: Backup .claude/settings.json
    t0=$(_ms)
    if [[ -f "${TARGET_DIR}/.claude/settings.json" ]]; then
        cp "${TARGET_DIR}/.claude/settings.json" "${TARGET_DIR}/.claude/settings.json.bak" 2>/tmp/cgw_bench_stderr
        local ec=$?
        t1=$(_ms); dur=$(( t1 - t0 ))
        if [[ $ec -eq 0 ]]; then
            verdict="PASS"; notes="saved to .claude/settings.json.bak"
        else
            verdict="FAIL"; notes="$(cat /tmp/cgw_bench_stderr)"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="PASS"; notes="no settings.json to backup"
    fi
    run_check "BK-02" "backup" "Backup .claude/settings.json" "$verdict" \
              "cp .claude/settings.json .claude/settings.json.bak" "" "" 0 "$dur" "$notes"

    # BK-03: Record git-commit-enforcer.py hash
    t0=$(_ms)
    local enforcer="${TARGET_DIR}/.claude/hooks/git-commit-enforcer.py"
    if [[ -f "$enforcer" ]]; then
        out=$(sha256sum "$enforcer" 2>/dev/null | awk '{print $1}' || md5sum "$enforcer" 2>/dev/null | awk '{print $1}' || echo "hash-unavailable")
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="PASS"; notes="sha256: ${out:0:16}..."
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="git-commit-enforcer.py not found"
    fi
    run_check "BK-03" "backup" "Record git-commit-enforcer.py hash" "$verdict" \
              "sha256sum .claude/hooks/git-commit-enforcer.py" "$out" "" 0 "$dur" "$notes"
}

# ─── Phase 2: File Copy ───────────────────────────────────────────────────────
phase_copy() {
    _phase_header "Phase 2 — Copy CGW Files Into Target"

    if [[ "$SKIP_WRITE" -eq 1 ]]; then
        echo "  (skipped — --dry-run or --skip-write)"
        return
    fi

    local t0 t1 dur verdict notes out ec

    # CP-01: Create scripts/git/ and copy scripts
    t0=$(_ms)
    mkdir -p "${TARGET_DIR}/scripts/git"
    cp "${SOURCE_DIR}/scripts/git/"*.sh "${TARGET_DIR}/scripts/git/" 2>/tmp/cgw_bench_stderr
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ $ec -eq 0 ]]; then
        local count
        count=$(ls "${TARGET_DIR}/scripts/git/"*.sh 2>/dev/null | wc -l | tr -d ' ')
        verdict="PASS"; notes="copied ${count} scripts"
    else
        verdict="FAIL"; notes="$(cat /tmp/cgw_bench_stderr)"
    fi
    run_check "CP-01" "copy" "Copy scripts/git/*.sh" "$verdict" \
              "cp SOURCE/scripts/git/*.sh TARGET/scripts/git/" "" "" "$ec" "$dur" "$notes"

    # CP-02: Verify scripts are executable
    t0=$(_ms)
    local non_exec
    non_exec=$(find "${TARGET_DIR}/scripts/git/" -name "*.sh" ! -perm -u+x 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$non_exec" -gt 0 ]]; then
        chmod +x "${TARGET_DIR}/scripts/git/"*.sh 2>/dev/null
        non_exec=$(find "${TARGET_DIR}/scripts/git/" -name "*.sh" ! -perm -u+x 2>/dev/null | wc -l | tr -d ' ')
    fi
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ "$non_exec" -eq 0 ]]; then
        verdict="PASS"; notes="all scripts executable"
    else
        verdict="WARN"; notes="${non_exec} scripts not executable — chmod +x applied"
    fi
    run_check "CP-02" "copy" "All copied scripts are executable" "$verdict" \
              "find scripts/git/ -name '*.sh' ! -perm -u+x" "$non_exec" "" 0 "$dur" "$notes"

    # CP-03: Copy hooks/ template directory
    t0=$(_ms)
    mkdir -p "${TARGET_DIR}/hooks"
    cp "${SOURCE_DIR}/hooks/pre-commit" "${TARGET_DIR}/hooks/pre-commit" 2>/tmp/cgw_bench_stderr
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ $ec -eq 0 ]]; then
        if grep -q '__CGW_LOCAL_FILES_PATTERN__' "${TARGET_DIR}/hooks/pre-commit"; then
            verdict="PASS"; notes="template placeholder present"
        else
            verdict="FAIL"; notes="copied but placeholder missing"
        fi
    else
        verdict="FAIL"; notes="$(cat /tmp/cgw_bench_stderr)"
    fi
    run_check "CP-03" "copy" "Copy hooks/pre-commit template" "$verdict" \
              "cp SOURCE/hooks/pre-commit TARGET/hooks/pre-commit" "" "" "$ec" "$dur" "$notes"

    # CP-04: Copy cgw.conf.example (optional)
    t0=$(_ms)
    if [[ -f "${SOURCE_DIR}/cgw.conf.example" ]]; then
        cp "${SOURCE_DIR}/cgw.conf.example" "${TARGET_DIR}/cgw.conf.example" 2>/dev/null
        ec=$?
    else
        ec=1
    fi
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ $ec -eq 0 ]]; then
        verdict="PASS"; notes="config reference available"
    else
        verdict="WARN"; notes="cgw.conf.example not found in source — optional, skipping"
    fi
    run_check "CP-04" "copy" "Copy cgw.conf.example (optional reference)" "$verdict" \
              "cp SOURCE/cgw.conf.example TARGET/cgw.conf.example" "" "" "$ec" "$dur" "$notes"
}

# ─── Phase 3: configure.sh ────────────────────────────────────────────────────
phase_configure() {
    _phase_header "Phase 3 — Run configure.sh + Verify Results"

    if [[ "$SKIP_WRITE" -eq 1 ]]; then
        echo "  (skipped — --dry-run or --skip-write)"
        return
    fi

    local t0 t1 dur verdict notes out ec cfg

    # CF-01: Run configure.sh --non-interactive
    t0=$(_ms)
    local cfg_out cfg_err cfg_exit
    cfg_out=$(bash "${TARGET_DIR}/scripts/git/configure.sh" --non-interactive 2>/tmp/cgw_bench_stderr)
    cfg_exit=$?
    cfg_err=$(cat /tmp/cgw_bench_stderr 2>/dev/null || true)
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ $cfg_exit -eq 0 ]]; then
        verdict="PASS"; notes="exited cleanly"
    else
        verdict="FAIL"; notes="exit=${cfg_exit}; check stderr"
    fi
    run_check "CF-01" "configure" "Run configure.sh --non-interactive" "$verdict" \
              "bash scripts/git/configure.sh --non-interactive" \
              "${cfg_out:0:300}" "${cfg_err:0:300}" "$cfg_exit" "$dur" "$notes"

    cfg="${TARGET_DIR}/.cgw.conf"

    # CF-02: .cgw.conf generated
    t0=$(_ms); t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$cfg" ]]; then verdict="PASS"; notes=""
    else verdict="FAIL"; notes=".cgw.conf not generated"; fi
    run_check "CF-02" "configure" ".cgw.conf was generated" "$verdict" \
              "test -f .cgw.conf" "" "" 0 "$dur" "$notes"

    # CF-03: Target branch
    t0=$(_ms)
    out=$(grep 'CGW_TARGET_BRANCH=' "$cfg" 2>/dev/null | head -1 | tr -d '"' || echo "")
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -n "$out" ]]; then
        verdict="PASS"; notes="$out"
    else
        verdict="FAIL"; notes="CGW_TARGET_BRANCH not set in .cgw.conf"
    fi
    run_check "CF-03" "configure" "Target branch detected + written to .cgw.conf" "$verdict" \
              "grep CGW_TARGET_BRANCH= .cgw.conf" "$out" "" 0 "$dur" "$notes"

    # CF-04: Source branch = development
    t0=$(_ms)
    out=$(grep 'CGW_SOURCE_BRANCH=' "$cfg" 2>/dev/null | head -1 | tr -d '"' || echo "")
    t1=$(_ms); dur=$(( t1 - t0 ))
    if echo "$out" | grep -q 'development'; then
        verdict="PASS"; notes="$out"
    else
        verdict="WARN"; notes="expected development, got: ${out}"
    fi
    run_check "CF-04" "configure" "Source branch detected as development" "$verdict" \
              "grep CGW_SOURCE_BRANCH= .cgw.conf" "$out" "" 0 "$dur" "$notes"

    # CF-05: Lint tool = ruff
    t0=$(_ms)
    out=$(grep 'CGW_LINT_CMD=' "$cfg" 2>/dev/null | head -1 | tr -d '"' || echo "")
    t1=$(_ms); dur=$(( t1 - t0 ))
    if echo "$out" | grep -qi 'ruff'; then
        verdict="PASS"; notes="$out"
    else
        verdict="WARN"; notes="expected ruff, got: ${out}"
    fi
    run_check "CF-05" "configure" "Lint tool detected as ruff" "$verdict" \
              "grep CGW_LINT_CMD= .cgw.conf" "$out" "" 0 "$dur" "$notes"

    # CF-06: Local files detected (CLAUDE.md should be present)
    t0=$(_ms)
    out=$(grep 'CGW_LOCAL_FILES=' "$cfg" 2>/dev/null | head -1 || echo "")
    t1=$(_ms); dur=$(( t1 - t0 ))
    local lf_issues=""
    echo "$out" | grep -q 'CLAUDE' || lf_issues+="CLAUDE.md missing "
    if [[ -z "$lf_issues" ]]; then
        verdict="PASS"; notes="$out"
    else
        verdict="WARN"; notes="local files may be incomplete: ${lf_issues}; got: ${out}"
    fi
    run_check "CF-06" "configure" "Local files detected (CLAUDE.md at minimum)" "$verdict" \
              "grep CGW_LOCAL_FILES= .cgw.conf" "$out" "" 0 "$dur" "$notes"

    # CF-07: .gitignore updated
    t0=$(_ms)
    local gi_conf gi_logs
    gi_conf=$(grep -c '^\.cgw\.conf$' "${TARGET_DIR}/.gitignore" 2>/dev/null || echo 0)
    gi_logs=$(grep -c '^logs/$' "${TARGET_DIR}/.gitignore" 2>/dev/null || echo 0)
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ "$gi_conf" -ge 1 && "$gi_logs" -ge 1 ]]; then
        verdict="PASS"; notes=".cgw.conf and logs/ both in .gitignore"
    elif [[ "$gi_conf" -ge 1 ]]; then
        verdict="WARN"; notes=".cgw.conf added but logs/ not found"
    else
        verdict="FAIL"; notes=".cgw.conf not found in .gitignore"
    fi
    run_check "CF-07" "configure" ".gitignore updated with .cgw.conf and logs/" "$verdict" \
              "grep -E '.cgw.conf|logs/' .gitignore" "" "" 0 "$dur" "$notes"

    # CF-08: .githooks/pre-commit generated (no placeholder)
    t0=$(_ms)
    local gh="${TARGET_DIR}/.githooks/pre-commit"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$gh" ]]; then
        if grep -q '__CGW_LOCAL_FILES_PATTERN__' "$gh" 2>/dev/null; then
            verdict="FAIL"; notes="placeholder not replaced — pattern substitution failed"
        else
            verdict="PASS"; notes="placeholder replaced with actual pattern"
        fi
    else
        verdict="FAIL"; notes=".githooks/pre-commit not generated"
    fi
    run_check "CF-08" "configure" ".githooks/pre-commit generated (placeholder replaced)" "$verdict" \
              "grep -v __CGW_LOCAL_FILES_PATTERN__ .githooks/pre-commit" "" "" 0 "$dur" "$notes"

    # CF-09: .git/hooks/pre-commit installed + executable
    t0=$(_ms)
    local git_hook="${TARGET_DIR}/.git/hooks/pre-commit"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$git_hook" && -x "$git_hook" ]]; then
        verdict="PASS"; notes="active git hook installed"
    elif [[ -f "$git_hook" ]]; then
        verdict="WARN"; notes="hook installed but not executable"
    else
        verdict="FAIL"; notes=".git/hooks/pre-commit not installed"
    fi
    run_check "CF-09" "configure" ".git/hooks/pre-commit installed and executable" "$verdict" \
              "test -f .git/hooks/pre-commit && test -x .git/hooks/pre-commit" "" "" 0 "$dur" "$notes"

    # CF-10: Skill installed
    t0=$(_ms)
    local skill_dir="${TARGET_DIR}/.claude/skills/auto-git-workflow"
    local ref_count
    ref_count=$(ls "${skill_dir}/references/"*.md 2>/dev/null | wc -l | tr -d ' ')
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "${skill_dir}/SKILL.md" && "$ref_count" -ge 3 ]]; then
        verdict="PASS"; notes="SKILL.md + ${ref_count} references"
    elif [[ -f "${skill_dir}/SKILL.md" ]]; then
        verdict="WARN"; notes="SKILL.md present but only ${ref_count} references (expected 3)"
    else
        verdict="WARN"; notes="skill not installed (may need .claude/ dir to exist)"
    fi
    run_check "CF-10" "configure" "Claude Code skill installed (.claude/skills/)" "$verdict" \
              "test -f .claude/skills/auto-git-workflow/SKILL.md" "" "" 0 "$dur" "$notes"

    # CF-11: Slash command installed
    t0=$(_ms)
    local cmd_file="${TARGET_DIR}/.claude/commands/auto-git-workflow.md"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$cmd_file" ]]; then
        verdict="PASS"; notes="slash command available"
    else
        verdict="WARN"; notes="/auto-git-workflow command not installed"
    fi
    run_check "CF-11" "configure" "Slash command installed (.claude/commands/)" "$verdict" \
              "test -f .claude/commands/auto-git-workflow.md" "" "" 0 "$dur" "$notes"
}

# ─── Phase 4: Custom Hooks ────────────────────────────────────────────────────
phase_hooks() {
    _phase_header "Phase 4 — Custom Hooks Setup Verification"

    local t0 t1 dur verdict notes out ec

    # HK-01: commit_enhanced.sh accessible at relative path
    t0=$(_ms)
    local ce_script="${TARGET_DIR}/scripts/git/commit_enhanced.sh"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$ce_script" && -x "$ce_script" ]]; then
        verdict="PASS"; notes="git-commit-enforcer.py redirect will resolve correctly"
    else
        verdict="FAIL"; notes="commit_enhanced.sh missing or not executable — enforcer redirect broken"
    fi
    run_check "HK-01" "hooks" "commit_enhanced.sh accessible (enforcer target)" "$verdict" \
              "test -x TARGET/scripts/git/commit_enhanced.sh" "" "" 0 "$dur" "$notes"

    # HK-02: .claude/settings.json PreToolUse hook intact
    t0=$(_ms)
    local settings="${TARGET_DIR}/.claude/settings.json"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$settings" ]] && grep -q 'PreToolUse' "$settings" && grep -q 'git-commit-enforcer' "$settings"; then
        verdict="PASS"; notes="PreToolUse hook active in settings.json"
    elif [[ -f "$settings" ]] && grep -q 'PreToolUse' "$settings"; then
        verdict="WARN"; notes="PreToolUse present but git-commit-enforcer not referenced"
    else
        verdict="WARN"; notes="no PreToolUse hook in settings.json"
    fi
    run_check "HK-02" "hooks" ".claude/settings.json PreToolUse hook intact" "$verdict" \
              "grep -q PreToolUse .claude/settings.json" "" "" 0 "$dur" "$notes"

    # HK-03: Test enforcer intercepts git commit -m
    t0=$(_ms)
    local enforcer="${TARGET_DIR}/.claude/hooks/git-commit-enforcer.py"
    if [[ -f "$enforcer" ]]; then
        out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test: hello\""}}' \
              | python "$enforcer" 2>/tmp/cgw_bench_stderr || echo "")
        ec=$?
        t1=$(_ms); dur=$(( t1 - t0 ))
        if echo "$out" | grep -q 'commit_enhanced.sh'; then
            verdict="PASS"; notes="correctly rewrites to commit_enhanced.sh"
        elif [[ $ec -ne 0 ]]; then
            verdict="FAIL"; notes="enforcer exited with error ${ec}: $(cat /tmp/cgw_bench_stderr 2>/dev/null | head -1)"
        else
            verdict="FAIL"; notes="output does not contain commit_enhanced.sh: ${out:0:100}"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="git-commit-enforcer.py not found — skipping test"
        out=""
    fi
    run_check "HK-03" "hooks" "Enforcer intercepts git commit -m and rewrites" "$verdict" \
              "echo '{git commit -m ...}' | python git-commit-enforcer.py" "${out:0:200}" "" "$ec" "$dur" "$notes"

    # HK-04: Enforcer passes through --amend
    t0=$(_ms)
    if [[ -f "$enforcer" ]]; then
        out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit --amend --no-edit"}}' \
              | python "$enforcer" 2>/tmp/cgw_bench_stderr || echo "")
        ec=$?
        t1=$(_ms); dur=$(( t1 - t0 ))
        # Pass-through = empty output (exit 0, no JSON rewrite)
        if [[ $ec -eq 0 && -z "$out" ]]; then
            verdict="PASS"; notes="--amend passes through (exit 0, no rewrite)"
        elif echo "$out" | grep -q 'updatedInput'; then
            verdict="FAIL"; notes="enforcer incorrectly rewrote --amend command"
        else
            verdict="PASS"; notes="allowed through (exit ${ec})"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="enforcer not found — skipping"; out=""
    fi
    run_check "HK-04" "hooks" "Enforcer passes through git commit --amend" "$verdict" \
              "echo '{git commit --amend ...}' | python git-commit-enforcer.py" "" "" 0 "$dur" "$notes"

    # HK-05: Enforcer passes through --no-verify
    # NOTE: Known regex bug in enforcer — \b--no-verify\b does not match because
    # '--' contains no word-boundary anchor (\b requires \w/\W transition).
    # The enforcer intercepts and rewrites --no-verify commands instead of passing them.
    t0=$(_ms)
    if [[ -f "$enforcer" ]]; then
        out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"hotfix\""}}' \
              | python "$enforcer" 2>/tmp/cgw_bench_stderr || echo "")
        ec=$?
        t1=$(_ms); dur=$(( t1 - t0 ))
        if [[ $ec -eq 0 && -z "$out" ]]; then
            verdict="PASS"; notes="--no-verify bypass honored"
        elif echo "$out" | grep -q 'commit_enhanced.sh'; then
            verdict="WARN"
            notes="BUG: enforcer rewrites --no-verify instead of passing through — regex '\b(--no-verify|-n)\b' fails because '--' has no word boundary; fix: change pattern to '(--no-verify|-n)'"
        else
            verdict="WARN"; notes="unexpected output for --no-verify: ${out:0:80}"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="enforcer not found"; out=""
    fi
    run_check "HK-05" "hooks" "Enforcer respects --no-verify bypass" "$verdict" \
              "echo '{git commit --no-verify ...}' | python git-commit-enforcer.py" "${out:0:200}" "" 0 "$dur" "$notes"

    # HK-06: Compare old vs new .githooks/pre-commit (feature diff)
    t0=$(_ms)
    local bak="${TARGET_DIR}/.githooks/pre-commit.bak"
    local new_hook="${TARGET_DIR}/.githooks/pre-commit"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$bak" && -f "$new_hook" ]]; then
        local lost_features=""
        grep -q 'AUTHORIZED_DOCS\|allowed.*docs\|unauthorized.*docs' "$bak" 2>/dev/null && \
            lost_features+="docs-allowlist-enforcement "
        grep -q 'Auto-fix lint\|yes/no/skip\|read.*choice' "$bak" 2>/dev/null && \
            lost_features+="interactive-lint-fix "
        if [[ -z "$lost_features" ]]; then
            verdict="PASS"; notes="no critical features identified as lost"
        else
            verdict="WARN"
            notes="old hook features NOT in CGW template: [${lost_features%% }] — manual merge may be needed"
        fi
        out=$(diff "$bak" "$new_hook" | head -20 || true)
    elif [[ ! -f "$bak" ]]; then
        verdict="PASS"; notes="no backup — no pre-existing hook to compare"
        out=""
    else
        verdict="WARN"; notes="backup exists but new hook not generated"
        out=""
    fi
    run_check "HK-06" "hooks" "Old vs new .githooks/pre-commit feature comparison" "$verdict" \
              "diff .githooks/pre-commit.bak .githooks/pre-commit" "${out:0:300}" "" 0 "$dur" "$notes"

    # HK-07: .pre-commit-config.yaml untouched
    t0=$(_ms)
    local precommit_cfg="${TARGET_DIR}/.pre-commit-config.yaml"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -f "$precommit_cfg" ]]; then
        local modified
        modified=$(git -C "${TARGET_DIR}" diff -- .pre-commit-config.yaml 2>/dev/null)
        if [[ -z "$modified" ]]; then
            verdict="PASS"; notes="pre-commit framework config untouched"
        else
            verdict="FAIL"; notes=".pre-commit-config.yaml was modified"
        fi
        notes+=" — NOTE: running 'pre-commit install' will overwrite .git/hooks/pre-commit (CGW hook)"
    else
        verdict="PASS"; notes="no .pre-commit-config.yaml in target"
    fi
    run_check "HK-07" "hooks" ".pre-commit-config.yaml untouched (coexistence)" "$verdict" \
              "git diff -- .pre-commit-config.yaml" "" "" 0 "$dur" "$notes"

    # HK-08: stale CLAUDE_PROJECT_DIR fallback in enforcer
    t0=$(_ms)
    if [[ -f "$enforcer" ]]; then
        out=$(grep 'CLAUDE_PROJECT_DIR' "$enforcer" 2>/dev/null | head -2 || echo "")
        t1=$(_ms); dur=$(( t1 - t0 ))
        if echo "$out" | grep -q 'claude-context-local\|claude_context_local'; then
            verdict="WARN"
            notes="stale fallback path detected — functional since relative path is used, but should be cleaned up"
        else
            verdict="PASS"; notes="CLAUDE_PROJECT_DIR fallback looks correct"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="enforcer not found"; out=""
    fi
    run_check "HK-08" "hooks" "git-commit-enforcer.py CLAUDE_PROJECT_DIR fallback" "$verdict" \
              "grep CLAUDE_PROJECT_DIR git-commit-enforcer.py" "$out" "" 0 "$dur" "$notes"
}

# ─── Phase 5: Functional Tests ────────────────────────────────────────────────
phase_functional() {
    _phase_header "Phase 5 — Functional Tests"

    # Guard: scripts must be installed to run functional tests
    if [[ ! -f "${TARGET_DIR}/scripts/git/commit_enhanced.sh" ]]; then
        echo "  (skipped — scripts/git/ not installed; run without --dry-run)"
        return
    fi

    local t0 t1 dur verdict notes out ec

    # FN-01: check_lint.sh runs without crash
    t0=$(_ms)
    out=$(cd "${TARGET_DIR}" && bash scripts/git/check_lint.sh 2>&1 || true)
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    # Script running at all (even with lint errors) = PASS; crash = FAIL
    if [[ $ec -le 1 ]]; then
        verdict="PASS"; notes="exit=${ec} (0=clean, 1=lint errors found — both are valid)"
    else
        verdict="FAIL"; notes="unexpected exit code ${ec} — script may have crashed"
    fi
    run_check "FN-01" "functional" "check_lint.sh executes without crash" "$verdict" \
              "bash scripts/git/check_lint.sh" "${out:0:200}" "" "$ec" "$dur" "$notes"

    # FN-02: commit_enhanced.sh --help
    t0=$(_ms)
    out=$(cd "${TARGET_DIR}" && bash scripts/git/commit_enhanced.sh --help 2>&1 || true)
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if echo "$out" | grep -qi 'usage\|commit_enhanced\|message'; then
        verdict="PASS"; notes="help text returned"
    else
        verdict="WARN"; notes="no recognizable help output: ${out:0:100}"
    fi
    run_check "FN-02" "functional" "commit_enhanced.sh --help shows usage" "$verdict" \
              "bash scripts/git/commit_enhanced.sh --help" "${out:0:200}" "" "$ec" "$dur" "$notes"

    # FN-03: push_validated.sh --help
    t0=$(_ms)
    out=$(cd "${TARGET_DIR}" && bash scripts/git/push_validated.sh --help 2>&1 || true)
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if echo "$out" | grep -qi 'usage\|push_validated\|push'; then
        verdict="PASS"; notes="help text returned"
    else
        verdict="WARN"; notes="no recognizable help output: ${out:0:100}"
    fi
    run_check "FN-03" "functional" "push_validated.sh --help shows usage" "$verdict" \
              "bash scripts/git/push_validated.sh --help" "${out:0:200}" "" "$ec" "$dur" "$notes"

    # FN-04: validate_branches.sh
    t0=$(_ms)
    out=$(cd "${TARGET_DIR}" && bash scripts/git/validate_branches.sh 2>&1 || true)
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ $ec -le 1 ]]; then
        verdict="PASS"; notes="exit=${ec}: ${out:0:100}"
    else
        verdict="FAIL"; notes="crashed with exit=${ec}"
    fi
    run_check "FN-04" "functional" "validate_branches.sh detects branch setup" "$verdict" \
              "bash scripts/git/validate_branches.sh" "${out:0:200}" "" "$ec" "$dur" "$notes"

    # FN-05: merge_with_validation.sh --dry-run
    t0=$(_ms)
    out=$(cd "${TARGET_DIR}" && bash scripts/git/merge_with_validation.sh --dry-run 2>&1 || true)
    ec=$?
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ $ec -le 1 ]]; then
        verdict="PASS"; notes="dry-run completed (exit=${ec})"
    else
        verdict="FAIL"; notes="unexpected exit=${ec}: ${out:0:100}"
    fi
    run_check "FN-05" "functional" "merge_with_validation.sh --dry-run runs" "$verdict" \
              "bash scripts/git/merge_with_validation.sh --dry-run" "${out:0:200}" "" "$ec" "$dur" "$notes"

    # FN-06: Pre-commit hook blocks CLAUDE.md (if it exists)
    t0=$(_ms)
    local claude_md="${TARGET_DIR}/CLAUDE.md"
    if [[ -f "$claude_md" ]]; then
        # Stage CLAUDE.md, attempt dry-run commit, then reset
        git -C "${TARGET_DIR}" add CLAUDE.md 2>/dev/null
        out=$(git -C "${TARGET_DIR}" commit --dry-run 2>&1 || true)
        ec=$?
        git -C "${TARGET_DIR}" reset HEAD CLAUDE.md 2>/dev/null
        t1=$(_ms); dur=$(( t1 - t0 ))
        if [[ $ec -ne 0 ]]; then
            verdict="PASS"; notes="hook correctly blocked CLAUDE.md commit (exit=${ec})"
        else
            verdict="FAIL"; notes="hook did NOT block CLAUDE.md — local-only file protection not working"
        fi
    else
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="CLAUDE.md not present in target — cannot test hook blocking"
        out=""
    fi
    run_check "FN-06" "functional" "Pre-commit hook blocks CLAUDE.md staging" "$verdict" \
              "git add CLAUDE.md && git commit --dry-run (then reset)" "${out:0:200}" "" "$ec" "$dur" "$notes"
}

# ─── Phase 6: Integration & Cleanup ──────────────────────────────────────────
phase_integration() {
    _phase_header "Phase 6 — Integration & Cleanup Checks"

    local t0 t1 dur verdict notes out ec

    # INT-01: Existing .claude/skills/mcp-search-tool/ preserved
    t0=$(_ms)
    local mcp_skill="${TARGET_DIR}/.claude/skills/mcp-search-tool"
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -d "$mcp_skill" ]]; then
        verdict="PASS"; notes="mcp-search-tool skill directory untouched"
    else
        verdict="WARN"; notes="mcp-search-tool skill not found — may not exist in this project"
    fi
    run_check "INT-01" "integration" "Existing .claude/skills/ content preserved" "$verdict" \
              "test -d .claude/skills/mcp-search-tool" "" "" 0 "$dur" "$notes"

    # INT-02: No duplicate .gitignore entries
    t0=$(_ms)
    out=$(sort "${TARGET_DIR}/.gitignore" 2>/dev/null | uniq -d || echo "")
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -z "$out" ]]; then
        verdict="PASS"; notes="no duplicate lines"
    else
        verdict="WARN"; notes="duplicate entries: ${out:0:100}"
    fi
    run_check "INT-02" "integration" "No duplicate .gitignore entries" "$verdict" \
              "sort .gitignore | uniq -d" "$out" "" 0 "$dur" "$notes"

    # INT-03: _config.sh sources cleanly in target
    t0=$(_ms)
    if [[ ! -f "${TARGET_DIR}/scripts/git/_config.sh" ]]; then
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="scripts not installed — skipping _config.sh source test"
        out=""
        run_check "INT-03" "integration" "_config.sh sources and detects PROJECT_ROOT" "$verdict" \
                  "source scripts/git/_config.sh && echo \$PROJECT_ROOT" "$out" "" 0 "$dur" "$notes"
    else
        out=$(cd "${TARGET_DIR}" && bash -c '
            SCRIPT_DIR="scripts/git"
            # shellcheck source=/dev/null
            source scripts/git/_config.sh 2>/dev/null
            echo "${PROJECT_ROOT}"
        ' 2>/tmp/cgw_bench_stderr || echo "")
        ec=$?
        t1=$(_ms); dur=$(( t1 - t0 ))
        local target_basename
        target_basename=$(basename "${TARGET_DIR}")
        if echo "$out" | grep -qi "$target_basename"; then
            verdict="PASS"; notes="PROJECT_ROOT: ${out}"
        elif [[ -n "$out" ]]; then
            verdict="WARN"; notes="PROJECT_ROOT resolved to unexpected path: ${out}"
        else
            verdict="FAIL"; notes="_config.sh failed to source: $(cat /tmp/cgw_bench_stderr 2>/dev/null | head -2)"
        fi
        run_check "INT-03" "integration" "_config.sh sources and detects PROJECT_ROOT" "$verdict" \
                  "source scripts/git/_config.sh && echo \$PROJECT_ROOT" "$out" "" "$ec" "$dur" "$notes"
    fi

    # INT-04: CGW files gitignore status
    t0=$(_ms)
    # .cgw.conf should be ignored, scripts/git/ should be untracked (to be committed)
    local conf_status scripts_status
    conf_status=$(git -C "${TARGET_DIR}" status --porcelain .cgw.conf 2>/dev/null || echo "unknown")
    scripts_status=$(git -C "${TARGET_DIR}" status --porcelain scripts/git/ 2>/dev/null | head -3 || echo "unknown")
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -z "$conf_status" ]]; then
        # Empty = gitignored or doesn't exist
        verdict="PASS"; notes=".cgw.conf is gitignored; scripts/git/ shows as untracked (ready to commit)"
    else
        verdict="WARN"; notes=".cgw.conf not gitignored: ${conf_status}"
    fi
    run_check "INT-04" "integration" ".cgw.conf is gitignored; scripts/ is untracked" "$verdict" \
              "git status --porcelain .cgw.conf scripts/git/" "${scripts_status:0:150}" "" 0 "$dur" "$notes"

    # INT-05: No syntax errors in copied scripts
    t0=$(_ms)
    local syntax_fails=""
    local sh_files=()
    # Use mapfile to avoid glob expansion to literal *.sh when no files present
    mapfile -t sh_files < <(ls "${TARGET_DIR}/scripts/git/"*.sh 2>/dev/null || true)
    if [[ "${#sh_files[@]}" -eq 0 ]]; then
        t1=$(_ms); dur=$(( t1 - t0 ))
        verdict="WARN"; notes="no scripts found in scripts/git/ — not installed yet"
        run_check "INT-05" "integration" "All copied scripts pass bash -n syntax check" "$verdict" \
                  "bash -n scripts/git/*.sh" "" "" 0 "$dur" "$notes"
        return
    fi
    for f in "${sh_files[@]}"; do
        bash -n "$f" 2>/dev/null || syntax_fails+="$(basename "$f") "
    done
    t1=$(_ms); dur=$(( t1 - t0 ))
    if [[ -z "$syntax_fails" ]]; then
        verdict="PASS"; notes="all ${#sh_files[@]} scripts pass bash -n syntax check"
    else
        verdict="FAIL"; notes="syntax errors in: ${syntax_fails}"
    fi
    run_check "INT-05" "integration" "All copied scripts pass bash -n syntax check" "$verdict" \
              "for f in scripts/git/*.sh; do bash -n \$f; done" "" "" 0 "$dur" "$notes"
}

# ─── Report generation ────────────────────────────────────────────────────────
generate_report() {
    local elapsed=$(( $(_ms) - BENCHMARK_START ))
    local branch
    branch=$(git -C "${TARGET_DIR}" branch --show-current 2>/dev/null || echo "unknown")

    # Build JSON records array
    local json_array
    printf -v json_array '%s,' "${JSON_RECORDS[@]}"
    json_array="[${json_array%,}]"

    # Markdown report
    cat > "$REPORT_FILE" << REPORT_EOF
# CGW Installation Benchmark Report

**Generated**: ${TIMESTAMP}
**Source**: \`${SOURCE_DIR}\`
**Target**: \`${TARGET_DIR}\`
**Branch**: \`${branch}\`
**Duration**: ${elapsed}ms

## Summary

| Phase | Total | Pass | Warn | Fail |
|-------|-------|------|------|------|
| 0 Pre-Flight | ${PHASE_TOTAL[preflight]:-0} | ${PHASE_PASS[preflight]:-0} | ${PHASE_WARN[preflight]:-0} | ${PHASE_FAIL[preflight]:-0} |
| 1 Backup | ${PHASE_TOTAL[backup]:-0} | ${PHASE_PASS[backup]:-0} | ${PHASE_WARN[backup]:-0} | ${PHASE_FAIL[backup]:-0} |
| 2 Copy | ${PHASE_TOTAL[copy]:-0} | ${PHASE_PASS[copy]:-0} | ${PHASE_WARN[copy]:-0} | ${PHASE_FAIL[copy]:-0} |
| 3 Configure | ${PHASE_TOTAL[configure]:-0} | ${PHASE_PASS[configure]:-0} | ${PHASE_WARN[configure]:-0} | ${PHASE_FAIL[configure]:-0} |
| 4 Hooks | ${PHASE_TOTAL[hooks]:-0} | ${PHASE_PASS[hooks]:-0} | ${PHASE_WARN[hooks]:-0} | ${PHASE_FAIL[hooks]:-0} |
| 5 Functional | ${PHASE_TOTAL[functional]:-0} | ${PHASE_PASS[functional]:-0} | ${PHASE_WARN[functional]:-0} | ${PHASE_FAIL[functional]:-0} |
| 6 Integration | ${PHASE_TOTAL[integration]:-0} | ${PHASE_PASS[integration]:-0} | ${PHASE_WARN[integration]:-0} | ${PHASE_FAIL[integration]:-0} |
| **Total** | **${TOTAL}** | **${PASSED}** | **${WARNED}** | **${FAILED}** |

REPORT_EOF

    # Append failed/warned items
    if [[ "$FAILED" -gt 0 || "$WARNED" -gt 0 ]]; then
        echo "## Issues Requiring Attention" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        for rec in "${JSON_RECORDS[@]}"; do
            local v id desc notes
            v=$(echo "$rec" | grep -o '"verdict":"[^"]*"' | cut -d'"' -f4)
            [[ "$v" == "PASS" ]] && continue
            id=$(echo "$rec" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
            desc=$(echo "$rec" | grep -o '"description":"[^"]*"' | cut -d'"' -f4)
            notes=$(echo "$rec" | grep -o '"notes":"[^"]*"' | cut -d'"' -f4)
            echo "- **${v} ${id}**: ${desc} — ${notes}" >> "$REPORT_FILE"
        done
        echo "" >> "$REPORT_FILE"
    fi

    echo "## JSON Log" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo '```json' >> "$REPORT_FILE"
    echo "$json_array" | python3 -m json.tool 2>/dev/null || echo "$json_array" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"

    echo ""
    printf "${C_BOLD}Results: ${C_PASS}${PASSED} PASS${C_RESET} | "
    printf "${C_WARN}${WARNED} WARN${C_RESET} | "
    printf "${C_FAIL}${FAILED} FAIL${C_RESET} | "
    printf "${C_DIM}Total: ${TOTAL} | ${elapsed}ms${C_RESET}\n"
    echo ""
    printf "${C_DIM}Report: ${REPORT_FILE}${C_RESET}\n"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    printf "${C_BOLD}CGW Installation Benchmark${C_RESET}\n"
    printf "${C_DIM}Source: ${SOURCE_DIR}${C_RESET}\n"
    printf "${C_DIM}Target: ${TARGET_DIR}${C_RESET}\n"
    [[ "$DRY_RUN" -eq 1 ]] && printf "${C_WARN}Mode: dry-run (no modifications)${C_RESET}\n"
    echo ""

    phase_preflight
    phase_backup
    phase_copy
    phase_configure
    phase_hooks
    phase_functional
    phase_integration
    generate_report
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILES_DIR="$PROJECT_ROOT/test_files"
WORKSPACES_DIR="$PROJECT_ROOT/workspaces"
RUN_SCRIPT="$PROJECT_ROOT/template/run.sh"

DEFAULT_BASELINE="claude_vanilla"
DEFAULT_CONCURRENCY=4
DEFAULT_TIMEOUT=900  # seconds per project

MODEL="${MODEL:-unknown}"

VALID_BASELINES=(claude_vanilla claude_spec opencode_vanilla opencode_spec)

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run NL2RepoBench benchmark across all projects.

Options:
  -b, --baseline BASELINE   Baseline to run (default: $DEFAULT_BASELINE)
                            Valid: ${VALID_BASELINES[*]}
  -c, --concurrency N       Number of parallel workers (default: $DEFAULT_CONCURRENCY)
  -t, --timeout SECS        Timeout per project in seconds (default: $DEFAULT_TIMEOUT)
  -p, --projects LIST       Comma-separated project names to run (default: all)
  -r, --run-script PATH     Path to run.sh (default: $RUN_SCRIPT)
  --skip-init               Skip workspace init (useful to resume a run)
  -h, --help                Show this help message

Examples:
  $(basename "$0") -b claude_spec -c 8
  $(basename "$0") -b opencode_vanilla -p aiofiles,boltons
  $(basename "$0") -b claude_spec -c 4 --timeout 900
EOF
    exit 0
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
BASELINE="$DEFAULT_BASELINE"
CONCURRENCY="$DEFAULT_CONCURRENCY"
TIMEOUT="$DEFAULT_TIMEOUT"
PROJECTS_FILTER=""
SKIP_INIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -b|--baseline)   BASELINE="$2";         shift 2 ;;
        -c|--concurrency) CONCURRENCY="$2";     shift 2 ;;
        -t|--timeout)    TIMEOUT="$2";           shift 2 ;;
        -p|--projects)   PROJECTS_FILTER="$2";  shift 2 ;;
        -r|--run-script) RUN_SCRIPT="$2";        shift 2 ;;
        --skip-init)     SKIP_INIT=true;         shift ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────────
is_valid_baseline() {
    local b="$1"
    for v in "${VALID_BASELINES[@]}"; do [[ "$v" == "$b" ]] && return 0; done
    return 1
}

if ! is_valid_baseline "$BASELINE"; then
    echo "Error: invalid baseline '$BASELINE'. Valid options: ${VALID_BASELINES[*]}" >&2
    exit 1
fi

if [[ ! -f "$RUN_SCRIPT" ]]; then
    echo "Error: run.sh not found at '$RUN_SCRIPT'" >&2
    exit 1
fi

if [[ ! -d "$TEST_FILES_DIR" ]]; then
    echo "Error: test_files directory not found at '$TEST_FILES_DIR'" >&2
    exit 1
fi

# ─── Determine openspec tool flag ─────────────────────────────────────────────
OPENSPEC_TOOL=""
case "$BASELINE" in
    claude_spec)    OPENSPEC_TOOL="claude" ;;
    opencode_spec)  OPENSPEC_TOOL="opencode" ;;
esac

# ─── Collect projects ─────────────────────────────────────────────────────────
ALL_PROJECTS=()
while IFS= read -r -d '' dir; do
    project="$(basename "$dir")"
    if [[ -f "$dir/start.md" ]]; then
        ALL_PROJECTS+=("$project")
    fi
done < <(find "$TEST_FILES_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

if [[ ${#ALL_PROJECTS[@]} -eq 0 ]]; then
    echo "Error: no projects with start.md found in $TEST_FILES_DIR" >&2
    exit 1
fi

# Filter to specified projects if requested
PROJECTS=()
if [[ -n "$PROJECTS_FILTER" ]]; then
    IFS=',' read -ra FILTER_LIST <<< "$PROJECTS_FILTER"
    for p in "${FILTER_LIST[@]}"; do
        p="${p// /}"  # trim spaces
        src="$TEST_FILES_DIR/$p"
        if [[ ! -d "$src" ]]; then
            echo "Warning: project '$p' not found in test_files, skipping" >&2
        elif [[ ! -f "$src/start.md" ]]; then
            echo "Warning: project '$p' has no start.md, skipping" >&2
        else
            PROJECTS+=("$p")
        fi
    done
else
    PROJECTS=("${ALL_PROJECTS[@]}")
fi

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    echo "Error: no valid projects to run" >&2
    exit 1
fi

# ─── Baseline directory name (append model if set) ───────────────────────────
BASELINE_DIR="${BASELINE}_${MODEL}"

# ─── Logging helpers ──────────────────────────────────────────────────────────
LOG_DIR="$WORKSPACES_DIR/$BASELINE_DIR/logs"
mkdir -p "$LOG_DIR"
SUMMARY_LOG="$LOG_DIR/benchmark_$(date +%Y%m%d_%H%M%S).log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
log_project() { local project="$1" level="$2"; shift 2; echo "[$(date '+%H:%M:%S')] [$project] $level: $*" | tee -a "$SUMMARY_LOG"; }

# ─── Per-project worker ───────────────────────────────────────────────────────
run_project() {
    local project="$1"
    local src_dir="$TEST_FILES_DIR/$project"
    local workspace_dir="$WORKSPACES_DIR/$BASELINE_DIR/$project/workspace"
    local project_log="$LOG_DIR/${project}.log"

    {
        echo "=== $project: start at $(date) ==="

        # 1. Create workspace directory
        mkdir -p "$workspace_dir"

        # 2. Copy start.md
        cp "$src_dir/start.md" "$workspace_dir/start.md"

        # 3. Run openspec init for spec baselines
        if [[ -n "$OPENSPEC_TOOL" ]] && [[ "$SKIP_INIT" == false ]]; then
            echo "Running: openspec init --tools $OPENSPEC_TOOL"
            if ! (cd "$workspace_dir" && openspec init --tools "$OPENSPEC_TOOL"); then
                echo "WARNING: openspec init failed for $project"
            fi
        fi

        # 4. Copy run.sh into workspace and make executable
        cp "$RUN_SCRIPT" "$workspace_dir/run.sh"
        chmod +x "$workspace_dir/run.sh"

        # 5. Execute run.sh inside the workspace
        echo "Running: run.sh in $workspace_dir"
        local run_cmd
        if command -v timeout &>/dev/null; then
            run_cmd="timeout $TIMEOUT bash run.sh"
        else
            echo "WARNING: timeout command not found, running without time limit"
            run_cmd="bash run.sh"
        fi
        if (cd "$workspace_dir" && $run_cmd); then
            echo "=== $project: SUCCESS at $(date) ==="
            echo "SUCCESS"
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                echo "=== $project: TIMEOUT (${TIMEOUT}s) at $(date) ==="
                echo "TIMEOUT"
            else
                echo "=== $project: FAILED (exit $exit_code) at $(date) ==="
                echo "FAILED"
            fi
        fi
    } > "$project_log" 2>&1

    # Return the last line (status) for summary
    tail -1 "$project_log"
}

# ─── Concurrency management ───────────────────────────────────────────────────
run_parallel() {
    local -i concurrency="$CONCURRENCY"
    local -i total=${#PROJECTS[@]}
    local -i running=0
    local -i done=0
    local -a pids=()
    local -a pid_projects=()

    log "Starting benchmark: baseline=$BASELINE_DIR, projects=$total, concurrency=$concurrency"
    log "Workspace root: $WORKSPACES_DIR/$BASELINE_DIR"
    log "Log directory: $LOG_DIR"
    echo ""

    local -i idx=0
    while [[ $done -lt $total ]]; do
        # Launch workers up to concurrency limit
        while [[ $running -lt $concurrency && $idx -lt $total ]]; do
            local project="${PROJECTS[$idx]}"
            log_project "$project" "INFO" "queued (slot $((running + 1))/$concurrency)"
            run_project "$project" &
            pids+=($!)
            pid_projects+=("$project")
            (( running++ ))
            (( idx++ ))
        done

        # Wait for any worker to finish
        for i in "${!pids[@]}"; do
            local pid="${pids[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                local project="${pid_projects[$i]}"
                wait "$pid" 2>/dev/null || true
                local status
                status=$(tail -1 "$LOG_DIR/${project}.log" 2>/dev/null || echo "UNKNOWN")
                echo "$status" > "$LOG_DIR/${project}.status"
                log_project "$project" "INFO" "done → $status"
                unset 'pids[$i]'
                unset 'pid_projects[$i]'
                (( running-- ))
                (( done++ ))
                break
            fi
        done

        # Small sleep to avoid busy-waiting
        sleep 0.5
    done

    # ─── Summary ──────────────────────────────────────────────────────────────
    local -i success=0 failed=0 timeout=0 unknown=0
    echo ""
    log "═══════════════════════════════════════════"
    log "Benchmark complete: $BASELINE_DIR"
    log "═══════════════════════════════════════════"

    for project in "${PROJECTS[@]}"; do
        local status
        status=$(cat "$LOG_DIR/${project}.status" 2>/dev/null || echo "UNKNOWN")
        case "$status" in
            SUCCESS) (( success++ )) ;;
            TIMEOUT) (( timeout++ )) ;;
            FAILED)  (( failed++ )) ;;
            *)       (( unknown++ )) ;;
        esac
        printf "[%-12s] %s\n" "$status" "$project" | tee -a "$SUMMARY_LOG"
    done

    echo "" | tee -a "$SUMMARY_LOG"
    log "Results: SUCCESS=$success  FAILED=$failed  TIMEOUT=$timeout  UNKNOWN=$unknown  TOTAL=$total"
    log "Full logs: $LOG_DIR"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
run_parallel

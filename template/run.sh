#!/usr/bin/env bash
# run.sh — Run an unattended agent workflow on Claude Code or
#          OpenCode, with per-step token/cost tracking.
#
#          Two modes:
#            MODE=opsx    (default) — OpenSpec workflow:
#                          propose → apply → sync → archive
#            MODE=oneshot           — one user-supplied prompt,
#                          start-to-finish in a single agent turn
#
# Usage:
#   ./run.sh <spec.md> [change-name]
#
# Pick a mode (default: opsx):
#   MODE=opsx     ./run.sh spec.md
#   MODE=oneshot  ./run.sh spec.md
#
# Pick a runner (auto-detected if unset):
#   RUNNER=claude   ./run.sh spec.md      # uses `claude -p`
#   RUNNER=opencode ./run.sh spec.md      # uses `opencode run`
#
# Specify a model:
#   Claude Code:  MODEL=claude-opus-4-7
#   OpenCode:     MODEL=anthropic/claude-opus-4-7   (provider/model format)
#
# Other env vars:
#   CLAUDE_BIN       Path to claude binary    (default: claude)
#   OPENCODE_BIN     Path to opencode binary  (default: opencode)
#   CLAUDE_MODEL     Back-compat alias for MODEL (only when RUNNER=claude)
#   OPSX_SKIP_SYNC   "1" to skip the explicit sync step (opsx mode only)
#
# Outputs (per run, under .opsx-auto-logs/):
#   <run-id>-<change>-<step>.json      raw JSON / JSONL from the runner
#   <run-id>-<change>-<step>.stderr    stderr from the runner
#   <run-id>-<change>-tokens.csv       per-step usage + cost
#   <run-id>-<change>-summary.txt      totals across all steps
#
# Prerequisites:
#   - /bin/sh, python3 (stdlib only — no jq required)
#   - one of:
#       claude   (npm i -g @anthropic-ai/claude-code)
#       opencode (https://opencode.ai/docs/)
#   - opsx mode only: an initialized OpenSpec project (openspec init)
#
# WARNING: uses --dangerously-skip-permissions. Run in a clean git repo,
# container, or sandbox. The runner can modify/delete files unattended.

set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  ✏️  ONESHOT PROMPT — edit me when using MODE=oneshot            ║
# ╚══════════════════════════════════════════════════════════════════╝
# This function is called only when MODE=oneshot. By the time it runs,
# $SPEC_FILE / $SPEC_CONTENT / $CHANGE_NAME / $RUNNER / $MODEL are all
# populated, so feel free to reference them inside the heredoc.
#
# To customize the agent's behavior, edit ONLY the body of the heredoc
# below (between the `cat <<EOF` and the closing `EOF`).
build_oneshot_prompt() {
  cat <<EOF
According to the start.md in the workspace, implement the entire project as per the requirements specified in the document, ensuring that the final product can be directly run in the current directory. The running requirements should comply with the <API Usage Guide> section of the document. Please complete this task step by step. Do NOT ask any clarifying questions. When something is unclear, make a reasonable assumption and document it in design.md under an Assumptions section.
EOF
}
# ╚══════════════════════════════════════════════════════════════════╝

# ───────────────── Args ─────────────────
SPEC_FILE="${1:-start.md}"
CHANGE_NAME="${2:-}"
MODE="${MODE:-opsx}"

case "$MODE" in
  opsx|oneshot) ;;
  *)
    echo "ERROR: unknown MODE '$MODE' (expected: opsx | oneshot)" >&2
    exit 1
    ;;
esac

# ───────────────── Runner selection ─────────────────
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
OPENCODE_BIN="${OPENCODE_BIN:-opencode}"

if [[ -z "${RUNNER:-}" ]]; then
  if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    RUNNER=claude
  elif command -v "$OPENCODE_BIN" >/dev/null 2>&1; then
    RUNNER=opencode
  else
    echo "ERROR: neither '$CLAUDE_BIN' nor '$OPENCODE_BIN' found on PATH." >&2
    echo "  Install one, or set RUNNER=claude|opencode explicitly." >&2
    exit 1
  fi
fi

case "$RUNNER" in
  claude)   RUNNER_BIN="$CLAUDE_BIN" ;;
  opencode) RUNNER_BIN="$OPENCODE_BIN" ;;
  *)
    echo "ERROR: unknown RUNNER '$RUNNER' (expected: claude | opencode)" >&2
    exit 1
    ;;
esac

# Back-compat: CLAUDE_MODEL → MODEL when running claude
if [[ -z "${MODEL:-}" && -n "${CLAUDE_MODEL:-}" && "$RUNNER" == "claude" ]]; then
  MODEL="$CLAUDE_MODEL"
fi

# ───────────────── Preflight ─────────────────
if ! command -v "$RUNNER_BIN" >/dev/null 2>&1; then
  case "$RUNNER" in
    claude)   echo "ERROR: '$RUNNER_BIN' not found. Install: npm i -g @anthropic-ai/claude-code" >&2 ;;
    opencode) echo "ERROR: '$RUNNER_BIN' not found. See: https://opencode.ai/docs/" >&2 ;;
  esac
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: 'python3' is required for JSON parsing (stdlib only, no extra packages)." >&2
  exit 1
fi
if [[ ! -f "$SPEC_FILE" ]]; then
  echo "ERROR: spec file not found: $SPEC_FILE" >&2
  exit 1
fi
if [[ "$MODE" == "opsx" && ! -d "openspec" ]]; then
  if ! command -v openspec >/dev/null 2>&1; then
    echo "ERROR: not an OpenSpec project (no openspec/ dir) and 'openspec' CLI not on PATH." >&2
    echo "  Install it (npm i -g @openspecai/openspec) or set MODE=oneshot to skip." >&2
    exit 1
  fi
  echo "▶ openspec/ not found — running 'openspec init --tools $RUNNER --force'..."
  if ! openspec init --tools "$RUNNER" --force; then
    echo "ERROR: 'openspec init --tools $RUNNER --force' failed." >&2
    exit 1
  fi
  if [[ ! -d "openspec" ]]; then
    echo "ERROR: openspec init did not create an openspec/ directory." >&2
    exit 1
  fi
  echo "▶ openspec initialized for runner '$RUNNER'."
  echo
fi

# ───────────────── Derive change-name ─────────────────
if [[ -z "$CHANGE_NAME" ]]; then
  base=$(basename "$SPEC_FILE" .md)
  if [[ "$base" == "start" || "$base" == "spec" || "$base" == "requirements" ]]; then
    CHANGE_NAME="auto-$(date +%Y%m%d-%H%M%S)"
  else
    CHANGE_NAME=$(echo "$base" \
      | tr '[:upper:]' '[:lower:]' \
      | tr ' _' '--' \
      | sed 's/[^a-z0-9-]//g')
  fi
fi

# ───────────────── Logging ─────────────────
LOG_DIR=".opsx-auto-logs"
mkdir -p "$LOG_DIR"
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_PREFIX="$LOG_DIR/${RUN_ID}-${CHANGE_NAME}"
USAGE_CSV="${LOG_PREFIX}-tokens.csv"
SUMMARY_TXT="${LOG_PREFIX}-summary.txt"

echo "step,model,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,cost_usd,duration_sec" > "$USAGE_CSV"

echo "▶ mode        : $MODE"
echo "▶ runner      : $RUNNER ($RUNNER_BIN)"
echo "▶ change-name : $CHANGE_NAME"
echo "▶ spec file   : $SPEC_FILE"
echo "▶ model       : ${MODEL:-<$RUNNER default>}"
echo "▶ logs/usage  : $LOG_PREFIX-*"
echo

# ───────────────── Runner invocation ─────────────────
# Builds RUN_CMD array and executes it; writes JSON to $1, stderr to $2.
invoke_runner() {
  local json_log="$1" err_log="$2" prompt="$3"
  local -a RUN_CMD
  case "$RUNNER" in
    claude)
      RUN_CMD=("$RUNNER_BIN" -p --dangerously-skip-permissions --output-format json)
      [[ -n "${MODEL:-}" ]] && RUN_CMD+=(--model "$MODEL")
      RUN_CMD+=("$prompt")
      ;;
    opencode)
      RUN_CMD=("$RUNNER_BIN" run --format json --dangerously-skip-permissions)
      [[ -n "${MODEL:-}" ]] && RUN_CMD+=(--model "$MODEL")
      RUN_CMD+=("$prompt")
      ;;
  esac
  "${RUN_CMD[@]}" > "$json_log" 2> "$err_log"
}

# ───────────────── JSON validation (no jq, just python3) ─────────────────
validate_output() {
  local path="$1"
  case "$RUNNER" in
    claude)
      # Claude Code: single JSON object
      python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$path" 2>/dev/null
      ;;
    opencode)
      # OpenCode: JSONL — at least one parseable line
      python3 - "$path" 2>/dev/null <<'PY'
import json, sys
ok = False
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            json.loads(line)
            ok = True
            break
        except json.JSONDecodeError:
            pass
sys.exit(0 if ok else 1)
PY
      ;;
  esac
}

# ───────────────── Usage extraction ─────────────────
# Both parsers write the same 7-line schema to stdout:
#   line 1: model
#   line 2: input_tokens
#   line 3: output_tokens
#   line 4: cache_creation_tokens
#   line 5: cache_read_tokens
#   line 6: cost_usd          (formatted as %.6f)
#   line 7: "---RESULT---"    (separator)
#   line 8..: result text     (may be multi-line)

parse_usage_claude() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'r') as f:
    data = json.load(f)

# Model detection: prefer .modelUsage key, fall back to .model.
model = "unknown"
mu = data.get("modelUsage") or data.get("model_usage") or {}
if isinstance(mu, dict) and mu:
    model = next(iter(mu.keys()))
if model == "unknown":
    model = data.get("model") or "unknown"

# Prefer top-level .usage; fall back to summing .modelUsage[*].
# (Avoid recursive descent — .usage and .modelUsage mirror each other
#  and recursion would double-count.)
def field(name):
    u = data.get("usage") or {}
    if isinstance(u, dict) and name in u:
        v = u.get(name) or 0
        return int(v) if isinstance(v, (int, float)) else 0
    total = 0
    for v in (data.get("modelUsage") or {}).values():
        if isinstance(v, dict):
            x = v.get(name) or 0
            if isinstance(x, (int, float)):
                total += int(x)
    return total

in_tok  = field("input_tokens")
out_tok = field("output_tokens")
cc_tok  = field("cache_creation_input_tokens")
cr_tok  = field("cache_read_input_tokens")
cost    = data.get("total_cost_usd")
if cost is None:
    cost = data.get("cost_usd", 0)
result = data.get("result") or "(no .result field)"

print(model)
print(in_tok)
print(out_tok)
print(cc_tok)
print(cr_tok)
print(f"{float(cost):.6f}")
print("---RESULT---")
print(result, end="")
PY
}

parse_usage_opencode() {
  python3 - "$1" "${MODEL:-}" <<'PY'
import json, sys
path = sys.argv[1]
fallback_model = sys.argv[2] if len(sys.argv) > 2 else ""

in_tok = out_tok = cc_tok = cr_tok = 0
cost = 0.0
texts = []
model_id = ""

# OpenCode emits one JSON event per line. The schema we care about:
#   {"type":"step_finish", "part":{"cost":<float>,
#                                  "tokens":{"input":N,"output":N,
#                                            "reasoning":N,
#                                            "cache":{"read":N,"write":N}}}}
#   {"type":"text", "part":{"type":"text","text":"..."}}
# Model name isn't reliably exposed; we fall back to whatever was passed
# in via MODEL, else "unknown".
with open(path, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type", "")
        part = ev.get("part") or {}
        # Opportunistically pick up a model id if we see one anywhere.
        for src in (ev, part):
            if isinstance(src, dict) and not model_id:
                m = src.get("modelID") or src.get("model_id") or src.get("model")
                if isinstance(m, str) and m:
                    model_id = m
        if t == "step_finish":
            toks = part.get("tokens") or {}
            in_tok  += int(toks.get("input", 0) or 0)
            out_tok += int(toks.get("output", 0) or 0)
            cache = toks.get("cache") or {}
            cr_tok += int(cache.get("read", 0) or 0)
            cc_tok += int(cache.get("write", 0) or 0)
            c = part.get("cost", 0)
            try:
                cost += float(c or 0)
            except (TypeError, ValueError):
                pass
        elif t == "text":
            txt = part.get("text") or ""
            if txt:
                texts.append(txt)

model = model_id or fallback_model or "unknown"
result = "\n".join(texts) if texts else "(no text output)"

print(model)
print(in_tok)
print(out_tok)
print(cc_tok)
print(cr_tok)
print(f"{cost:.6f}")
print("---RESULT---")
print(result, end="")
PY
}

parse_usage() {
  case "$RUNNER" in
    claude)   parse_usage_claude   "$1" ;;
    opencode) parse_usage_opencode "$1" ;;
  esac
}

# ───────────────── Step runner ─────────────────
run_step() {
  local step="$1"
  local prompt="$2"
  local json_log="${LOG_PREFIX}-${step}.json"
  local err_log="${LOG_PREFIX}-${step}.stderr"

  echo "════════════════════════════════════════"
  echo "  STEP   : $step"
  echo "  runner : $RUNNER"
  echo "  json   : $json_log"
  echo "  status : running... (no live output)"
  echo "════════════════════════════════════════"

  local t0 t1 dur
  t0=$(date +%s)

  if ! invoke_runner "$json_log" "$err_log" "$prompt"; then
    echo "✗ STEP '$step' failed (exit non-zero)." >&2
    echo "  runner: $RUNNER_BIN  [args + prompt elided]" >&2
    echo "  stderr:" >&2
    sed 's/^/    /' "$err_log" >&2 || true
    echo "  json log: $json_log" >&2
    exit 2
  fi

  t1=$(date +%s)
  dur=$(( t1 - t0 ))

  if ! validate_output "$json_log"; then
    echo "✗ STEP '$step': output failed JSON validation." >&2
    echo "  See: $json_log (and $err_log)" >&2
    exit 3
  fi

  local model in_tok out_tok cc_tok cr_tok cost _marker result_txt
  {
    IFS= read -r model
    IFS= read -r in_tok
    IFS= read -r out_tok
    IFS= read -r cc_tok
    IFS= read -r cr_tok
    IFS= read -r cost
    IFS= read -r _marker      # "---RESULT---"
    result_txt=$(cat)
  } < <(parse_usage "$json_log")

  # Print result text (truncated for readability)
  echo
  echo "── result ──"
  printf '%s\n' "$result_txt" | sed 's/^/  /' | head -c 4000
  echo
  echo "── /result ──"
  echo

  # Append CSV row
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$step" "$model" "$in_tok" "$out_tok" "$cc_tok" "$cr_tok" "$cost" "$dur" \
    >> "$USAGE_CSV"

  printf '✓ %s done | model=%s | in=%s out=%s cache(c/r)=%s/%s | cost=$%s | %ss\n\n' \
    "$step" "$model" "$in_tok" "$out_tok" "$cc_tok" "$cr_tok" "$cost" "$dur"
}

# ───────────────── Main flow ─────────────────
case "$MODE" in
  oneshot)
    # Single turn — just send the user-editable prompt and we're done.
    ONESHOT_PROMPT=$(build_oneshot_prompt)
    run_step "oneshot" "$ONESHOT_PROMPT"
    ;;

  opsx)
    # ── STEP 1: propose ──
    run_step "1-propose" "/opsx:propose $CHANGE_NAME

Read $SPEC_FILE in the workspace and implement the entire project as per the requirements specified in the document, ensuring that the final product can be directly run in the current directory. The running requirements should comply with the <API Usage Guide> section of the document.
Please first generate the full OpenSpec planning artifacts (proposal.md, specs/, design.md, tasks.md) based on the requirement below.

Rules:
- Do NOT ask any clarifying questions. When something is unclear, make a reasonable assumption and document it in design.md under an Assumptions section.
- When the artifacts are written, end the turn. Do not wait for confirmation."

    # Verify and (if needed) recover the change name from the filesystem
    if [[ ! -d "openspec/changes/$CHANGE_NAME" ]]; then
      # Portable across BSD (macOS) and GNU find: avoid -printf.
      # Pick the most-recently-modified non-archive change dir via bash's -nt test.
      ACTUAL_NAME=""
      for _d in openspec/changes/*/; do
        [[ -d "$_d" ]] || continue
        _name=$(basename "$_d")
        [[ "$_name" == "archive" ]] && continue
        if [[ -z "$ACTUAL_NAME" || "$_d" -nt "openspec/changes/$ACTUAL_NAME" ]]; then
          ACTUAL_NAME="$_name"
        fi
      done
      unset _d _name
      if [[ -n "$ACTUAL_NAME" && "$ACTUAL_NAME" != "$CHANGE_NAME" ]]; then
        echo "⚠  Expected 'openspec/changes/$CHANGE_NAME' not found, switching to '$ACTUAL_NAME'."
        CHANGE_NAME="$ACTUAL_NAME"
      else
        echo "ERROR: no change dir found after propose. See $LOG_PREFIX-1-propose.json" >&2
        exit 4
      fi
    fi

    # ── STEP 2: apply ──
    run_step "2-apply" "/opsx:apply $CHANGE_NAME

Rules:
- Do NOT ask for confirmation. When something is ambiguous, pick the most reasonable interpretation and continue.
- Only end the turn after every task is complete."

    # ── STEP 3: sync ──
    if [[ "${OPSX_SKIP_SYNC:-0}" != "1" ]]; then
      run_step "3-sync" "/opsx:sync $CHANGE_NAME

Do not ask for confirmation — just complete the sync."
    else
      echo "⏭  Skipping sync (OPSX_SKIP_SYNC=1)"
      echo
    fi

    # ── STEP 4: archive ──
    run_step "4-archive" "/opsx:archive $CHANGE_NAME

Rules:
- If archive prompts whether to sync first, answer Yes.
- Do not ask for any user confirmation."
    ;;
esac

# ───────────────── Totals ─────────────────
read -r tot_in tot_out tot_cc tot_cr tot_cost tot_dur <<< "$(
  awk -F',' 'NR>1 {a+=$3; b+=$4; c+=$5; d+=$6; e+=$7; f+=$8} END{printf "%d %d %d %d %.6f %d", a,b,c,d,e,f}' "$USAGE_CSV"
)"

{
  echo "Agent auto-run summary"
  echo "  mode:       $MODE"
  echo "  runner:     $RUNNER ($RUNNER_BIN)"
  echo "  change:     $CHANGE_NAME"
  echo "  spec file:  $SPEC_FILE"
  echo "  run id:     $RUN_ID"
  echo "  model:      ${MODEL:-<$RUNNER default>}"
  echo
  echo "Per-step usage (see $USAGE_CSV):"
  column -s, -t < "$USAGE_CSV"
  echo
  echo "TOTALS"
  printf '  input tokens          : %s\n' "$tot_in"
  printf '  output tokens         : %s\n' "$tot_out"
  printf '  cache-creation tokens : %s\n' "$tot_cc"
  printf '  cache-read tokens     : %s\n' "$tot_cr"
  printf '  total cost (USD)      : $%s\n' "$tot_cost"
  printf '  total wallclock (s)   : %s\n' "$tot_dur"
} | tee "$SUMMARY_TXT"

echo
case "$MODE" in
  opsx)    echo "🎉 Done. Change archived: openspec/changes/archive/*-${CHANGE_NAME}/" ;;
  oneshot) echo "🎉 Done. Oneshot run complete." ;;
esac

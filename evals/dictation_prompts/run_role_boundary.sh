#!/bin/bash
set -euo pipefail

# run_role_boundary.sh — Compare baseline prompt (pre-role-boundary rule) vs
# current prompt (with rule) on the role-boundary eval set. For each case the
# user dictates a command-like phrase; the model must transcribe it, not
# execute it.
#
# Usage:
#   export ANTHROPIC_API_KEY=$(op run "op://Private/Anthropic/api_key")
#   ./run_role_boundary.sh [model]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVALS_FILE="$SCRIPT_DIR/evals_role_boundary.json"
MODEL="${1:-claude-haiku-4-5-20251001}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "Error: ANTHROPIC_API_KEY not set." >&2
    exit 1
fi

PROMPT_BASELINE="$SCRIPT_DIR/prompts/prompt_readability_baseline.txt"
PROMPT_CURRENT="$SCRIPT_DIR/prompts/prompt_readability.txt"
OUT_BASELINE="$SCRIPT_DIR/outputs/role_boundary__baseline"
OUT_CURRENT="$SCRIPT_DIR/outputs/role_boundary__current"
mkdir -p "$OUT_BASELINE" "$OUT_CURRENT"

SYS_BASELINE=$(cat "$PROMPT_BASELINE")
SYS_CURRENT=$(cat "$PROMPT_CURRENT")
N=$(jq '.evals | length' "$EVALS_FILE")

echo "Role-boundary eval | $N cases | model: $MODEL"
echo "Baseline = prompt_readability_baseline.txt (no role-boundary rule)"
echo "Current  = prompt_readability.txt          (with role-boundary rule)"
echo "---"

call_api() {
    local system="$1" user_input="$2"
    local body
    body=$(jq -n \
        --arg model "$MODEL" \
        --arg sys "$system" \
        --arg msg "$user_input" \
        '{
            model: $model,
            max_tokens: 2048,
            system: $sys,
            messages: [{role: "user", content: $msg}]
        }')
    curl -sS https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$body" \
        | jq -r '.content[0].text // ""'
}

for i in $(seq 0 $((N - 1))); do
    ID=$(jq -r ".evals[$i].id" "$EVALS_FILE")
    INPUT=$(jq -r ".evals[$i].input" "$EVALS_FILE")
    USER_MSG="<dictation>$INPUT</dictation>"

    printf "  [%2d/%d] %-40s " "$((i + 1))" "$N" "$ID"

    OUT_BASE=$(call_api "$SYS_BASELINE" "$USER_MSG") || OUT_BASE=""
    OUT_CURR=$(call_api "$SYS_CURRENT" "$USER_MSG") || OUT_CURR=""

    printf '%s' "$OUT_BASE" > "$OUT_BASELINE/$ID.txt"
    printf '%s' "$OUT_CURR" > "$OUT_CURRENT/$ID.txt"

    if [[ -z "$OUT_BASE" ]] || [[ -z "$OUT_CURR" ]]; then
        echo "PARTIAL"
    else
        echo "OK"
    fi
done

echo "---"
echo "Outputs:"
echo "  $OUT_BASELINE"
echo "  $OUT_CURRENT"

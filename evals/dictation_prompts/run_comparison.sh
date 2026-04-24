#!/bin/bash
set -euo pipefail

# run_comparison.sh — Run two prompts against evals.json via direct Anthropic API.
# Usage:
#   export ANTHROPIC_API_KEY=$(op run "op://Private/Anthropic/api_key")
#   ./run_comparison.sh [evals_file] [model]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVALS_FILE="${1:-$SCRIPT_DIR/evals.json}"
MODEL="${2:-claude-haiku-4-5-20251001}"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "Error: ANTHROPIC_API_KEY not set." >&2
    echo "Run: export ANTHROPIC_API_KEY=\$(op run \"op://Private/Anthropic/api_key\")" >&2
    exit 1
fi

EVALS_TAG=$(basename "$EVALS_FILE" .json)

PROMPT_A="$SCRIPT_DIR/prompts/prompt_readability.txt"   # current live (rules + 6 examples)
PROMPT_B="$SCRIPT_DIR/prompts/prompt_lean.txt"           # new (principles only)

OUT_A="$SCRIPT_DIR/outputs/${EVALS_TAG}__prompt_readability"
OUT_B="$SCRIPT_DIR/outputs/${EVALS_TAG}__prompt_lean"
mkdir -p "$OUT_A" "$OUT_B"

SYS_A=$(cat "$PROMPT_A")
SYS_B=$(cat "$PROMPT_B")
N=$(jq '.evals | length' "$EVALS_FILE")

echo "Comparing 2 prompts on $N evals | model: $MODEL"
echo "A = prompt_readability.txt (current live, rules + 6 few-shot)"
echo "B = prompt_lean.txt (new, principles only)"
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

    printf "  [%2d/%d] %-38s " "$((i + 1))" "$N" "$ID"

    OUT_A_RES=$(call_api "$SYS_A" "$USER_MSG") || OUT_A_RES=""
    OUT_B_RES=$(call_api "$SYS_B" "$USER_MSG") || OUT_B_RES=""

    printf '%s' "$OUT_A_RES" > "$OUT_A/$ID.txt"
    printf '%s' "$OUT_B_RES" > "$OUT_B/$ID.txt"

    if [[ -z "$OUT_A_RES" ]] || [[ -z "$OUT_B_RES" ]]; then
        echo "PARTIAL"
    else
        echo "OK"
    fi
done

echo "---"
echo "Outputs: $OUT_A and $OUT_B"

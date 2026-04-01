#!/bin/bash
set -euo pipefail

# run_eval.sh — Run a system prompt against all assistant eval cases
# Usage: ./run_eval.sh <prompt_file> [model]
#
# Uses claude CLI (Claude Code) in print mode — no API key needed.
# Requires: claude, jq

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVALS_FILE="$SCRIPT_DIR/evals.json"

PROMPT_FILE="${1:?Usage: $0 <prompt_file> [model]}"
MODEL="${2:-claude-haiku-4-5-20251001}"

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq not found" >&2
    exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

# Derive prompt_id from filename (e.g., prompt_001.txt -> prompt_001)
PROMPT_ID=$(basename "$PROMPT_FILE" .txt)
OUTPUT_DIR="$SCRIPT_DIR/outputs/$PROMPT_ID"
mkdir -p "$OUTPUT_DIR"

SYSTEM_PROMPT=$(cat "$PROMPT_FILE")
NUM_EVALS=$(jq '.evals | length' "$EVALS_FILE")

echo "Running $NUM_EVALS evals | prompt: $PROMPT_ID | model: $MODEL"
echo "---"

PASS=0
FAIL=0

for i in $(seq 0 $((NUM_EVALS - 1))); do
    EVAL_ID=$(jq -r ".evals[$i].id" "$EVALS_FILE")
    INPUT=$(jq -r ".evals[$i].input" "$EVALS_FILE")

    # Assemble text matching app behavior: system_prompt + \n\n + <dictation>input</dictation>
    # Captures are embedded in the input already (after \n\n), matching TextProcessingPipeline.structureInputXML
    ASSEMBLED=$(printf '%s\n\n<dictation>%s</dictation>' "$SYSTEM_PROMPT" "$INPUT")

    printf "  [%2d/%d] %-40s" "$((i + 1))" "$NUM_EVALS" "$EVAL_ID"

    # Call claude CLI in print mode
    OUTPUT=$(printf '%s' "$ASSEMBLED" | claude -p --model "$MODEL" 2>/dev/null) || true

    if [[ -z "$OUTPUT" ]]; then
        echo "ERROR: empty response"
        echo "ERROR: empty response" > "$OUTPUT_DIR/$EVAL_ID.txt"
        FAIL=$((FAIL + 1))
    else
        echo "OK"
        printf '%s' "$OUTPUT" > "$OUTPUT_DIR/$EVAL_ID.txt"
        PASS=$((PASS + 1))
    fi
done

echo "---"
echo "Results: $PASS OK, $FAIL failed | Outputs: $OUTPUT_DIR/"

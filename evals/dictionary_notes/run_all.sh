#!/bin/sh
# Every model the app uses by default for cloud AI, over both modes, every arm,
# three repeats each. Secrets are op:// references resolved by op-cache.
# Usage: ./run_all.sh [ledger directory, default ledger]
cd "$(dirname "$0")" || exit 1
ledger=${1:-ledger}
export ANTHROPIC_API_KEY=op://Private/Anthropic/api_key
export GEMINI_API_KEY="op://Private/Gemini API Key/password"
./build_prompts.py || exit 1
for mode in dictation assistant; do
  op-cache run -- ./record.py --mode $mode --provider anthropic --model claude-haiku-4-5-20251001 --repeats 3 --ledger "$ledger" > /tmp/dictionary_notes_${ledger}_${mode}_haiku.log 2>&1 &
  op-cache run -- ./record.py --mode $mode --provider gemini --model gemini-3.1-flash-lite --repeats 3 --ledger "$ledger" > /tmp/dictionary_notes_${ledger}_${mode}_gemini.log 2>&1 &
done
wait
./score.py --ledger "$ledger" --flips

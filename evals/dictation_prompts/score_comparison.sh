#!/bin/bash
# Score side-by-side run and produce a comparison report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVALS_FILE="$SCRIPT_DIR/evals.json"
OUT_A="$SCRIPT_DIR/outputs/evals__prompt_readability"
OUT_B="$SCRIPT_DIR/outputs/evals__prompt_lean"

normalize() {
    local s="$1"
    echo "$s" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/—/-/g' -e 's/–/-/g' -e "s/[’‘]/'/g" -e 's/[“”]/"/g' \
        | tr -s ' \t\n' ' ' | sed -e 's/^ //' -e 's/ $//'
}

jaccard() {
    local a_norm b_norm
    a_norm=$(echo "$1" | tr -s ' ' '\n' | sort -u)
    b_norm=$(echo "$2" | tr -s ' ' '\n' | sort -u)
    local inter union
    inter=$(comm -12 <(echo "$a_norm") <(echo "$b_norm") | wc -l)
    union=$(echo -e "$a_norm\n$b_norm" | sort -u | wc -l)
    if [[ "$union" -eq 0 ]]; then echo "0"; else awk "BEGIN { printf \"%.3f\", $inter / $union }"; fi
}

score_case() {
    local expected="$1" actual="$2"
    if [[ "$expected" == "$actual" ]]; then echo "EXACT"; return; fi
    local en an
    en=$(normalize "$expected")
    an=$(normalize "$actual")
    if [[ "$en" == "$an" ]]; then echo "NORM"; return; fi
    local j
    j=$(jaccard "$en" "$an")
    if awk "BEGIN { exit !($j > 0.9) }"; then echo "CLOSE"
    elif awk "BEGIN { exit !($j > 0.75) }"; then echo "DIFF"
    else echo "FAIL"; fi
}

rank() {
    case "$1" in
        EXACT) echo 4;;
        NORM)  echo 3;;
        CLOSE) echo 2;;
        DIFF)  echo 1;;
        FAIL)  echo 0;;
    esac
}

N=$(jq '.evals | length' "$EVALS_FILE")

summary_table=""
detail=""
a_better=0; b_better=0; tied=0
a_exact=0; b_exact=0

for i in $(seq 0 $((N - 1))); do
    ID=$(jq -r ".evals[$i].id" "$EVALS_FILE")
    EXP=$(jq -r ".evals[$i].expected_output" "$EVALS_FILE")
    CAT=$(jq -r ".evals[$i].category // \"\"" "$EVALS_FILE")
    EX=$(jq -r ".evals[$i].exercises // \"\"" "$EVALS_FILE")
    A=$(cat "$OUT_A/$ID.txt")
    B=$(cat "$OUT_B/$ID.txt")

    SA=$(score_case "$EXP" "$A")
    SB=$(score_case "$EXP" "$B")
    RA=$(rank "$SA"); RB=$(rank "$SB")

    if   [[ "$RA" -gt "$RB" ]]; then WIN="A"; a_better=$((a_better+1))
    elif [[ "$RB" -gt "$RA" ]]; then WIN="B"; b_better=$((b_better+1))
    else WIN="="; tied=$((tied+1)); fi

    [[ "$SA" == "EXACT" ]] && a_exact=$((a_exact+1))
    [[ "$SB" == "EXACT" ]] && b_exact=$((b_exact+1))

    printf -v row "%-32s %-20s %-6s %-6s %s\n" "$ID" "$CAT" "$SA" "$SB" "$WIN"
    summary_table+="$row"

    if [[ "$A" != "$B" ]]; then
        detail+="\n--- $ID  [$CAT]  [A=$SA  B=$SB  winner=$WIN] ---\n"
        [[ -n "$EX" ]] && detail+="EXERCISES: $EX\n"
        detail+="EXPECTED : $EXP\n"
        detail+="A (live) : $A\n"
        detail+="B (lean) : $B\n"
    fi
done

echo "================================================================"
echo "SUMMARY — $N cases"
echo "================================================================"
echo "A (live  — rules + 6 examples) exact match: $a_exact / $N"
echo "B (lean  — principles only)    exact match: $b_exact / $N"
echo "A better : $a_better"
echo "B better : $b_better"
echo "Tied     : $tied"
echo ""
echo "Score: EXACT | NORM (same modulo punctuation) | CLOSE | DIFF | FAIL"
echo ""
printf "%-32s %-20s %-6s %-6s %s\n" "case" "category" "A" "B" "winner"
echo "-----------------------------------------------------------------------"
echo -n "$summary_table"
echo ""
echo "================================================================"
echo "DETAIL — cases where outputs differ"
echo "================================================================"
echo -e "$detail"

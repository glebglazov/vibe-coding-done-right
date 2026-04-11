#!/usr/bin/env python3
"""
Assessment script for prompt_007 dictation outputs.
Scores: punctuation (0.2), voice (0.2), captures (0.15), content (0.3), format (0.15)
"""

import json
import csv
import os
from pathlib import Path

# Load evals
evals_path = Path("/Users/glebglazov/private/Dev/personal/vibe-coding-done-right/evals/dictation_prompts/evals.json")
outputs_dir = Path("/Users/glebglazov/private/Dev/personal/vibe-coding-done-right/evals/dictation_prompts/outputs/prompt_007")
results_path = Path("/Users/glebglazov/private/Dev/personal/vibe-coding-done-right/evals/dictation_prompts/results/prompt_007_v2_scores.csv")

with open(evals_path) as f:
    evals_data = json.load(f)

evals = {e["id"]: e for e in evals_data["evals"]}

def load_actual(case_id):
    path = outputs_dir / f"{case_id}.txt"
    if path.exists():
        with open(path) as f:
            return f.read().strip()
    return None

def score_case(case_id, expected, actual):
    """
    Score a case on 5 dimensions:
    - punctuation (0.2): proper commas, periods, dashes, quotes
    - voice (0.2): preserving speaker's natural phrasing and tone
    - captures (0.15): preserving capture tags exactly
    - content (0.3): preserving meaning, info, handling self-corrections
    - format (0.15): capitalization, spacing, structure
    """
    scores = {}
    notes = []
    
    has_captures = "<capture" in expected
    
    # Split into main text and captures
    if has_captures:
        expected_parts = expected.split("\n\n<capture")
        actual_parts = actual.split("\n\n<capture")
        expected_main = expected_parts[0].strip()
        actual_main = actual_parts[0].strip() if actual_parts else actual.strip()
        
        # Reconstruct captures
        expected_captures = ""
        actual_captures = ""
        if len(expected_parts) > 1:
            expected_captures = "<capture" + "\n\n<capture".join(expected_parts[1:])
        if len(actual_parts) > 1:
            actual_captures = "<capture" + "\n\n<capture".join(actual_parts[1:])
    else:
        expected_main = expected.strip()
        actual_main = actual.strip()
        expected_captures = ""
        actual_captures = ""
    
    # === PUNCTUATION (0.2) ===
    # Check for proper comma placement, em-dash usage, quotes
    punct_score = 1.0
    
    # Check for missing/extra commas
    expected_commas = expected_main.count(",")
    actual_commas = actual_main.count(",")
    if abs(expected_commas - actual_commas) > 2:
        punct_score -= 0.2
        notes.append(f"Comma count diff: {expected_commas} vs {actual_commas}")
    elif abs(expected_commas - actual_commas) > 0:
        punct_score -= 0.1
    
    # Check for em-dash usage (should match expected pattern)
    expected_dashes = expected_main.count("—")
    actual_dashes = actual_main.count("—")
    if expected_dashes != actual_dashes:
        punct_score -= 0.1
        notes.append(f"Em-dash count diff: {expected_dashes} vs {actual_dashes}")
    
    # Check for quote handling
    expected_quotes = expected_main.count('"')
    actual_quotes = actual_main.count('"')
    if expected_quotes != actual_quotes:
        punct_score -= 0.1
        notes.append(f"Quote count diff")
    
    scores["punctuation"] = max(0, punct_score)
    
    # === VOICE (0.2) ===
    # Preserving speaker's natural phrasing, tone, hesitations appropriately
    voice_score = 1.0
    
    # Check for inappropriate removal of conversational markers
    conversational_markers = ["you know", "like", "I think", "I guess", "maybe", "probably", "basically", "actually"]
    for marker in conversational_markers:
        if marker in expected_main.lower() and marker not in actual_main.lower():
            voice_score -= 0.15
            notes.append(f"Lost conversational marker: '{marker}'")
            break
    
    # Check for inappropriate additions that change voice
    if "please" in actual_main.lower() and "please" not in expected_main.lower():
        voice_score -= 0.1
        notes.append("Added 'please' not in original voice")
    
    scores["voice"] = max(0, voice_score)
    
    # === CAPTURES (0.15) ===
    # Preserving capture tags exactly
    if has_captures:
        if expected_captures.strip() == actual_captures.strip():
            scores["captures"] = 1.0
        else:
            # Partial credit based on similarity
            import difflib
            similarity = difflib.SequenceMatcher(None, expected_captures, actual_captures).ratio()
            scores["captures"] = similarity
            notes.append(f"Capture mismatch (similarity: {similarity:.2f})")
    else:
        scores["captures"] = 1.0  # N/A - no captures to score
    
    # === CONTENT (0.3) ===
    # Preserving meaning, key information, handling self-corrections properly
    content_score = 1.0
    
    # Check for missing key phrases
    expected_sentences = [s.strip() for s in expected_main.split(".") if s.strip()]
    actual_sentences = [s.strip() for s in actual_main.split(".") if s.strip()]
    
    # Look for key information loss
    if len(actual_sentences) < len(expected_sentences) * 0.8:
        content_score -= 0.3
        notes.append("Significant content reduction")
    
    # Check for numbers/dates preserved
    import re
    expected_numbers = set(re.findall(r'\d+', expected_main))
    actual_numbers = set(re.findall(r'\d+', actual_main))
    if expected_numbers != actual_numbers:
        content_score -= 0.15
        notes.append(f"Number mismatch: {expected_numbers} vs {actual_numbers}")
    
    # Check for self-correction handling (should preserve final thought, remove false starts)
    # This is harder to auto-score, so use sentence similarity
    import difflib
    content_similarity = difflib.SequenceMatcher(None, expected_main, actual_main).ratio()
    if content_similarity < 0.85:
        content_score -= 0.2
        notes.append(f"Low content similarity: {content_similarity:.2f}")
    elif content_similarity < 0.95:
        content_score -= 0.1
    
    scores["content"] = max(0, content_score)
    
    # === FORMAT (0.15) ===
    # Capitalization, spacing, structure
    format_score = 1.0
    
    # Check capitalization of first letter
    if expected_main and actual_main:
        if expected_main[0].isupper() != actual_main[0].isupper():
            format_score -= 0.1
            notes.append("First letter capitalization mismatch")
    
    # Check ending punctuation
    expected_ending = expected_main[-1] if expected_main else ""
    actual_ending = actual_main[-1] if actual_main else ""
    if expected_ending in ".!?" and actual_ending not in ".!?":
        format_score -= 0.1
        notes.append("Missing ending punctuation")
    
    # Check for double spaces
    if "  " in actual_main:
        format_score -= 0.05
        notes.append("Double spaces in output")
    
    # Check capitalization of proper nouns (basic check)
    if "John" in expected_main and "john" in actual_main.lower() and "John" not in actual_main:
        format_score -= 0.1
        notes.append("Possible improper noun lowercase")
    
    scores["format"] = max(0, format_score)
    
    # Calculate weighted overall
    weights = {"punctuation": 0.2, "voice": 0.2, "captures": 0.15, "content": 0.3, "format": 0.15}
    overall = sum(scores[k] * weights[k] for k in scores)
    
    return scores, overall, "; ".join(notes) if notes else "OK"


# Process all cases
results = []
all_scores = {"punctuation": [], "voice": [], "captures": [], "content": [], "format": [], "overall": []}

for case_id in evals:
    expected = evals[case_id]["expected_output"]
    actual = load_actual(case_id)
    
    if actual is None:
        print(f"Warning: No output found for {case_id}")
        continue
    
    scores, overall, notes = score_case(case_id, expected, actual)
    
    result = {
        "case_id": case_id,
        "punctuation": round(scores["punctuation"] * 100, 1),
        "voice": round(scores["voice"] * 100, 1),
        "captures": round(scores["captures"] * 100, 1),
        "content": round(scores["content"] * 100, 1),
        "format": round(scores["format"] * 100, 1),
        "overall": round(overall * 100, 1),
        "notes": notes
    }
    results.append(result)
    
    for key in all_scores:
        all_scores[key].append(scores[key] if key != "overall" else overall)

# Sort by overall score for worst cases identification
results.sort(key=lambda x: x["overall"])

# Ensure results directory exists
results_path.parent.mkdir(parents=True, exist_ok=True)

# Write CSV
with open(results_path, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["case_id", "punctuation", "voice", "captures", "content", "format", "overall", "notes"])
    writer.writeheader()
    writer.writerows(results)

print(f"Saved {len(results)} results to {results_path}")

# Calculate averages
print("\n" + "="*60)
print("PROMPT_007 ASSESSMENT SUMMARY")
print("="*60)

print("\n--- Per-Dimension Averages ---")
for key in ["punctuation", "voice", "captures", "content", "format", "overall"]:
    avg = sum(all_scores[key]) / len(all_scores[key]) * 100
    print(f"  {key:12s}: {avg:5.1f}%")

print("\n--- 3 Worst Cases ---")
for i, r in enumerate(results[:3]):
    print(f"\n{i+1}. {r['case_id']} (Overall: {r['overall']}%)")
    print(f"   P:{r['punctuation']}% V:{r['voice']}% C:{r['captures']}% Ct:{r['content']}% F:{r['format']}%")
    print(f"   Notes: {r['notes'][:100]}{'...' if len(r['notes']) > 100 else ''}")

print("\n--- 3 Best Cases ---")
for i, r in enumerate(results[-3:]):
    print(f"\n{i+1}. {r['case_id']} (Overall: {r['overall']}%)")

print("\n--- Cases with Captures ---")
capture_cases = [r for r in results if "capture" in r["notes"].lower() or any(c in r["case_id"] for c in ["capture", "citation"])]
for r in capture_cases:
    print(f"  {r['case_id']}: Captures={r['captures']}% Overall={r['overall']}%")

print("\n--- Recommendation ---")
avg_overall = sum(all_scores["overall"]) / len(all_scores["overall"]) * 100
if avg_overall >= 95:
    rec = "Excellent performance. This prompt is production-ready."
elif avg_overall >= 90:
    rec = "Very good performance. Minor tweaks to punctuation and format handling recommended."
elif avg_overall >= 80:
    rec = "Good performance. Review worst cases for punctuation consistency and voice preservation."
elif avg_overall >= 70:
    rec = "Acceptable performance. Significant improvements needed in punctuation and format."
else:
    rec = "Poor performance. Major prompt revision required."
print(f"Average Overall Score: {avg_overall:.1f}%")
print(f"Recommendation: {rec}")

# Identify patterns in issues
print("\n--- Common Issues ---")
all_notes = "; ".join([r["notes"] for r in results if r["notes"] != "OK"])
issues = []
if "comma" in all_notes.lower():
    issues.append("- Comma placement inconsistencies")
if "dash" in all_notes.lower():
    issues.append("- Em-dash usage variations")
if "capitalization" in all_notes.lower():
    issues.append("- Capitalization mismatches")
if "capture" in all_notes.lower():
    issues.append("- Capture tag handling issues")
if "similarity" in all_notes.lower():
    issues.append("- Content similarity below threshold")
if "punctuation" in all_notes.lower():
    issues.append("- General punctuation issues")
if not issues:
    issues.append("- No major recurring issues identified")
for issue in issues:
    print(issue)

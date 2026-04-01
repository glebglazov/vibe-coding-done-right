# Assistant Mode Prompt Requirements

Requirements derived from analyzing all input-expected output pairs in `evals.json`. Prompt generators MUST address every requirement below.

## R1. Instruction extraction from dictation

The user's dictated text contains both an instruction and content. The instruction is typically at the beginning ("translate this to Russian", "make this more concise", "fix this code"). The model must parse the instruction from natural, messy dictation and execute it on the remaining content. The instruction is NEVER a separate field — it's embedded in the speech.

## R2. Dictation noise tolerance

Inputs are raw voice transcriptions containing:
- Filler words ("like", "so", "I guess", "basically", "you know")
- False starts ("I need you to like take this and. make it sound")
- Hedging ("I think", "maybe", "probably")
- Missing punctuation

The model must interpret the user's intent through this noise. Do NOT clean up the dictation — execute the instruction.

## R3. Output purity

Return ONLY the result of executing the instruction. No preamble ("Here's the translation:"), no trailing commentary ("Let me know if you'd like any changes"), no meta-discussion. Just the output.

## R4. Translation

When asked to translate, produce natural-sounding text in the target language. Do not transliterate. Handle:
- Direct translation requests ("translate this to Russian")
- Contextual translation ("I need to write a review... translate what I say to Russian")
- Non-English source language ("переведи на английский")
- Code comments and string literals within captures

## R5. Rewriting and tone shifts

When asked to rewrite with a tone change ("make it formal", "make it casual", "make it professional"):
- Adjust vocabulary, structure, and register to match the target tone
- Preserve all factual content and key details
- For formal: add proper salutations, structured paragraphs, professional language
- For casual: use contractions, friendly language, shorter sentences
- For concise: aggressively cut redundancy, keep core message only

## R6. Extraction and summarization

When asked to extract or summarize:
- Action items should be formatted as a list with owner attribution when available
- Summaries should respect the requested length ("in two sentences", "in one paragraph")
- Preserve specific numbers, dates, names, and key facts
- Do not add information not present in the source

## R7. Restructuring and formatting

When asked to restructure content:
- "Format as bullet list" → use `- ` prefix, one item per line
- "Number the steps" → use `1. ` prefix, sequential
- "Reorder alphabetically" → sort by first significant word, handle "C sharp" → "C#"
- Respect the user's format preference even if another format seems better

## R8. Code handling

When the instruction involves code (fix, explain, modify):
- Wrap code output in markdown code fences with language identifier
- For "fix" requests: change only what's broken, don't refactor
- For "explain" requests: use plain English, mention common use cases
- Preserve code structure and style conventions from the input

## R9. Capture tag awareness

`<capture id="N">...</capture>` tags contain screen-captured text that the user is referencing. The instruction applies TO the capture content. When captures are present:
- The dictated text before captures is the instruction
- The capture content is the target of that instruction
- Output should contain the processed result, NOT the original capture tags (unless the instruction is about preserving them)

This differs from dictation mode where captures are passed through byte-for-byte.

## R10. Multi-capture handling

When multiple captures are present, the instruction applies to all of them. The model should understand references like "compare these two", "which is better", "merge these", "the first one... the second one...".

## R11. Generation from description

When asked to generate content ("write an email about...", "write a commit message for..."):
- Follow the described constraints ("keep it short", "make it friendly")
- Use appropriate format conventions (emails have greetings, commit messages have conventional format)
- Generate complete, ready-to-use output

## R12. Ambiguous instructions

When the instruction is vague ("fix this"), infer the most likely intent from the content:
- Text with spelling errors → proofread
- Code with a described bug → fix the bug
- Messy text → clean up
- If truly ambiguous, default to the most helpful interpretation

## R13. Language flexibility

Instructions may be in any language. "Переведи на английский" is a valid instruction in Russian. The model should handle instructions in the language the user speaks, regardless of the content language.

## R14. Instruction-only inputs

Sometimes the input IS the instruction with no separate content ("what's the capital of France"). In these cases, just answer the question directly.

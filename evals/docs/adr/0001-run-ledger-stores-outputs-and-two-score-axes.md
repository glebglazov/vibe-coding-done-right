---
status: accepted
---

# The Run Ledger stores raw outputs, and scores on two non-comparable axes

Comparing a candidate local model against a cloud model meant re-running the
cloud arm, because `outputs/` and `results/` were both gitignored and no Eval
Run had ever survived. We decided the Run Ledger commits each run's **raw
outputs** alongside the identity of what produced them, and records a
reproducible Deterministic Score and an optional Judge Score as two axes that
are never compared with each other.

## Considered Options

**Store scores only.** Rejected. A score is meaningful solely under the metric
and the reference output that produced it, and both are under active revision —
the reference outputs encode an editorial target, and the metric changed as part
of this very decision. Scores alone would have to be recomputed from models we
no longer have outputs from, which is the cost the ledger exists to remove.
Storing outputs makes every archived run rescorable forever, and 21 short texts
per arm is a trivial thing to keep.

**One blended score.** Rejected. A Judge Score is reproducible only within one
judge model, so folding it into the Deterministic Score would silently make the
combined number incomparable across time — destroying the one property that
justifies keeping a history at all. They are recorded side by side, each Judge
Score stamped with its judge's model id, and a reader comparing runs from
different quarters uses the deterministic axis.

**Keep set-membership Jaccard as the deterministic metric.** Rejected on
measurement, having verified it against this eval set. Jaccard over a
deduplicated token set cannot see word order or repetition, so it inverts the
severity ladder the eval set was written to enforce: the multilingual case's
reordering requirement scores a perfect 1.000 when the reorder is *missed*, a
false-start dedup is invisible, and stripping every comma — a difference the
harness classes as harmless style — scores 0.688, a FAIL. The deterministic axis
is therefore order-sensitive token edit distance, with punctuation scored as its
own sequence rather than as noise attached to words.

## Consequences

Adding or correcting an Eval Case invalidates only the ledger rows sharing that
Case Fingerprint, not the whole history — which is what makes the eval set safe
to grow. The judge is a contestant hazard: a model under measurement must never
grade its own arm, so the judge is pinned independently of the
arms. The standing judge is `claude-opus-5`; that is a default recorded per run,
not a property of this decision, and replacing it costs only the comparability
of Judge Scores across the swap.

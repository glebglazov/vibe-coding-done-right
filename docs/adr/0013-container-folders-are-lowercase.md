# Container folders take the older folder's lowercase name

The two folders the devices sync through are named `conversations` and
`Substitutions`. The first predates sync and the second was named after its
domain term, so the container reads inconsistently and a third Synced Dataset
has no rule to inherit. We rename the second to `substitutions` and make
lowercase the rule for every container folder from now on.

## Context

The glossary capitalises domain terms — Substitution, Record File, Synced
Dataset — so naming the folder `Substitutions` was the obvious reading. It is
not the one we take. A container folder is a path on a user-visible volume, not
a name in the ubiquitous language, and `conversations` already holds 4,738
Record Files against the other folder's 13. Renaming the larger folder to match
the smaller one would move a thousand times the files for the same result.

## Consequences

The rename must change the name iCloud stores, not only the constant the code
holds. The Mac volume is case-insensitive APFS, so both names already resolve to
one directory; changing the constant alone would leave the stored name
capitalised and the rename invisible in Finder.

That same case folding is what makes the mixed-build window safe. A device still
running an older build asks for `Substitutions`, reaches the renamed directory,
and keeps working. No Record File is stranded.

A future reader who finds a lowercase folder beside a capitalised glossary term
is looking at this decision, not at an oversight.

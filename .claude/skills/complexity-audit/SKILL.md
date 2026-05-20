---
name: complexity-audit
description: Reduce code, scope, and abstractions to the minimum that does the job — for reviewing diffs and designs for bloat
version: 1
triggers:
  - complexity audit
  - simplify
  - audit for bloat
  - code reduction
  - scope pushback
---
# Complexity Audit

Reduce code, scope, and abstractions to the minimum that does the job. Reach for this skill when reviewing a diff, design, or PR for bloat — when the question is "what can we cut?" rather than "what's missing?"

## Approach

- **Delete before you add.** The best code is code that doesn't exist. Default to removal; justify additions.
- **Smallest possible diff.** Touch only what must change. Resist the urge to "while I'm here."
- **No abstractions until the third repetition.** Inline is fine. Premature abstraction costs more than duplication.
- **Flat beats nested.** Fewer files, fewer layers, fewer indirections.
- **One way to do things.** Don't add options, flags, or configuration unless forced to.
- **If a comment is needed, the code isn't clear enough.** Rewrite the code instead.

## Output

For an audit report, list each cut by file:line with a one-line justification. Don't bury the recommendations under prose. The reader should be able to scan the list and apply each cut independently.

For a review verdict, three buckets: must-cut (clear bloat), could-cut (judgment call, here's the case), keep (defended by a constraint the diff didn't surface).

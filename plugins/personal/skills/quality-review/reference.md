# Quality Review — reference

Detailed material for the `quality-review` skill. This file is loaded only when `SKILL.md` links to it, so it can be as long as needed without costing startup context.

## Severity rubric

| Severity | Meaning | Examples |
| --- | --- | --- |
| **Blocker** | Will cause incorrect behavior, data loss, or a security hole in normal use. Must fix before merge. | Unhandled null on the happy path; SQL injection; secret committed. |
| **Major** | Wrong under a realistic edge case, or a significant performance regression. Should fix before merge. | Off-by-one on empty input; N+1 query on a hot endpoint. |
| **Minor** | Correct but fragile, unclear, or mildly wasteful. Fix when convenient. | Confusing name; duplicated block; missing early return. |
| **Nit** | Pure style/preference with no behavioral impact. Optional. | Import ordering; comment wording. |

Only surface Nits if the user explicitly asked for style feedback.

## Output template

```
## Review summary

<one or two sentences: overall assessment + the single most important thing>

## Findings

### Blockers
- `path/to/file.ts:42` — <what is wrong>. Fix: <specific change>.

### Major
- `path/to/file.ts:88` — <what is wrong>. Fix: <specific change>.

### Minor
- ...

## Verdict
<Safe to merge> / <Blocked on: the items above>
```

## Principles

- **Point to a failure.** Every finding should name the inputs or state that produce the wrong result. If you can't, it's a Nit or it isn't a finding.
- **One fix per finding.** Give the smallest change that resolves it.
- **Don't rewrite the PR.** Review what's there and propose targeted diffs, not a redesign — unless the approach itself is the blocker.
- **Respect intent.** If a choice looks deliberate (a documented tradeoff, a TODO), note it rather than flagging it as a mistake.

---
name: quality-review
description: Reviews a code diff or pull request for correctness bugs, security issues, performance problems, and readability, reporting findings by severity with concrete fixes. Use when the user asks to review a diff, review changes, check code quality, or sanity-check code before committing or opening a PR.
---

# Quality Review

Review the selected code or the most recent changes and report issues grouped by severity, each with a concrete, actionable fix.

## Steps

1. **Get the diff.** Run `git diff` for unstaged changes or `git diff --staged` for staged changes. If the user pasted code instead, review that. If they named a PR, use `gh pr diff <number>`.
2. **Read in context.** Read each changed hunk against the surrounding file — a change that looks fine in isolation may break an invariant elsewhere.
3. **Scan each dimension** (see below).
4. **Report findings** grouped by dimension, most severe first. For every finding give the `file:line`, a one-line description of the defect, and a specific suggested fix.
5. **End with a short verdict** — safe to merge, or the blocking items that must change first.

## What to look for

- **Correctness** — off-by-one errors, null/undefined handling, inverted conditionals, unhandled error paths, resource leaks, incorrect async/await.
- **Security** — injection (SQL/shell/HTML), unvalidated input, secrets committed in code, unsafe deserialization, missing authorization checks.
- **Performance** — N+1 queries, needless allocation in hot loops, blocking I/O on a latency path, accidental quadratic behavior.
- **Readability** — unclear names, dead code, duplicated logic, missing handling of an obvious edge case.

Report only issues you can tie to a concrete failure; skip vague style nits unless the user asked for them.

For the full severity rubric and the exact output template, see [reference.md](reference.md).

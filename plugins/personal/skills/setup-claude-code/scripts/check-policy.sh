#!/usr/bin/env bash
# check-policy.sh — decide whether the org's remote-managed model pin is overridable to Opus.
# Reads the cached remote policy and applies the exact availableModels/enforce rules.
# Exit 0 = overridable (proceed), 2 = hard-locked (admin change needed), 3 = unparseable.
set -uo pipefail

RS="$HOME/.claude/remote-settings.json"
if [ ! -f "$RS" ]; then
  echo "No remote-managed policy at $RS — nothing pins the model; the override will apply. OK to proceed."
  exit 0
fi

python3 - "$RS" <<'PY'
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print("Could not parse %s: %s" % (path, e)); sys.exit(3)

model   = d.get("model")
effort  = d.get("effortLevel")
avail   = d.get("availableModels", None)          # None => key absent
enforce = bool(d.get("enforceAvailableModels", False))

print("Policy model pin        : %s" % model)
print("Policy effort pin       : %s" % effort)
print("availableModels         : %s" % avail)
print("enforceAvailableModels  : %s" % enforce)

def opus_allowed(avail):
    # Schema semantics: undefined => all models available; [] => ONLY the default model;
    # non-empty list => a model is selectable iff it's in the list. `opus`, `opus-4-8`,
    # and full IDs all contain "opus". enforce only changes what *Default* resolves to,
    # not whether an allowed model can be selected — so it doesn't gate us here.
    if avail is None:
        return True
    if len(avail) == 0:
        return False
    return any("opus" in str(m).lower() for m in avail)

if opus_allowed(avail):
    print("VERDICT: OVERRIDABLE — Opus is allowed; ANTHROPIC_MODEL=claude-opus-5 will win. Proceed.")
    # The skill pins the exact id. An allowlist that names only an *older* Opus (e.g. only
    # "opus-4-8", with no bare "opus" alias) still passes the check above but may refuse the
    # Opus 5 pin, so say so rather than let verify.sh fail with no explanation.
    if avail is not None:
        entries = [str(m) for m in avail if "opus" in str(m).lower()]
        if entries and not any(e.lower() in ("opus", "claude-opus-5", "opus-5") for e in entries):
            print("NOTE: the allowlist names Opus only as %s — if the exact `claude-opus-5` pin is" % entries)
            print("      refused, fall back to ANTHROPIC_MODEL=opus (the track-latest alias).")
    sys.exit(0)
else:
    print("VERDICT: HARD-LOCKED — Opus is not in the org allowlist, so the env-var override")
    print("will NOT work. This is an org-admin change, not a local one. Do not claim success.")
    sys.exit(2)
PY

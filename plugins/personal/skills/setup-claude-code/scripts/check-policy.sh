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
    print("VERDICT: OVERRIDABLE — Opus is allowed; ANTHROPIC_MODEL=opus will win. Proceed.")
    # The skill uses the track-latest `opus` alias, so what it resolves to changes as new Opus
    # models ship. An allowlist that names only specific older versions still passes the check
    # above but may not carry the alias forward, so surface it instead of letting verify.sh fail
    # with no explanation.
    if avail is not None:
        entries = [str(m) for m in avail if "opus" in str(m).lower()]
        if entries and not any(e.lower() == "opus" for e in entries):
            print("NOTE: the allowlist names Opus only as %s, not the bare `opus` alias — if the" % entries)
            print("      alias is refused, pin one of those exact ids in ANTHROPIC_MODEL instead.")
    sys.exit(0)
else:
    print("VERDICT: HARD-LOCKED — Opus is not in the org allowlist, so the env-var override")
    print("will NOT work. This is an org-admin change, not a local one. Do not claim success.")
    sys.exit(2)
PY

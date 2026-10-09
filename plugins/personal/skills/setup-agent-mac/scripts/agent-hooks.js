// agent-hooks.js — register or remove the agent-hold hooks in a Claude Code
// settings.json or a Codex hooks.json, leaving every other key and hook alone.
//
//   osascript -l JavaScript agent-hooks.js install|uninstall <file> <agent-hold.sh> claude|codex
//
// JavaScript for Automation ships with macOS, so this needs no python3 or jq. Entries
// are recognised by the exact command this script writes ('…/agent-hold.sh' start|stop),
// which makes install idempotent and uninstall exact. An unreadable or invalid file is
// reported and left untouched. A symlinked file is updated through the link, its
// permissions are kept (0600 for a new file), and the previous contents are kept beside
// the real file as <file>.agent-hold.bak with the same permissions.
ObjC.import('Foundation');
ObjC.import('stdio');

// Our generated commands, and nothing else that merely mentions agent-hold.sh.
const OURS = /'[^']*\/agent-hold\.sh' (start|stop)$/;

// [event, agent-hold action, matcher]. Stop is the normal turn end; the others catch
// turns that end without one, so a hold is not left behind until the session exits.
// PreToolUse re-takes the hold for a turn that resumed without a prompt.
const EVENTS = {
  claude: [
    ['UserPromptSubmit', 'start'],
    ['PreToolUse', 'start', '*'],
    ['Stop', 'stop'],
    ['StopFailure', 'stop'],
    ['SessionEnd', 'stop'],
    ['Notification', 'stop', 'idle_prompt'],
  ],
  codex: [
    ['UserPromptSubmit', 'start'],
    ['PreToolUse', 'start', '*'],
    ['Stop', 'stop'],
    ['Interrupt', 'stop'],
    ['SessionEnd', 'stop'],
  ],
};

// Codex caps SessionEnd and Interrupt hooks at 3 seconds.
const timeoutFor = (flavor, event) =>
  flavor === 'codex' && (event === 'SessionEnd' || event === 'Interrupt') ? 3 : 10;

const shellQuote = (s) => `'${s.replace(/'/g, `'\\''`)}'`;

const fm = $.NSFileManager.defaultManager;

function permissionsOf(path) {
  const attrs = fm.attributesOfItemAtPathError(path, null);
  if (attrs.isNil()) return null;
  const mode = attrs.objectForKey($.NSFilePosixPermissions);
  return mode.isNil() ? null : mode.intValue;
}

function setPermissions(path, mode) {
  const attrs = $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithInt(mode), $.NSFilePosixPermissions);
  if (!fm.setAttributesOfItemAtPathError(attrs, path, null)) throw new Error(`cannot set permissions on ${path}`);
}

function readJson(path) {
  if (!fm.fileExistsAtPath(path)) return { data: {}, raw: null };
  const raw = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (raw.isNil()) throw new Error(`cannot read ${path}`);
  const text = raw.js;
  const data = text.trim() === '' ? {} : JSON.parse(text);
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    throw new Error(`${path}: the top level is not a JSON object`);
  }
  return { data, raw: text };
}

// Atomic, with the given permissions applied before anything else can read it.
function writeText(path, text, mode) {
  const tmp = `${path}.agent-hold.tmp`;
  fm.removeItemAtPathError(tmp, null);
  if (!fm.createFileAtPathContentsAttributes(tmp, $(text).dataUsingEncoding($.NSUTF8StringEncoding),
      $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithInt(mode), $.NSFilePosixPermissions))) {
    throw new Error(`cannot write ${tmp}`);
  }
  setPermissions(tmp, mode);   // createFile applies the process umask on top of the mode
  // rename(2) swaps the file in atomically; the caller passes the resolved real path.
  if ($.rename(tmp, path) !== 0) {
    fm.removeItemAtPathError(tmp, null);
    throw new Error(`cannot replace ${path}`);
  }
}

function run(argv) {
  const [action, given, hold, flavor] = argv;
  if (!['install', 'uninstall'].includes(action) || !given || !hold || !EVENTS[flavor]) {
    throw new Error('usage: agent-hooks.js install|uninstall <file> <agent-hold.sh> claude|codex');
  }
  // Update a symlinked settings file (dotfiles) through the link, not over it.
  const path = $(given).stringByResolvingSymlinksInPath.js;
  const { data, raw } = readJson(path);
  const before = JSON.stringify(data);
  if (data.hooks !== undefined && (typeof data.hooks !== 'object' || data.hooks === null || Array.isArray(data.hooks))) {
    throw new Error(`${given}: "hooks" is not a JSON object; leaving the file untouched`);
  }
  const hooks = data.hooks || {};

  // Drop our previous entries, then any group or event they leave empty.
  for (const event of Object.keys(hooks)) {
    if (!Array.isArray(hooks[event])) continue;
    hooks[event] = hooks[event]
      .map((group) => Array.isArray(group.hooks)
        ? Object.assign({}, group, {
            hooks: group.hooks.filter((h) => !(typeof h.command === 'string' && OURS.test(h.command))),
          })
        : group)
      .filter((group) => !Array.isArray(group.hooks) || group.hooks.length > 0);
    if (hooks[event].length === 0) delete hooks[event];
  }

  if (action === 'install') {
    for (const [event, verb, matcher] of EVENTS[flavor]) {
      const group = {};
      if (matcher) group.matcher = matcher;
      group.hooks = [{ type: 'command', command: `${shellQuote(hold)} ${verb}`, timeout: timeoutFor(flavor, event) }];
      (hooks[event] = hooks[event] || []).push(group);
    }
  }

  if (Object.keys(hooks).length > 0) data.hooks = hooks;
  else delete data.hooks;

  // Nothing of ours to add or remove: leave the user's formatting alone.
  if (raw !== null && JSON.stringify(data) === before) return `${given}: unchanged`;
  const text = JSON.stringify(data, null, 2) + '\n';
  const dir = path.replace(/\/[^/]*$/, '');
  fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  // Settings files can hold tokens: keep their mode, and never widen it for a copy.
  const mode = raw === null ? 0o600 : (permissionsOf(path) ?? 0o600);
  if (raw !== null) writeText(`${path}.agent-hold.bak`, raw, mode);
  writeText(path, text, mode);
  return `${given}: ${action === 'install' ? 'registered' : 'removed'} agent-hold hooks`;
}

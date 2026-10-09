// agent-hooks.js — register or remove the agent-hold hooks in a Claude Code
// settings.json or a Codex hooks.json, leaving every other key and hook alone.
//
//   osascript -l JavaScript agent-hooks.js install|uninstall <file> <agent-hold.sh> claude|codex
//
// JavaScript for Automation ships with macOS, so this needs no python3 or jq. Entries
// are recognised by their command running agent-hold.sh, which makes install
// idempotent and uninstall exact. An unreadable or invalid file is reported and left
// untouched; the previous contents are kept beside it as <file>.agent-hold.bak.
ObjC.import('Foundation');

const MARK = 'agent-hold.sh';

// [event, agent-hold action, matcher]. Stop is the normal turn end; the others catch
// turns that end without one, so a hold is not left behind until the session exits.
const EVENTS = {
  claude: [
    ['UserPromptSubmit', 'start'],
    ['Stop', 'stop'],
    ['StopFailure', 'stop'],
    ['SessionEnd', 'stop'],
    ['Notification', 'stop', 'idle_prompt'],
  ],
  codex: [
    ['UserPromptSubmit', 'start'],
    ['Stop', 'stop'],
    ['Interrupt', 'stop'],
    ['SessionEnd', 'stop'],
  ],
};

// Codex caps SessionEnd and Interrupt hooks at 3 seconds.
const timeoutFor = (flavor, event) =>
  flavor === 'codex' && (event === 'SessionEnd' || event === 'Interrupt') ? 3 : 10;

const shellQuote = (s) => `'${s.replace(/'/g, `'\\''`)}'`;

function readJson(path) {
  if (!$.NSFileManager.defaultManager.fileExistsAtPath(path)) return { data: {}, raw: null };
  const raw = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (raw.isNil()) throw new Error(`cannot read ${path}`);
  const text = raw.js;
  const data = text.trim() === '' ? {} : JSON.parse(text);
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    throw new Error(`${path}: the top level is not a JSON object`);
  }
  return { data, raw: text };
}

function writeText(path, text) {
  const ok = $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  if (!ok) throw new Error(`cannot write ${path}`);
}

function run(argv) {
  const [action, path, hold, flavor] = argv;
  if (!['install', 'uninstall'].includes(action) || !path || !hold || !EVENTS[flavor]) {
    throw new Error('usage: agent-hooks.js install|uninstall <file> <agent-hold.sh> claude|codex');
  }
  const { data, raw } = readJson(path);
  const hooks = typeof data.hooks === 'object' && data.hooks !== null ? data.hooks : {};

  // Drop our previous entries, then any group or event they leave empty.
  for (const event of Object.keys(hooks)) {
    if (!Array.isArray(hooks[event])) continue;
    hooks[event] = hooks[event]
      .map((group) => Array.isArray(group.hooks)
        ? Object.assign({}, group, {
            hooks: group.hooks.filter((h) => !(typeof h.command === 'string' && h.command.includes(MARK))),
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

  const text = JSON.stringify(data, null, 2) + '\n';
  if (text === raw) return `${path}: unchanged`;
  const dir = path.replace(/\/[^/]*$/, '');
  $.NSFileManager.defaultManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  if (raw !== null) writeText(`${path}.agent-hold.bak`, raw);
  writeText(path, text);
  return `${path}: ${action === 'install' ? 'registered' : 'removed'} agent-hold hooks`;
}

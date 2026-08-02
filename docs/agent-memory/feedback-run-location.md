---
name: feedback-run-location
description: "When Simon needs to run a command himself, state explicitly WHERE (his terminal vs the chat)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 59076df8-2015-4bf2-9a34-fa4a0f7bc65f
---

When a command must be run by Simon (e.g. `sudo` installs needing a password),
state **explicitly** whether he should run it in his own terminal or type it into
the Claude Code chat with the leading `! ` prefix. Don't leave it ambiguous.

**Why:** He once pasted `sudo pacman -S cmake` into the chat without `!`, so it ran
in the sandbox (no TTY, sudo failed) instead of his session. Round-trip wasted.

**How to apply:** For anything Simon runs, say either "run this in your terminal:"
or "type this into this chat with a leading `! `:" — never just show a command and
assume he knows which. `!`-prefixed runs in-session (his TTY, can enter passwords);
a plain paste runs in Claude's sandbox.

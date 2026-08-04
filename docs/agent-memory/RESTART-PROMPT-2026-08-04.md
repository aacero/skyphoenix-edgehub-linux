# Restart prompt — next session

Copy everything between the two `---8<---` markers. Edit the seven bracketed
decisions first; leave them as-is and the agent will ask instead of guessing.

Companion: `docs/agent-memory/SESSION-HANDOFF-2026-08-04.md` (the full state).

---8<--- COPY FROM HERE ---8<---

Read docs/agent-memory/SESSION-HANDOFF-2026-08-04.md first, then BACKLOG.md's
section headings. Do NOT trust a BACKLOG.md entry without checking it against the
tree — six were found stale on 2026-08-04, including ones that described already
-shipped work as blocked. v1.0.0 is RELEASED (2026-07-28); current target v1.0.1.

MY DECISIONS (§11 of the handover) — these are now approved, build them:

1. behaviorProfile default:        [ calm | keep custom ]
2. Media artwork error state:      [ build it | leave it ]
3. Dead notificationBridge.send:   [ delete all three | keep + add a double without sendPriority ]
4. config.toml.bak on normal save: [ yes | reset-only, as today ]
5. Wallpaper/theme name collision: [ my intent: the shared names ARE a deliberate pairing | they are NOT — disambiguate in the UI ]
6. build-release/ (196 tracked files): [ delete and gitignore | leave it ]
7. "Surface a screen when noteworthy": [ design it as an ADR first | not now ]

RESEARCH (none has ever been done in this repo — see handover §5). Use primary
sources, follow agent-framework/canonical/policies/research-policy.md, and deliver
a source ledger. Priorities in order:
  a. Open-Meteo's free-tier surface beyond the 10 fields the weather widget now
     uses — air quality, pollen, minutely precipitation. What is worth adding to
     a wall panel, and what the rate limits/attribution require.
  b. AppImage self-update in practice: how comparable Qt/Linux desktop projects
     wire zsync discovery, and what breaks in the field. We ship
     X-AppImage-UpdateInformation but the download-and-patch round trip has
     never been exercised end to end.
  c. MPRIS quirks across real players (Spotify, VLC, Firefox, mpv) — our D-Bus
     fan-out is GCOVR_EXCL'd and deliberately left to on-device E2E.
  d. A competitive scan of comparable dashboard/wall-panel products, to inform 7.
File findings as BACKLOG.md Candidates. Do not implement from research without
asking me.

STILL MINE, don't wait on them: I need to confirm the Lemon Squeezy store product
+ mint webhook are live (the keygen half is done), and I need to eyeball the panel
for W3 widget smoothness.

WORKING RULES (these cost real time last session, they're in handover §8):
- The QML harness loads widgets from qrc: — rebuild xeneon-qmltestrunner before
  believing any negative control. But tst_theme.qml imports the filesystem path,
  so its font loaders never touch the qrc. Know which file you're in.
- Always assert a sabotage actually applied. A control that didn't apply looks
  exactly like a control that didn't bite.
- Every new guard needs a negative control proving it fails when the behaviour is
  removed, with the evidence in the commit body.
- Never max out CPU/GPU/RAM. Boundary tests fine, hammering never — it crashed
  this machine once.
- pkill -f kills the invoking shell; pkill -x silently no-ops past 15 chars.
- Branch, PR, and wait for my approval to merge. Report actual commands and output.

Start by reconciling BACKLOG.md against the tree and telling me what's actually
open, before building anything.

---8<--- COPY TO HERE ---8<---

## If you would rather not decide anything up front

Delete the numbered block. The agent will work the approved backlog instead. The
most productive open thread is test integrity — it has found a real defect every
time it has been run, and its own open follow-up is that *nothing forces the
fail-on-violation proof for new guards*. Making that enforceable rather than
conventional is a clean, well-scoped next item.

## Why the research block is scoped to Candidates

No web research has ever been done in this repository. The first pass should
inform decisions, not trigger changes — otherwise implementation gets built on a
source you have not read. The scope-control policy already requires this;
the prompt restates it so the boundary is explicit.

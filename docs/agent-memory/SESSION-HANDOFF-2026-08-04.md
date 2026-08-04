# Session handover — 2026-08-04

Written at Simon's request, at the point where **all 30 catalog widgets have had
their first audit pass**. This is the "pick it up cold" document: what is done,
what is not, what needs deciding, and which traps cost time so they are not paid
for twice.

Companion documents, all still current:

| Document | What it owns |
|---|---|
| `BACKLOG.md` | The item list. Sections are load-bearing — see "How the backlog is organised" below. |
| `docs/testing/widget-audit-2026-08-03.md` | The 1487-line running record of the widget pass. Per-widget findings live there, not here. |
| `AGENTS.md` | Build, test, layout, FFI rules. Read before touching anything. |
| `docs/agent-memory/SESSION-HANDOFF-2026-07-20.md` | The previous handover. Superseded for status, still useful for the test-regression history. |

---

## 1. Where things stand in one paragraph

**v1.0.0 is RELEASED** — published 2026-07-28 with signed `.deb`, `.rpm`,
`.AppImage` and `.zsync` assets, after alpha.1, alpha.2, beta.1 and rc.1. The
current release target is **v1.0.1**; the metadata contract reports
`stage=development, target=v1.0.1, published=v1.0.0`. `master` is green and
carries 30 widgets, a Dashboard with pages and an idle-gated auto-cycle, a
companion Manager that live-pushes over a control socket, a Rust core behind a
hand-written C FFI, and ~30 CI checks including a nested-compositor GUI suite and
reviewed visual baselines. The widget feature audit is **complete for all 30
widgets**. Nothing is release-blocking; what remains is v1.0.1/v1.1 backlog plus
a small number of genuine product decisions.

> **Read §6 before trusting any `BACKLOG.md` entry.** Large parts of it still use
> pre-release language ("RC exit criterion", "no release has ever shipped an
> AppImage") that was true when written and is not true now. Six stale entries
> were closed on 2026-08-04 alone.

---

## 2. What shipped in this session (2026-08-04)

Four PRs, all merged to `master` except the last (open at time of writing).

| PR | What | Why it mattered |
|---|---|---|
| #21 | `check_ui_links.sh` and `check_tree_walks.py` reported OK when they had done no work | Seventh and eighth instances of the repo's most persistent defect class |
| #22 | New gate `scripts/check_bundled_fonts.py` | The bundled-font contract spanned three files nothing compared |
| #23 | Pinned the D1/D2 defaults; removed an assertion that could not fail | Both decisions were already shipped; the guards protecting them were weak |
| #24 | Killed a live CI flake; pinned the invariant a visual baseline rests on | The flake blocked #23 and would have blocked others |

### The through-line

Every one of these is the same shape: **something was verified by an artifact
that could not fail.** A gate that scanned zero files and printed OK. A test
whose assertion was `X || string.length > 0`. A guard that passed because the
*test harness* had a resource the *product* did not. A baseline that was
deterministic only because someone had been careful, with nothing asserting the
branch order that made it so.

`BACKLOG.md` "Test-integrity debt" has recorded this shape eight times now, with
the standing rule: **a gate must assert its own subjects exist.** Two refinements
were added this session and are worth carrying forward:

1. **Printing the subject count is not the same as flooring it.** Both gates in
   #21 already printed their count. A reader could see `0` and the exit code was
   still `0`. The count is for humans; the floor is what makes the gate fail.
2. **A zero-floor alone is too weak for a gate that scans more than its own
   subjects.** `check_tree_walks.py` walks the whole repo, so excluding `ui/qml`
   still left 499 files and 17,264 functions scanned — `scanned == 0` sails
   through while the gate is blind to exactly the code it guards. Assert "my
   specific subjects are present", not "something was scanned".

---

## 3. The widget first pass — complete

All 30 widgets audited, 2026-08-03. Method is documented in the audit file
§"Method, per widget"; in short: enumerate every `schema:` key, classify its
strongest existing coverage as **behaviour** / **shape-only** / **absent**,
exercise everything that is not `behaviour`, and fix each finding with a negative
control proving the new assertion fails when the behaviour is removed.

**Why it existed:** `WidgetConfigSchema.qml` opens with the promise *"every
option here is honoured by the corresponding widget — nothing is decorative."*
Nothing verified that. The enumerated-requirements matrix only requires that
*some* assertion mentions a key's leaf token, which a schema-shape test satisfies
completely while proving nothing about the widget.

### Results

35 findings across 30 widgets and 2 shared seams. **All fixed except 2**, both
deliberately filed as Candidates rather than fixed unilaterally.

| Findings | Widgets |
|---|---|
| 0 | `break`, `quote` |
| 1 | `gpu`, `ram`, `net`, `disk`, `packages`, `sinceinstall`, `clock`, `analog`, `moon`, `focus`, `tasks`, `rightnow`, `notes`, `habit`, `hydration`, `meds`, `braindump`, `routine`, `httpjson`, `nownext`, `countdown`, `eod` |
| 2 | `cpu`, `sensors`, `kpi`, `calendar`, `weather` |
| 5 | `media` |

Plus the **NetHub seam** (shared by calendar, weather, nownext, httpjson, kpi and
the update checker): 5 findings, 4 fixed.

### Widget quality assessment

This is a judgement call layered on the audit, not a mechanical result.

**In good shape — no action expected**
`break`, `quote` (clean pass), and the three metric widgets `cpu` / `gpu` / `ram`
after their fixes. `break` is notable: it survived the audit with zero findings
*and* its parked-state behaviour is now pinned (#24).

**Solid, one fix applied, no known residue**
`net`, `disk`, `packages`, `sinceinstall`, `clock`, `analog`, `moon`, `focus`,
`tasks`, `rightnow`, `notes`, `habit`, `hydration`, `meds`, `braindump`,
`routine`, `httpjson`, `nownext`, `countdown`, `eod`.

**Improved substantially this session, worth re-reviewing on device**
- **`weather`** — was "the most basic weather widget ever" (Simon's words). Now
  requests humidity, wind speed + direction, precipitation + probability, UV,
  cloud cover, pressure, sunrise/sunset; renders them as a responsive
  `GridLayout` whose font ceilings scale with the tile's short edge rather than
  flat pixel caps. Two rounds of layout work were needed — the first fix was
  still "tiny with empty space" because the ceilings were flat literals (88/21 px
  on a ~1280×770 tile).
- **`media`** — the only widget with **open findings** (see §4).

**Known weak spot in the shared layer, now covered**
The **NetHub** egress gate had two branches unreachable by construction: product
code excluded tests via `!mk` guards, so the request watchdog and the
response-cap header could never fire in a test. Both fixed by removing the guards
and injecting a fake timer factory. The shared fake XHR also silently swallowed
every header, which is why nobody noticed.

---

## 4. What is NOT done

### 4a. Two open widget findings (filed as Candidates, need a decision)

1. **`"Artwork unavailable"` in MediaWidget can never render, and the case it
   was written for is unhandled.** `MediaWidget.qml:55` reaches that string only
   when `avail && artUrl && !artworkSource.length` *and* `remoteArtworkBlocked`
   is false — but those three conjuncts *are* the definition of
   `remoteArtworkBlocked` at `:53`. Dead by algebra.
   The live gap it was presumably meant to cover: a `file://` artwork that passes
   the policy but fails to **load** (deleted, unreadable, corrupt) leaves
   `artworkSource` non-empty, shows no notice, and draws a silently blank art
   box. Wiring the rung to the `Image`'s `status === Image.Error` makes it both
   reachable and correct. Small, user-visible, testable — the artwork policy
   already has ten cases to extend. Audit finding 10.4.

2. **A dead `notificationBridge.send` fallback in three widgets.**
   `FocusWidget.qml:241`, `BreakWidget.qml:194`, `MedsWidget.qml:297` each fall
   back to `send()` when the bridge has no `sendPriority()`. There is exactly one
   real bridge and it implements `sendPriority`; both test doubles do too. Dead
   in production *and* in tests, three times over. Unlike a version-skew fallback
   it cannot become reachable — QML and the C++ bridge ship in one binary from
   one qrc. Either delete all three (keeping the outer `&& .send` guard, which
   still usefully covers "no bridge injected"), or keep them and give one double
   no `sendPriority`. **Wants a single decision, not three.** Audit finding N.5.

### 4b. The "Blocked on Simon" table is now CLOSED

All four decisions are resolved. **Verified against the tree on 2026-08-04, not
taken from the backlog** — which still listed several of these as open.

| # | Decision | Status |
|---|---|---|
| D1 | Calm default theme | **DECIDED — already shipped.** Default is `nord`, the calm palette (`core/src/config.rs:173`, `ui/qml/Theme.qml:362`). |
| D2 | Default font | **DECIDED — already shipped.** Atkinson Hyperlegible (`Theme.qml:235`). |
| D3 | Lawyer pass on distro theme naming | **DECIDED 2026-08-04: the naming stays as it is.** Already de-risked by `Theme.qml:334` keeping distro modes colour-only — no logos, no wordmarks. |
| D4 | Payment provider | **DECIDED (Lemon Squeezy / Gumroad) and the code half is DONE.** |

**Licensing — the keygen step is DONE, contrary to the backlog.** `core/src/license.rs:77`
shows the zero placeholder commented out and `:78` carries a real
`ISSUER_PUBLIC_KEY`; `:739` notes the "still a placeholder" release guard was
retired. Verification is armed. `tools/license-tool` and `tools/license-webhook`
are both built, with `scripts/setup-lemonsqueezy.py` to register the webhook.

**The only licensing item that cannot be verified from the repository** is
whether the Lemon Squeezy/Gumroad *store product* has actually been created and
the webhook registered — that is an action in an external account, not in code.
See `docs/LICENSING.md` §"Selling". If purchases are not yet minting keys, that
is the step.

**One genuinely new question, raised 2026-08-04, never asked before:** should the
per-widget `behaviorProfile` default to `calm` instead of `custom` — i.e. no
celebrations, reward points or nudges out of the box? This is the *other*
plausible reading of "calm by default"; it is a real behaviour change rather than
a palette. Only `focus` and `tasks` carry the key.

### 4c. Open engineering gaps (no decision needed, just work)

- **W3 — widget smoothness needs Simon's eyes on the panel.** All the motion work
  landed (Sensors delegate churn, Dashboard and EdgeClone reorder teleports,
  PillButton glyph scaling, add/remove fades). None of it is verified on the real
  device because the offscreen harness cannot instantiate `qrc:` widgets —
  delegate survival is asserted via the Loader, not the widget. **This is the one
  W-item that genuinely needs a human looking at the screen.**
- **`backup_config()` is still only reached via `--reset`.** `config.toml.bak`
  is never written by a normal save, so the "canonical good-config backup" is not
  a routine safety net. Worth deciding whether a save should ever produce one.
- ~~**AppImage zsync update path has never worked and has never run.**~~
  **STALE — resolved before v1.0.0.** That entry was audited 2026-07-17 and says
  "no release has ever shipped an AppImage or a `.zsync`". v1.0.0 (2026-07-28)
  shipped **both**: `xeneon-edge-hub-1.0.0-x86_64.AppImage` (56 MB) and
  `…AppImage.zsync` (329 KB), alongside signed `.deb`/`.rpm` and `SHA256SUMS.asc`.
  The `X-AppImage-UpdateInformation` the entry called an open product decision is
  wired at `packaging/appimage/build-appimage.sh:91`
  (`LDAI_UPDATE_INFORMATION=gh-releases-zsync|…|latest|…`, with the older
  `UPDATE_INFORMATION` name also exported for tool-vintage safety).
  **What is still genuinely unproven:** a true download-and-patch round trip. The
  cross-file invariants are guarded offline by
  `scripts/check_appimage_update_contract.sh`, which is not a substitute. The
  first real test is whether a v1.0.0 AppImage self-updates to v1.0.1 — worth
  watching on the next release rather than treating as open work now.
- **Wallpaper/theme name collision — it is FIVE names, not three.** Measured
  overlap: `aurora`, `ember`, `midnight`, `nebula`, `sunset`. The nuance before
  anyone "fixes" it: `WallpaperCatalog.qml`'s header says the wallpapers are
  "tuned to the built-in themes", so a shared name may be a deliberate *pairing*.
  But only 5 of 12 wallpapers match a theme and 19 of 24 themes have no
  wallpaper, so it reads as a systematic pairing that is not one. Renaming either
  set rewrites persisted config and needs a migration — **the cheap fix is UI
  disambiguation plus honest copy. Decide the intent first; it is a copy
  question, not an engineering one.**
- **`build-release/` is tracked in git — 196 files of build output.** Found
  2026-08-04. Not cleaned because it is a large deletion that wants approval.
- **`scripts/test.sh` is still the framework adoption stub** — it echoes "No test
  command configured" and exits 0. Under the evidence policy it must never be
  cited as passing validation.

---

## 5. Findings from online research

**None. No web research was performed in this session or the preceding widget
audit sessions.** Everything recorded in the audit and in `BACKLOG.md` was
derived from reading this repository's own source, tests, CI logs and git
history, and from running the suites locally.

This is stated explicitly because the handover was asked to include such a
section, and inventing findings would be worse than reporting the absence. If
external input is wanted, the areas where it would genuinely help are:

- **Open-Meteo API surface** — the weather widget now consumes ten fields; a
  review of what else the free tier offers (air quality, pollen, minutely
  precipitation) could inform the next weather pass.
- **MPRIS edge cases across players** — the D-Bus fan-out is deliberately left
  to on-device E2E and is `GCOVR_EXCL`'d with that reason. Real-world player
  quirks are exactly the kind of thing documentation would shortcut.
- **AppImage update information conventions** — the `X-AppImage-UpdateInformation`
  decision above would benefit from seeing how comparable projects wire zsync
  discovery.
- **Comparable dashboard products** — for the "what should a screen surface"
  question in §7. No competitive scan has been done.

---

## 6. Two things the backlog got wrong (read this before trusting an entry)

`BACKLOG.md`'s own header says: *"If an entry here disagrees with the code, the
code wins."* That is not a formality. **Five items closed on 2026-08-04 were
stale entries describing problems that were already fixed:**

- **D1** claimed "current default: dark". Both layers default to `nord`
  (`core/src/config.rs:173`, `ui/qml/Theme.qml:362`), and the Rust test pinning
  it has read *"shipped default is the calm palette (D1)"* since it was written.
  The `mode = "dark"` at `config.rs:1847` that looks like a default is a **legacy
  test fixture**.
- **D1** also asked for "calm as the default theme". **There is no `calm`
  theme.** `calm` is a per-widget `behaviorProfile`. The backlog had already
  recorded this discovery elsewhere without reconciling the D1 row.
- **D2** was already implemented (`Theme.qml:235`).
- **"CI has a font blind spot"** described `fontMono` resolving through
  fontconfig. It has been bundled since 2026-08-02.
- **`preset-health` "STILL FRAGILE"** was fixed **in the same PR that filed the
  entry** (#13).

**Recommendation for the next session:** a periodic reconciliation pass over
`BACKLOG.md` against the tree is worth more than working entries at face value.
In every one of the five cases the *real* work was underneath — an invariant that
nothing asserted — and would have been missed by either believing the entry or
ignoring it.

---

## 7. What would be better functionality (product ideas, unapproved)

Ordered by how much they would change the product, not by effort.

1. **Surface a screen when something on it becomes noteworthy.** The shipped
   auto-cycle takes turns on a clock. The interesting version reacts to content:
   a threshold crossed, a calendar event imminent, a break due, a countdown
   expiring. The repository already has the vocabulary — widget `state` /
   `Warning` / `Critical`, and a priority-alert GUI suite. This would make the
   other screens *earn* attention instead of merely taking turns. The idle
   rotation was the cheap half. **Needs a product decision, not a setting.**
2. **Make `--reset`'s backup a routine safety net** rather than a reset-only
   artifact (see §4c). Users lose layouts; a `.bak` written on every successful
   save is cheap insurance.
3. **Media artwork error state** (§4a item 1) — small, visible, and the widget
   currently draws a silently blank box for a broken file.
4. **A premium preset pack and/or custom user widgets** as Pro-gated content. The
   flag infrastructure is one line; it needs a "which items" decision. Currently
   Pro gates a theme pack only.
5. **Weather, next pass** — the widget is now genuinely informative but still
   shows one location. Multi-location, or a "conditions changed materially"
   highlight, would suit a wall panel.

---

## 8. Traps that cost real time (do not re-pay these)

**Testing**
- **The QML harness loads widgets from `qrc:`.** A product edit proves nothing
  until `xeneon-qmltestrunner` is rebuilt. This invalidated four negative
  controls in a row during the weather work. `run_ui_tests.sh` has a stale-runner
  guard; a manual `-input` run does not.
- **But `tst_theme.qml` imports `"../../ui/qml"` as a FILESYSTEM path**, so its
  font loaders read `assets/fonts/` off disk and never touch the qrc. Sabotaging
  `fonts.qrc` leaves it green. The two facts above coexist; know which file you
  are in.
- **A control that does not apply looks exactly like a control that does not
  bite.** Two sabotage attempts silently no-op'd on 2026-08-04 (a `sed` that
  matched nothing; a Python edit that broke syntax instead of the regex). Always
  assert the sabotage landed before drawing a conclusion.
- **`test_x_data()` is QtTest's data provider for `test_x()`.** Three tests had
  never executed. `scripts/check_live_tests.sh` gates this now.
- **Never bound test memory with the kernel OOM killer.** Use `ulimit -v` plus an
  RSS watchdog. And never write a test that maxes CPU/GPU/RAM — this crashed
  Simon's machine once. Boundary tests are fine; hammering is never fine.

**Tooling**
- **`pkill -f <pattern>` kills the invoking shell** (the Bash tool's command line
  contains the pattern) → exit 144, script dies mid-way. Use `kill` by PID from a
  prior `pgrep`, or a bracket class (`"[g]h pr checks"`).
- **`pkill -x <name>` silently matches nothing when the name exceeds 15 chars.**
  `xeneon-edge-manager` is 19 — the command reports success having done nothing.
  `xeneon-edge-hub` is exactly 15 and works, which makes the failure look
  inconsistent.
- **`visual_baselines.py update` rewrites ALL fifty baselines**, not the one you
  changed — which its own docstring forbids. Re-capture the single case through
  `write_normalized` and patch that one manifest entry; the diff should be one
  PNG and three manifest fields.
- **`scripts/gen_widgets.py` is stale bootstrap scaffolding, not a source of
  truth.** `--force` would replace a real widget with a 20-line stub. It did,
  once, to `RamWidget`.
- **Committing on `master` and pushing a branch ref merges nothing.** PR #19
  appeared to merge and did not; recovered from reflog. Verify the branch
  actually carries the commit before opening the PR.

**Product**
- **Single-writer rule:** a running `xeneon-edge-manager` re-pushes its UI state
  to the hub on hub start, silently reverting direct `config.toml` edits. Stop
  the Manager before editing config by hand.
- **Wayland window placement:** position and `setScreen` *before*
  `showFullScreen`/`show`, or the compositor picks the wrong display.

---

## 9. How the backlog is organised

Sections are load-bearing under the scope-control policy:

- **Blocked on Simon** — nothing downstream proceeds.
- **Beta workstreams / Known gaps / v1.1 / Test-integrity debt** — approved work.
  An agent may pick these up autonomously.
- **Candidates** — unapproved. **Never implemented without explicit product-owner
  approval.** Findings from any work go here, not into the code.

---

## 10. Restarting cold — suggested first moves

1. Read `AGENTS.md`, then this file, then `BACKLOG.md`'s section headings.
2. `./scripts/run_all_tests.sh` for a full picture, or the focused gates for a
   quick one. Everything was green at handover.
3. **Reconcile before building.** Given §6, spot-check any backlog entry against
   the tree before working it.
4. If continuing the productive thread: the test-integrity work has found a real
   defect every time it has been run, and its own open follow-up is that *nothing
   forces the fail-on-violation proof for new guards*. The proposed fix — require
   a guard's sabotage evidence in the PR body — is currently convention, not a
   gate. Making it enforceable is a scoped, valuable next item.
5. See §11 for the only things that still need Simon.

---

## 11. What still needs Simon — the complete list

Compiled 2026-08-04 by checking each candidate **against the tree**, after the
"blocked on Simon" table turned out to be entirely resolved. **Nothing here is
release-blocking**; v1.0.0 is out and none of it is a defect in shipped
behaviour.

### Needs a decision before an agent may act (scope-control policy)

| # | Question | Why it needs you |
|---|---|---|
| 1 | Should `behaviorProfile` default to `calm` rather than `custom`? | A real behaviour change — celebrations, reward points and nudges off by default. The other reading of "calm by default". Affects `focus` and `tasks`. |
| 2 | Media artwork error state (audit 10.4) | A `file://` artwork that passes policy but fails to load draws a **silently blank art box**. The fix is small and testable, but it is a Candidate — user-visible behaviour, so it wants approval. |
| 3 | The dead `notificationBridge.send` fallback in 3 widgets (audit N.5) | Delete all three, or keep them and give one test double no `sendPriority`. **One decision, not three.** Dead code, not a defect. |
| 4 | Should a normal save ever write `config.toml.bak`? | Today the backup exists only on `--reset`, so the "canonical good-config backup" is not a routine safety net. |
| 5 | Wallpaper/theme name collision (5 shared names) | Purely a **copy/intent** question: is Midnight-the-wallpaper *meant* to pair with Midnight-the-theme? Renaming needs a config migration, so the cheap fix is UI disambiguation. Decide intent first. |
| 6 | "Surface a screen when something on it becomes noteworthy" | Product direction. The shipped auto-cycle takes turns on a clock; the interesting version reacts to content. Needs a decision, not a setting. |
| 7 | May `build-release/` be deleted from git? | 196 files of build output are **tracked**. Removing them is a large deletion, so it wants explicit approval. |

### Needs you to do something outside the repository

| # | Action |
|---|---|
| 8 | **Confirm the Lemon Squeezy / Gumroad store product exists and the mint webhook is registered.** The code half is done and the issuer key is armed; this is the one licensing step that cannot be verified from the tree. If purchases are not minting keys, this is why. |
| 9 | **Look at the panel for W3 (widget smoothness).** All the motion work landed but none is verified on the real device — the offscreen harness cannot instantiate `qrc:` widgets, so delegate survival is asserted via the Loader, not the widget. This is the one item no amount of test work can close. |

### Nice to have, entirely optional

| # | Item |
|---|---|
| 10 | Whether to Pro-gate a **preset pack** and/or **custom user widgets**. The flag infrastructure is one line; it needs a "which items" answer. Pro currently gates a theme pack only. |
| 11 | Whether online research is wanted (§5) — no web research has been done in any of these sessions. |

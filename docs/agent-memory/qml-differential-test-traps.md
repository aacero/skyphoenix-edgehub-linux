---
name: qml-differential-test-traps
description: "Two ways a QML parity test passes with the bug reintroduced — self-supplied injection callbacks, and store.load() wiping appearance"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d97d3721-bc7b-47b8-a5e8-108867083bee
  modified: 2026-07-20T16:25:05.438Z
---

Writing the Manager↔hub WYSIWYG parity test (2026-07-20, Phase 2.1) produced two
tests that were green **with the bug deliberately reintroduced**. Both are shapes
that will recur in this repo, because both look correct on the page.

**Trap 1 — testing the injector instead of the caller.** `EdgeClone.injectInto`
takes a `sizeFn` callback. My first test supplied its *own* correct callback and
asserted the widget got the right class. That proves `injectInto` binds what it
is handed — it cannot see the clone's real call site passing the WRONG thing,
which was the entire bug. Reverting `EdgeClone.qml` left the suite green.
The fix: reach the widget the component ACTUALLY rendered, through the delegate's
own Loader (`wId`), so the component's real call site is in the path.

**Trap 2 — `DashboardStore.load()` replaces the whole document, appearance
included.** I set the orientation, then called `store.load("blank")` per case, so
every case silently reverted to portrait — the exact answer the test existed to
distinguish landscape from. It agreed with the bug. Order is: `load()` first,
`setAppearance()` after.

**Also:** QtTest aborts a test function at the FIRST `compare()` failure, so one
red line in a cross-product loop means everything after it never ran. Don't read
"1 failure" as "1 divergence". And a cross-product loop with a `continue` needs an
anti-vacuity counter (`verify(checked >= N)`), or a filter that skips everything
reports a green cross product over zero cases.

**Why:** these are the Category-B failure mode from [[test-regression-root-cause]]
— pins that exist and run but cannot observe the failure — appearing *while
writing the fix for* a Category-B bug. Reading the test does not reveal them.

**How to apply:** revert-and-run is not optional for a parity/differential test,
it is the only thing that distinguishes one from decoration. See
[[test-integrity]] for the general rule and [[dashboard-architecture]] for the
store semantics.

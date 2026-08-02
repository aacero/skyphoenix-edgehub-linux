---
name: test-integrity
description: "The QtTest _data trap that silently disabled 3 tests, and the rule that a guard isn't done until proven to fail"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: cc3f5c02-a801-4f39-936e-d4d0ed258239
---

**A test that cannot fail is worse than no test — it spends review trust without
earning it.** Prove every guard fails when violated: break the thing, watch it go
red, restore it. Report that you did.

**The recurring shape: a gate reports SUCCESS for the state where it did no work.**
Six found in this repo across 2026-07-16/17, every one green for years:
| Gate | How it was silently inert |
|---|---|
| 3 QtTest cases | named `test_x_data()` → registered as the data provider for a `test_x()` that never existed |
| `coverage.sh` C++ gate | `--json-summary build` → gcovr 8 reads it as an OUTPUT FILE → error → `2>/dev/null` → `CPP_PCT=n/a` → `if [ "$CPP_PCT" != "n/a" ]` **skipped itself** |
| `qml_coverage.py` | `ratio = ... if total else 100.0` → an empty matrix scored **100% PASS**; and `read()` returns `""` on OSError, so a typo'd source dropped 24 behaviors *without* a coverage drop (its uncovered ones left the denominator too) |
| `check_ui_links.sh` (mine) | grepped `openUrlExternally("` — the target call was line-wrapped, so it matched nothing and passed on a tree with the dead link still in it |
| `check_live_tests.sh` + `check_doc_links.sh` (mine) | reported OK on an **empty tree** — zero subjects, zero work, green |

**The fix is always the same: a gate must assert its own subjects exist.**
`scripts/check_no_raw_xhr.sh` is the model and got it right from the start — it
checks *"the gate must still own exactly one construction site"*, so if its
pattern ever stops matching it FAILS instead of going quiet. That single line is
why the no-telemetry claim rests on something. Copy it: count subjects, print the
count in the OK line (a reader can then see the gate had work to do), and make
zero-subjects fatal. `.github/workflows/supply-chain.yml`'s no-egress job is the
other model — three negative controls, each requiring the SPECIFIC failure
message because "exit 1 alone is not enough, a typo also exits 1".

**Why:** On 2026-07-16 a Wave-3 agent reported "weather refuses to fake an hourly
chart — *a test now fails if the URL ever grows one*". Verifying it, I injected
`&hourly=temperature_2m` into `WeatherWidget`'s request. The suite stayed **green**.

Root cause — **QtTest overloads the `_data` suffix**: `test_X_data()` is registered
as the DATA PROVIDER for `test_X()`, not as a test. The guard was named
`test_the_request_never_asks_for_hourly_data()`, so QtTest silently made it the
provider for a `test_the_request_never_asks_for_hourly()` that never existed, and
ran NEITHER. No warning. Green suite. 9 of 10 functions in the TestCase ran and
`-functions` listed the guard nowhere.

A sweep found **three** tests that had never once executed, two predating that
agent. One (`test_seed_shapes_data`) FAILED the moment it could run: it pinned
gaming=[System, Play] / productivity=[Focus, System], stale since the ≤3-tiles
re-authoring split them into [GPU, System, Play] / [Focus, Day, System]. Nobody
noticed the drift because the pin never ran.

**How to apply:**
- NEVER name a QML test `test_*_data()`. `scripts/check_live_tests.sh` now gates
  exactly this (wired into `run_all_tests.sh` + ci.yml's lint step, no new job).
  It is a *narrow* gate: it only catches this one trap.
- The general duty is NOT gated and is yours: an agent reporting "a test now
  guards X" is a claim, not evidence. Verify by sabotage before believing it —
  and before merging on the strength of it.
- Grep the RIGHT filename. My first check used `tst_weather*.qml`; the file is
  `tst_gen_weather.qml`, and the wrong grep briefly "confirmed" the guard absent.
- The gold standard already in this repo: the no-egress job in
  `.github/workflows/supply-chain.yml` runs three negative controls and requires
  the SPECIFIC failure message, because "exit 1 alone is not enough — a typo also
  exits 1". Copy that pattern. See [[ci-setup]], [[runtime-e2e-testing]].
- Same failure family as the docs link checker (80352d3): it had been RED on
  master for two runs over a link that was actually *valid* (it tested the `#anchor`
  as part of the filename). A gate that cries wolf gets ignored — and that is
  what let a dead security contact and 202MB of committed build output sit
  unnoticed in the same files. A wrong gate and an inert gate cost the same.

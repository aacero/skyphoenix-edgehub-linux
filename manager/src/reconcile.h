#pragma once

#include <QString>

// Decision for what to do with a UI-state document pulled from the hub over IPC,
// given the reconnect/suppression context. Pure - no I/O, no clock - so the
// reconnect state machine is testable with a decision table.
enum class ReconcileAction {
    AdoptHub,          // adopt the hub's pulled state (subject to the suppress check)
    KeepAndPushEdit,   // hub unchanged since we went offline → (re)push our buffered edit
    RequireConflict,   // both sides changed or age is ambiguous → require Retry/Discard
    Ignore,            // inside the post-push suppression window → leave state untouched
};

// Decide the fate of a pulled state.
//   awaitingHub      - a buffered offline edit is waiting to be reconciled on the
//                      first pull after reconnecting.
//   havePendingPush  - a buffered offline edit actually exists.
//   pulled           - the UI-state the hub just sent us.
//   lastHub          - the last UI-state we knew the hub held.
//   suppressed       - nowMs < suppressAdoptUntilMs (a recent push we shouldn't clobber).
//
// When awaitingHub: if the hub's state changed while we were offline and a local
// edit exists, neither side is silently discarded (RequireConflict). With no
// prior baseline but a non-empty pull, age is ambiguous and also requires that
// explicit choice. If there is no buffered edit, the Hub can be adopted. An
// empty pull carries nothing to clobber, so there we (re)push our edit.
// Valid JSON states are compared by value: insignificant whitespace and object-key
// order do not count as device changes, while array order and value changes do.
// Malformed inputs retain conservative exact-text comparison.
// Outside the reconnect reconcile, adopt the hub state unless suppressed.
ReconcileAction reconcileOnPull(bool awaitingHub, bool havePendingPush,
                                const QString& pulled, const QString& lastHub,
                                bool suppressed);

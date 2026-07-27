// Decision table for reconcileOnPull() - the reconnect PULL-before-PUSH state
// machine. Pure, GUILESS.
#include <QtTest>

#include "reconcile.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

Q_DECLARE_METATYPE(ReconcileAction)

class TstReconcile : public QObject {
    Q_OBJECT
private slots:
    void table_data() {
        QTest::addColumn<bool>("awaitingHub");
        QTest::addColumn<bool>("havePendingPush");
        QTest::addColumn<QString>("pulled");
        QTest::addColumn<QString>("lastHub");
        QTest::addColumn<bool>("suppressed");
        QTest::addColumn<ReconcileAction>("expect");

        // ── Not reconciling a reconnect: plain adopt vs suppress ──
        QTest::newRow("adopt-normal")
            << false << false << QString("A") << QString("B") << false << ReconcileAction::AdoptHub;
        QTest::newRow("adopt-suppressed")
            << false << false << QString("A") << QString("B") << true  << ReconcileAction::Ignore;
        QTest::newRow("adopt-normal-with-pending-not-awaiting")
            << false << true  << QString("A") << QString("B") << false << ReconcileAction::AdoptHub;

        // ── Reconnect reconcile: both sides changed → explicit conflict ──
        QTest::newRow("hub-changed-conflict")
            << true  << true  << QString("NEW") << QString("OLD") << false << ReconcileAction::RequireConflict;
        // hubChanged wins even if suppressed.
        QTest::newRow("hub-changed-conflict-suppressed")
            << true  << true  << QString("NEW") << QString("OLD") << true  << ReconcileAction::RequireConflict;
        // With no buffered edit there is no conflict; adopt the newer Hub state.
        QTest::newRow("hub-changed-no-pending-adopt")
            << true  << false << QString("NEW") << QString("OLD") << false << ReconcileAction::AdoptHub;
        QTest::newRow("json-value-changed-conflict")
            << true << true
            << QStringLiteral(R"({"version":1,"appearance":{"theme":"light"}})")
            << QStringLiteral(R"({"version":1,"appearance":{"theme":"dark"}})")
            << false << ReconcileAction::RequireConflict;
        QTest::newRow("json-array-order-changed-conflict")
            << true << true
            << QStringLiteral(R"({"pages":[{"id":"second"},{"id":"first"}]})")
            << QStringLiteral(R"({"pages":[{"id":"first"},{"id":"second"}]})")
            << false << ReconcileAction::RequireConflict;

        // ── Reconnect reconcile: hub UNCHANGED → (re)push our buffered edit ──
        QTest::newRow("hub-same-keep")
            << true  << true  << QString("SAME") << QString("SAME") << false << ReconcileAction::KeepAndPushEdit;
        // KeepAndPushEdit wins over the suppression window (hubChanged=false, pending).
        QTest::newRow("hub-same-keep-suppressed")
            << true  << true  << QString("SAME") << QString("SAME") << true  << ReconcileAction::KeepAndPushEdit;
        // Empty pull is treated as "unchanged" → keep the edit, don't drop it.
        QTest::newRow("empty-pull-keep")
            << true  << true  << QString("")     << QString("OLD")  << false << ReconcileAction::KeepAndPushEdit;
        QTest::newRow("json-whitespace-only-keep")
            << true << true
            << QStringLiteral("{\n  \"version\": 1,\n  \"pages\": []\n}\n")
            << QStringLiteral(R"({"version":1,"pages":[]})")
            << false << ReconcileAction::KeepAndPushEdit;
        QTest::newRow("json-object-key-order-only-keep")
            << true << true
            << QStringLiteral(
                   R"({"appearance":{"accent":"#fff","theme":"dark"},"pages":[{"widgets":[],"id":"main"}]})")
            << QStringLiteral(
                   R"({"pages":[{"id":"main","widgets":[]}],"appearance":{"theme":"dark","accent":"#fff"}})")
            << false << ReconcileAction::KeepAndPushEdit;

        // ── Empty baseline (no prior successful pull) + NON-EMPTY pull → adopt the
        //    hub: we cannot prove either side is newer, so require a choice. ──
        QTest::newRow("empty-baseline-nonempty-pull-conflict")
            << true  << true  << QString("DEVICE") << QString("")   << false << ReconcileAction::RequireConflict;

        // ── Reconnect but nothing buffered → falls through to adopt/suppress ──
        QTest::newRow("awaiting-no-pending-adopt")
            << true  << false << QString("SAME") << QString("SAME") << false << ReconcileAction::AdoptHub;
        QTest::newRow("awaiting-no-pending-suppressed")
            << true  << false << QString("SAME") << QString("SAME") << true  << ReconcileAction::Ignore;
    }
    void table() {
        QFETCH(bool, awaitingHub);
        QFETCH(bool, havePendingPush);
        QFETCH(QString, pulled);
        QFETCH(QString, lastHub);
        QFETCH(bool, suppressed);
        QFETCH(ReconcileAction, expect);
        QCOMPARE(reconcileOnPull(awaitingHub, havePendingPush, pulled, lastHub, suppressed), expect);
    }
};

QTEST_GUILESS_MAIN(TstReconcile)
#include "tst_reconcile.moc"

// Single-instance guard semantics (QLockFile-based). See app/src/single_instance.h.
#include <QtTest>

#include "../../app/src/single_instance.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstSingleInstance : public QObject {
    Q_OBJECT
private slots:
    // Grab/QA mode must never block, even when a lock is already held - headless
    // captures run alongside a real instance.
    void grabModeNeverBlocks() {
        auto held = xeneon::acquireSingleInstance(QStringLiteral("unittest-grab"), false);
        QVERIFY(held);   // free → acquired
        auto grab = xeneon::acquireSingleInstance(QStringLiteral("unittest-grab"), true);
        QVERIFY(grab);   // grab mode ignores contention
    }

    // A second live instance is blocked while the first holds the lock; once the
    // first releases (process exit / crash-reclaim), a new one can acquire.
    void secondLiveInstanceBlocked() {
        const QString key = QStringLiteral("unittest-block");
        auto first = xeneon::acquireSingleInstance(key, false);
        QVERIFY(first);                 // acquired
        auto second = xeneon::acquireSingleInstance(key, false, 0);
        QVERIFY(!second);               // blocked while first holds it
        first.reset();                  // release (unlocks on destruction)
        auto third = xeneon::acquireSingleInstance(key, false);
        QVERIFY(third);                 // free again
    }

    // Hub and manager use distinct keys → they never block each other.
    void distinctAppsDoNotBlock() {
        auto hub = xeneon::acquireSingleInstance(QStringLiteral("unittest-hub"), false);
        auto mgr = xeneon::acquireSingleInstance(QStringLiteral("unittest-manager"), false);
        QVERIFY(hub);
        QVERIFY(mgr);
    }
};

QTEST_GUILESS_MAIN(TstSingleInstance)
#include "tst_single_instance.moc"

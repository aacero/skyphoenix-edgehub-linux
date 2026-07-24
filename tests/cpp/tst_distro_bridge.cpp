// DistroBridge - distro identity / package count / install date for QML.
//
// These assert the BINDING: that the bridge probes OFF the GUI thread, publishes
// exactly what the Rust core found, and stays in its "unknown" state rather than
// half-populating when the answer is absent.
//
// Every case roots the probe at a CRAFTED fixture tree (setRoot), so the results
// are pinned values rather than whatever the build box happens to run - the suite
// asserts the same thing on Arch, in a Debian CI container, and in a scratch
// image with no /etc at all. One case deliberately probes the real "/" to prove
// the default path works, and asserts only shape.
#include <QtTest>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QThread>

#include "distro_bridge.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

// Write `text` to <root>/<rel>, creating parent dirs.
static void writeFile(const QString& root, const QString& rel, const QByteArray& text) {
    const QString path = root + "/" + rel;
    QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
    QFile f(path);
    QVERIFY(f.open(QIODevice::WriteOnly));
    QCOMPARE(f.write(text), qint64(text.size()));
}

class TstDistroBridge : public QObject {
    Q_OBJECT

    // Build a pacman root with `n` package dirs + the ALPM_DB_VERSION FILE (which
    // is not a package - the count must exclude it).
    void makeArchRoot(const QString& root, int n, const QByteArray& osRelease,
                      const QByteArray& pacmanLog = QByteArray()) {
        writeFile(root, "etc/os-release", osRelease);
        for (int i = 0; i < n; ++i)
            QVERIFY(QDir().mkpath(QString("%1/var/lib/pacman/local/pkg%2-1.0-1").arg(root).arg(i)));
        writeFile(root, "var/lib/pacman/local/ALPM_DB_VERSION", "9\n");
        if (!pacmanLog.isEmpty()) writeFile(root, "var/log/pacman.log", pacmanLog);
    }

    // Point the bridge at `root` and block until THAT root's probe has landed.
    //
    // Waiting for "any infoChanged" is not enough, and the difference is not
    // theoretical: the constructor kicks off a probe of the REAL system, and on
    // the dev box (CachyOS) that answer has the same `id`/`family` as the arch
    // fixtures below - so a test that resumed on the first signal asserted
    // against the real machine's 1461 packages and only failed on the count.
    // Gate on probedRoot() instead, which names the root that produced the data.
    static bool probeAt(DistroBridge& b, const QString& root) {
        b.setRoot(root);
        return QTest::qWaitFor([&] { return b.ready() && b.probedRoot() == root; }, 5000);
    }

private slots:

    // The core promise: a real count off a real (fixture) database.
    void publishesTheProbeForAnArchRoot() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        makeArchRoot(d.path(), 7, "ID=arch\nNAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\n",
                     "[2024-03-01T00:00:00+0000] [ALPM] installed base (3-1)\n");

        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_VERIFY(b.ready());
        QTRY_COMPARE(b.info().value("packageCount").toInt(), 7);
        QCOMPARE(b.info().value("family").toString(), QStringLiteral("arch"));
        QCOMPARE(b.info().value("id").toString(), QStringLiteral("arch"));
        QCOMPARE(b.info().value("name").toString(), QStringLiteral("Arch Linux"));
        QVERIFY(!b.refreshing());
        QVERIFY(b.refreshedAtMs() > 0);
        // 2024-03-01T00:00:00Z
        QCOMPARE(b.info().value("installEpoch").toLongLong(), 1709251200LL);
        QCOMPARE(b.info().value("installSource").toString(), QStringLiteral("package-log-estimate"));
        QCOMPARE(b.info().value("installEvidence").toString(), QStringLiteral("/var/log/pacman.log"));
        QVERIFY(b.info().value("installEvidenceNote").toString().contains("visible pacman history"));
        QVERIFY(b.info().value("installReason").isNull());
    }

    // ID_LIKE=arch must reach the pacman reader. This is the dev box's own file.
    void resolvesADerivativeThroughIdLike() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        makeArchRoot(d.path(), 3,
                     "NAME=\"CachyOS Linux\"\nPRETTY_NAME=\"CachyOS\"\nID=cachyos\nID_LIKE=arch\n");
        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_COMPARE(b.info().value("id").toString(), QStringLiteral("cachyos"));
        QCOMPARE(b.info().value("family").toString(), QStringLiteral("arch"));
        QCOMPARE(b.info().value("name").toString(), QStringLiteral("CachyOS"));
        QCOMPARE(b.info().value("packageCount").toInt(), 3);
    }

    void countsDpkgStanzasForADebianRoot() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        writeFile(d.path(), "etc/os-release", "ID=ubuntu\nID_LIKE=debian\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n");
        // Only `install ok installed` counts: a removed-but-configured package is
        // still in this file and must not be counted.
        writeFile(d.path(), "var/lib/dpkg/status",
                  "Package: bash\nStatus: install ok installed\n\n"
                  "Package: coreutils\nStatus: install ok installed\n\n"
                  "Package: nano\nStatus: deinstall ok config-files\n\n");
        writeFile(d.path(), "var/log/dpkg.log", "2022-02-03 08:30:00 startup archives unpack\n");

        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_COMPARE(b.info().value("family").toString(), QStringLiteral("debian"));
        QCOMPARE(b.info().value("packageCount").toInt(), 2);
        QCOMPARE(b.info().value("name").toString(), QStringLiteral("Ubuntu 24.04 LTS"));
    }

    // The documented non-support, asserted so it cannot silently become a
    // subprocess: an RPM root must report a REASON, not a count and not a zero.
    void rpmIsExplicitlyUnsupportedWithAReason() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        writeFile(d.path(), "etc/os-release",
                  "ID=fedora\nPRETTY_NAME=\"Fedora Linux 40 (Workstation Edition)\"\n");
        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_COMPARE(b.info().value("family").toString(), QStringLiteral("rpm"));
        // null over the FFI -> an invalid QVariant, NOT 0.
        QVERIFY(!b.info().value("packageCount").isValid()
                || b.info().value("packageCount").isNull());
        QVERIFY(b.info().value("unsupportedReason").toString().contains("librpm"));
    }

    // An unknown distro degrades; it does not crash and does not guess.
    void unknownRootDegradesToUnknown() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_COMPARE(b.info().value("family").toString(), QStringLiteral("unknown"));
        QVERIFY(b.info().value("packageCount").isNull());
        QVERIFY(b.info().value("installEpoch").isNull());
        QVERIFY(!b.info().value("unsupportedReason").toString().isEmpty());
        QVERIFY(!b.info().value("installReason").toString().isEmpty());
    }

    // "Updates available" is never claimed - see core/src/distro.rs. If someone
    // ever wires up a stale-cache guess, this fails.
    void updatesAreNeverClaimed() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        makeArchRoot(d.path(), 2, "ID=arch\n");
        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_VERIFY(b.ready());
        QVERIFY(b.info().value("updates").isNull());
        QVERIFY(b.info().value("securityUpdates").isNull());
        QVERIFY(!b.info().value("updatesReason").toString().isEmpty());
    }

    // Before the first probe lands there is no data - and an empty map must not
    // be mistakable for "0 packages". QML keys its placeholder off `ready`.
    void isNotReadyBeforeTheFirstProbeLands() {
        DistroBridge b;
        // Read IMMEDIATELY, before the worker thread can answer: the ctor kicks
        // the probe off asynchronously, so this is still the pristine state.
        QCOMPARE(b.ready(), false);
        QVERIFY(b.info().isEmpty());
        // ...and it becomes ready on its own, with no refresh() call: the
        // constructor must kick off the initial probe.
        QTRY_VERIFY_WITH_TIMEOUT(b.ready(), 5000);
    }

    // THE threading claim, asserted directly: the probe must execute on a thread
    // that is NOT the caller's. In production the caller is the GUI thread, and a
    // 10 MB dpkg-status parse there is several dropped frames.
    void probeRunsOnTheWorkerThreadNotTheCallers() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        makeArchRoot(d.path(), 2, "ID=arch\n");

        QThread t;
        DistroProbeWorker w;
        w.moveToThread(&t);
        t.start();

        // Capture the thread the probe body actually ran on. done() is emitted
        // from inside probe(), so the emitting thread IS the executing thread.
        QThread* ran = nullptr;
        connect(&w, &DistroProbeWorker::done, &w,
                [&] { ran = QThread::currentThread(); }, Qt::DirectConnection);

        QSignalSpy spy(&w, &DistroProbeWorker::done);
        QMetaObject::invokeMethod(&w, "probe", Qt::QueuedConnection, Q_ARG(QString, d.path()));
        QVERIFY(spy.wait(5000));

        QVERIFY(ran != nullptr);
        QVERIFY2(ran != QThread::currentThread(), "probe ran on the calling thread");
        QCOMPARE(ran, &t);

        t.quit();
        QVERIFY(t.wait(5000));
    }

    // A probe still in flight must not overwrite a newer one. Probes are queued,
    // so without the root check in _onProbed the FIRST root's answer lands second
    // and wins - which is exactly what the dev box reproduced, invisibly, because
    // the real system and the arch fixture share an `id`.
    void aStaleInFlightProbeCannotOverwriteANewerOne() {
        QTemporaryDir oldRoot, newRoot;
        QVERIFY(oldRoot.isValid() && newRoot.isValid());
        makeArchRoot(oldRoot.path(), 11, "ID=arch\n");
        makeArchRoot(newRoot.path(), 22, "ID=arch\n");

        DistroBridge b;
        // Queue both back-to-back: the first probe is in flight (or queued) when
        // the second is requested.
        b.setRoot(oldRoot.path());
        b.setRoot(newRoot.path());

        QVERIFY(QTest::qWaitFor([&] { return b.ready() && b.probedRoot() == newRoot.path(); }, 5000));
        QCOMPARE(b.info().value("packageCount").toInt(), 22);

        // Give the dropped answer every chance to land late and clobber this.
        QTest::qWait(200);
        QCOMPARE(b.info().value("packageCount").toInt(), 22);
        QCOMPARE(b.probedRoot(), newRoot.path());
    }

    // refresh() must pick up a change on disk rather than serve a frozen cache.
    void refreshRecountsAfterTheDatabaseChanges() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        makeArchRoot(d.path(), 4, "ID=arch\n");

        DistroBridge b;
        QVERIFY(probeAt(b, d.path()));
        QTRY_COMPARE(b.info().value("packageCount").toInt(), 4);

        // Simulate `pacman -S something`.
        QVERIFY(QDir().mkpath(d.path() + "/var/lib/pacman/local/newpkg-1.0-1"));
        b.refresh();
        QTRY_COMPARE(b.info().value("packageCount").toInt(), 5);
    }

    // The default root is the real system. Shape only - this must pass on any
    // distro (and in a container with no package manager at all).
    void defaultRootProbesTheRealSystem() {
        DistroBridge b;
        QTRY_VERIFY_WITH_TIMEOUT(b.ready(), 5000);
        const QString family = b.info().value("family").toString();
        QVERIFY2(family == "arch" || family == "debian" || family == "rpm" || family == "unknown",
                 qPrintable("unexpected family: " + family));
        QVERIFY(!b.info().value("name").toString().isEmpty());
        // A supported family that produced a count must produce a plausible one.
        const QVariant count = b.info().value("packageCount");
        if ((family == "arch" || family == "debian") && !count.isNull())
            QVERIFY2(count.toLongLong() > 10, "implausible package count");
    }

    // Construct/destroy repeatedly: the worker thread must be torn down cleanly
    // every time (this is what catches a missing quit()/wait() in ~DistroBridge).
    void constructsAndDestroysCleanly() {
        for (int i = 0; i < 3; ++i) {
            DistroBridge b;
            QTRY_VERIFY_WITH_TIMEOUT(b.ready(), 5000);
        }
    }
};

QTEST_MAIN(TstDistroBridge)
#include "tst_distro_bridge.moc"

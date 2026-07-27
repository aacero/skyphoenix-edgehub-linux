// Headless negative tests for OrientationSensor's read/EOF/retry path using a
// crafted FIFO (no hardware). Drives the reader through: valid report → rotation
// emitted; writer closes → EOF → stop-watching + retry-timer armed. GUILESS (needs
// an event dispatcher for QSocketNotifier/QTimer, no GUI).
#include <QtTest>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QFile>

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include "orientation_sensor.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstOrientationReopen : public QObject {
    Q_OBJECT
private slots:
    // A missing node cannot be opened → false, inactive, no retry armed by openForTest.
    void openMissingPathFails() {
        OrientationSensor s;
        QVERIFY(!s.openForTest("/dev/xeneon-nonexistent-hidraw"));
        QVERIFY(!s.active());
    }

    // Full lifecycle over a FIFO: read a valid orientation report, then EOF on the
    // writer closing → the sensor stops watching and arms the reopen retry timer.
    void reportThenEofArmsRetry() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString fifo = dir.path() + "/edge_fifo";
        QCOMPARE(::mkfifo(fifo.toUtf8().constData(), 0600), 0);

        // Open a keep-alive writer end FIRST (O_RDWR avoids ENXIO with no reader and
        // keeps a writer present, so the sensor's initial drain sees EAGAIN - not the
        // immediate EOF a writer-less FIFO read returns).
        int wfd = ::open(fifo.toUtf8().constData(), O_RDWR | O_NONBLOCK);
        QVERIFY(wfd >= 0);

        OrientationSensor s;
        QVERIFY(s.openForTest(fifo));   // reader; a writer exists → stays active
        QVERIFY(s.active());
        QVERIFY(!s.retryActiveForTest());

        // A valid orientation notification: report id 0x01, header 0x11, byte[7]=0x03
        // (upright portrait → content rotation 0).
        QSignalSpy spy(&s, &OrientationSensor::rotationChanged);
        unsigned char report[64] = {0};
        report[0] = 0x01; report[1] = 0x11; report[7] = 0x03;
        QCOMPARE(::write(wfd, report, sizeof(report)), ssize_t(sizeof(report)));

        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 3000);
        QCOMPARE(spy.at(0).at(0).toInt(), 0);
        QCOMPARE(s.rotation(), 0);
        QVERIFY(s.active());

        // Writer closes → reader hits EOF → device-lost handling: stop watching + arm
        // the reopen retry timer (so auto-rotate recovers if the panel returns).
        ::close(wfd);
        QTRY_VERIFY_WITH_TIMEOUT(!s.active(), 3000);
        QVERIFY(s.retryActiveForTest());
    }

    // Malformed reports are skipped without emitting: a runt report (< 8 bytes) and a
    // full-length report with the wrong header both leave the rotation untouched; only
    // the following VALID report emits. Exercises the two in-loop "continue" guards.
    void malformedReportsAreSkipped() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString fifo = dir.path() + "/edge_fifo";
        QCOMPARE(::mkfifo(fifo.toUtf8().constData(), 0600), 0);
        int wfd = ::open(fifo.toUtf8().constData(), O_RDWR | O_NONBLOCK);
        QVERIFY(wfd >= 0);

        OrientationSensor s;
        QVERIFY(s.openForTest(fifo));
        QVERIFY(s.active());
        QSignalSpy spy(&s, &OrientationSensor::rotationChanged);

        // (a) Runt report: fewer than 8 bytes → skipped (n < 8 continue). Drain it in
        //     isolation (FIFO is a byte stream, so we must not let it coalesce with the
        //     next write, which would misalign the 64-byte report framing).
        unsigned char runt[4] = {0x01, 0x11, 0x00, 0x02};
        QCOMPARE(::write(wfd, runt, sizeof(runt)), ssize_t(sizeof(runt)));
        QTest::qWait(50);
        QCOMPARE(spy.count(), 0);

        // (b) Wrong header: full length but header byte != 0x11 → skipped.
        unsigned char badHdr[64] = {0};
        badHdr[0] = 0x01; badHdr[1] = 0x22; badHdr[7] = 0x02;   // 0x02 → 90° if honored
        QCOMPARE(::write(wfd, badHdr, sizeof(badHdr)), ssize_t(sizeof(badHdr)));
        QTest::qWait(50);
        QCOMPARE(spy.count(), 0);
        QCOMPARE(s.rotation(), -1);   // still the initial "unknown" value

        // (c) A valid report now DOES emit (proves the reader kept running past the
        // malformed ones rather than stalling).
        unsigned char good[64] = {0};
        good[0] = 0x01; good[1] = 0x11; good[7] = 0x03;   // upright portrait → 0°
        QCOMPARE(::write(wfd, good, sizeof(good)), ssize_t(sizeof(good)));
        QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 3000);
        QCOMPARE(s.rotation(), 0);

        ::close(wfd);
    }

    // Persistence: a live rotation is written to the state file, and a fresh sensor
    // that gets NO startup report restores it (the fix for panels that answer no
    // GET_REPORT and only push on physical change - a restart would otherwise start
    // mis-rotated).
    void persistsAndRestoresOrientation() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString state = dir.path() + "/orientation.state";
        const QString fifo = dir.path() + "/edge_fifo";
        QCOMPARE(::mkfifo(fifo.toUtf8().constData(), 0600), 0);
        int wfd = ::open(fifo.toUtf8().constData(), O_RDWR | O_NONBLOCK);
        QVERIFY(wfd >= 0);

        // (a) A pushed report is persisted.
        {
            OrientationSensor s;
            s.setStatePath(state);
            QVERIFY(s.openForTest(fifo));
            QSignalSpy spy(&s, &OrientationSensor::rotationChanged);
            unsigned char report[64] = {0};
            report[0] = 0x01; report[1] = 0x11; report[7] = 0x02;   // 0x02 → 90°
            QCOMPARE(::write(wfd, report, sizeof(report)), ssize_t(sizeof(report)));
            QTRY_VERIFY_WITH_TIMEOUT(spy.count() >= 1, 3000);
            QCOMPARE(s.rotation(), 90);
            QFile f(state);
            QVERIFY(f.open(QIODevice::ReadOnly));
            QCOMPARE(f.readAll().trimmed().toInt(), 90);
        }
        // (b) A fresh sensor with no startup report restores the persisted 90°.
        {
            OrientationSensor s2;
            s2.setStatePath(state);
            QVERIFY(s2.openForTest(fifo));   // writer present → active, nothing pushed
            QCOMPARE(s2.rotation(), 90);     // restored synchronously at open time
        }
        ::close(wfd);
    }

    // A persisted fallback is presentation state, not proof of the panel's
    // current orientation. It must not cancel the bounded startup acquisition.
    void persistedFallbackDoesNotSuppressStartupRetries() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString state = dir.path() + "/orientation.state";
        const QString fifo = dir.path() + "/edge_fifo";
        {
            QFile f(state);
            QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
            QCOMPARE(f.write("90"), qint64(2));
        }
        QCOMPARE(::mkfifo(fifo.toUtf8().constData(), 0600), 0);
        const int wfd = ::open(fifo.toUtf8().constData(), O_RDWR | O_NONBLOCK);
        QVERIFY(wfd >= 0);

        OrientationSensor s;
        s.setStatePath(state);
        s.setStartupRetryScheduleForTest({5, 10, 15});
        QVERIFY(s.openForTest(fifo));
        QCOMPARE(s.rotation(), 90);
        QVERIFY(!s.hasDeviceReadingForTest());
        QVERIFY(s.startupRetryActiveForTest());

        // One immediate attempt plus all three scheduled attempts. ioctl on the
        // FIFO always fails, so exhaustion is deterministic and fast.
        QTest::ignoreMessage(
            QtInfoMsg,
            QRegularExpression(
                "OrientationSensor: startup GET_REPORT unavailable after .* "
                "using remembered rotation 90 deg and following pushed reports"));
        QTRY_COMPARE_WITH_TIMEOUT(s.startupAttemptCountForTest(), 4, 1000);
        QTRY_VERIFY_WITH_TIMEOUT(!s.startupRetryActiveForTest(), 1000);
        QCOMPARE(s.rotation(), 90);
        QVERIFY(!s.hasDeviceReadingForTest());
        ::close(wfd);
    }

    // Exhaustion without either a device report or persisted state is genuinely
    // degraded: the shell can only infer landscape from the display aspect. Keep
    // that case at warning severity so the production warning gate remains useful.
    void missingDeviceAndFallbackRemainsWarning() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString fifo = dir.path() + "/edge_fifo";
        QCOMPARE(::mkfifo(fifo.toUtf8().constData(), 0600), 0);
        const int wfd = ::open(fifo.toUtf8().constData(), O_RDWR | O_NONBLOCK);
        QVERIFY(wfd >= 0);

        OrientationSensor s;
        s.setStatePath(dir.path() + "/missing-orientation.state");
        s.setStartupRetryScheduleForTest({5, 10});
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(
                "OrientationSensor: no startup HID orientation or remembered rotation after .* "
                "using the display-aspect fallback until a pushed report arrives"));
        QVERIFY(s.openForTest(fifo));
        QTRY_COMPARE_WITH_TIMEOUT(s.startupAttemptCountForTest(), 3, 1000);
        QTRY_VERIFY_WITH_TIMEOUT(!s.startupRetryActiveForTest(), 1000);
        QCOMPARE(s.rotation(), -1);
        QVERIFY(!s.hasDeviceReadingForTest());
        ::close(wfd);
    }

    // A real pushed report is authoritative and cancels remaining startup retries.
    void pushedReportStopsStartupRetries() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString fifo = dir.path() + "/edge_fifo";
        QCOMPARE(::mkfifo(fifo.toUtf8().constData(), 0600), 0);
        const int wfd = ::open(fifo.toUtf8().constData(), O_RDWR | O_NONBLOCK);
        QVERIFY(wfd >= 0);

        OrientationSensor s;
        s.setStartupRetryScheduleForTest({500, 500});
        QVERIFY(s.openForTest(fifo));
        QCOMPARE(s.startupAttemptCountForTest(), 1);
        QVERIFY(s.startupRetryActiveForTest());

        unsigned char report[64] = {0};
        report[0] = 0x01;
        report[1] = 0x11;
        report[7] = 0x00;
        QCOMPARE(::write(wfd, report, sizeof(report)), ssize_t(sizeof(report)));

        QTRY_VERIFY_WITH_TIMEOUT(s.hasDeviceReadingForTest(), 1000);
        QCOMPARE(s.rotation(), 270);
        QVERIFY(!s.startupRetryActiveForTest());
        QTest::qWait(550);
        QCOMPARE(s.startupAttemptCountForTest(), 1);
        ::close(wfd);
    }
};

QTEST_GUILESS_MAIN(TstOrientationReopen)
#include "tst_orientation_reopen.moc"

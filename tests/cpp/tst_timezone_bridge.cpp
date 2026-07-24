// TimeZoneBridge - real IANA zones for QML, backed by the OS tzdata.
//
// These assert the BINDING (that we hand QTimeZone the right instant and hand QML
// back the right string), not tzdata itself - Qt's zone data is not ours to test.
// But the DST transitions below are pinned to real UTC instants, so if the wiring
// ever silently reverts to host-local time (the exact failure mode of the QML
// approaches this replaced) they fail loudly.
//
// Every instant is an explicit UTC epoch. Nothing here reads "now", so the result
// cannot depend on the day the suite runs. GUILESS.
#include <QtTest>
#include <QDateTime>
#include <QTimeZone>

#include "timezone_bridge.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

// 2026 transitions, as UTC instants.
//   US: DST 2nd Sun Mar 02:00 local -> 1st Sun Nov 02:00 local
//       2026-03-08 07:00Z (EST->EDT), 2026-11-01 06:00Z (EDT->EST)
//   EU: last Sun Mar 01:00Z -> last Sun Oct 01:00Z
//       2026-03-29 01:00Z (CET->CEST), 2026-10-25 01:00Z (CEST->CET)
static qint64 utcMs(int y, int mo, int d, int h, int mi = 0) {
    return QDateTime(QDate(y, mo, d), QTime(h, mi), QTimeZone::UTC).toMSecsSinceEpoch();
}

class TstTimeZoneBridge : public QObject {
    Q_OBJECT
    TimeZoneBridge tz;

private slots:
    void initTestCase() {
        // If the box has no tzdata these tests are meaningless rather than failing.
        if (!QTimeZone("America/New_York").isValid())
            QSKIP("no IANA tzdata on this system");
    }

    void validIds() {
        QVERIFY(tz.isValid("America/New_York"));
        QVERIFY(tz.isValid("Europe/Berlin"));
        QVERIFY(tz.isValid("Asia/Tokyo"));
        QVERIFY(tz.isValid("UTC"));
        QVERIFY(!tz.isValid("Not/AZone"));
        QVERIFY(!tz.isValid(""));
        // A zoneId from a newer build must be reported invalid, not silently
        // resolved to something else - QML relies on this to fall back.
        QVERIFY(!tz.isValid("Mars/Olympus_Mons"));
    }

    // The whole point: the offset must FOLLOW DST, not be a fixed number.
    void offsetFollowsDstAcrossTheYear_data() {
        QTest::addColumn<QString>("zone");
        QTest::addColumn<qint64>("instant");
        QTest::addColumn<int>("expectSecs");

        // America/New_York: -5h standard, -4h daylight
        QTest::newRow("NY winter")  << "America/New_York" << utcMs(2026, 1, 15, 12) << -5 * 3600;
        QTest::newRow("NY summer")  << "America/New_York" << utcMs(2026, 7, 15, 12) << -4 * 3600;
        // Europe/Berlin: +1h standard, +2h daylight
        QTest::newRow("BER winter") << "Europe/Berlin"    << utcMs(2026, 1, 15, 12) << 1 * 3600;
        QTest::newRow("BER summer") << "Europe/Berlin"    << utcMs(2026, 7, 15, 12) << 2 * 3600;
        // Asia/Tokyo observes no DST - same all year.
        QTest::newRow("TYO winter") << "Asia/Tokyo"       << utcMs(2026, 1, 15, 12) << 9 * 3600;
        QTest::newRow("TYO summer") << "Asia/Tokyo"       << utcMs(2026, 7, 15, 12) << 9 * 3600;
        // Southern hemisphere: DST straddles New Year, so the seasons invert.
        QTest::newRow("SYD january") << "Australia/Sydney" << utcMs(2026, 1, 15, 12) << 11 * 3600;
        QTest::newRow("SYD july")    << "Australia/Sydney" << utcMs(2026, 7, 15, 12) << 10 * 3600;
        // A half-hour zone - a whole-hours assumption would break here.
        QTest::newRow("Kolkata")     << "Asia/Kolkata"     << utcMs(2026, 7, 15, 12)
                                     << 5 * 3600 + 1800;
    }
    void offsetFollowsDstAcrossTheYear() {
        QFETCH(QString, zone);
        QFETCH(qint64, instant);
        QFETCH(int, expectSecs);
        QCOMPARE(tz.offsetSecsAt(zone, double(instant)), expectSecs);
    }

    // Pinned to the second: one ms before the switch is still standard time.
    void transitionIsExactToTheSecond() {
        const QString ny = "America/New_York";
        const qint64 spring = utcMs(2026, 3, 8, 7);      // 02:00 EST -> 03:00 EDT
        QCOMPARE(tz.offsetSecsAt(ny, double(spring - 1)), -5 * 3600);
        QCOMPARE(tz.offsetSecsAt(ny, double(spring)),     -4 * 3600);

        const qint64 fall = utcMs(2026, 11, 1, 6);       // 02:00 EDT -> 01:00 EST
        QCOMPARE(tz.offsetSecsAt(ny, double(fall - 1)), -4 * 3600);
        QCOMPARE(tz.offsetSecsAt(ny, double(fall)),     -5 * 3600);

        const QString ber = "Europe/Berlin";
        const qint64 euSpring = utcMs(2026, 3, 29, 1);
        QCOMPARE(tz.offsetSecsAt(ber, double(euSpring - 1)), 1 * 3600);
        QCOMPARE(tz.offsetSecsAt(ber, double(euSpring)),     2 * 3600);
    }

    // format() must render the TARGET zone's wall clock regardless of the host's.
    void formatRendersTheTargetZoneWallClock() {
        // 2026-07-15 12:00Z -> New York is UTC-4 in July -> 08:00
        QCOMPARE(tz.format("America/New_York", double(utcMs(2026, 7, 15, 12)), "HH:mm"),
                 QStringLiteral("08:00"));
        // Same instant in Tokyo (UTC+9, no DST) -> 21:00
        QCOMPARE(tz.format("Asia/Tokyo", double(utcMs(2026, 7, 15, 12)), "HH:mm"),
                 QStringLiteral("21:00"));
        // Winter: New York is UTC-5 -> 07:00
        QCOMPARE(tz.format("America/New_York", double(utcMs(2026, 1, 15, 12)), "HH:mm"),
                 QStringLiteral("07:00"));
    }

    void formatLocaleUsesTheRequestedLocale() {
        const qint64 instant = utcMs(2026, 7, 15, 12);
        const QDateTime tokyo = QDateTime::fromMSecsSinceEpoch(
                instant, QTimeZone("Asia/Tokyo"));
        QCOMPARE(tz.formatLocale("Asia/Tokyo", double(instant), "dddd MMMM", "de_DE"),
                 QLocale("de_DE").toString(tokyo, "dddd MMMM"));
        QCOMPARE(tz.formatLocale("Asia/Tokyo", double(instant), "dddd MMMM", "en_GB"),
                 QLocale("en_GB").toString(tokyo, "dddd MMMM"));
    }

    // The bug this design exists to kill: the old QML trick shifted a Date and
    // formatted it LOCALLY, so an instant whose target wall clock lands in the
    // HOST's spring-forward gap could not be represented (a Berlin host showed
    // Tokyo an hour out). QDateTime carries the zone, so the host is irrelevant.
    void resultDoesNotDependOnTheHostZone() {
        const qint64 inst = utcMs(2026, 3, 29, 1, 30);   // inside Berlin's DST gap
        const QByteArray saved = qgetenv("TZ");
        const QStringList hosts = { "UTC", "Europe/Berlin", "America/New_York",
                                    "Pacific/Auckland", "Asia/Kolkata" };
        QString expected;
        for (const QString& host : hosts) {
            qputenv("TZ", host.toUtf8());
            const QString got = tz.format("Asia/Tokyo", double(inst), "HH:mm");
            if (expected.isEmpty()) expected = got;
            QCOMPARE(got, expected);   // identical on every host
        }
        if (saved.isEmpty()) qunsetenv("TZ"); else qputenv("TZ", saved);
        QCOMPARE(expected, QStringLiteral("10:30"));   // 01:30Z + 9h
    }

    // An unknown zone must yield an empty string, never a plausible-looking time:
    // QML treats "" as "fall back", and a wrong time would be worse than none.
    void unknownZoneFormatsToEmptyNotToAGuess() {
        QVERIFY(tz.format("Not/AZone", double(utcMs(2026, 7, 15, 12)), "HH:mm").isEmpty());
        QVERIFY(tz.format("", double(utcMs(2026, 7, 15, 12)), "HH:mm").isEmpty());
        QCOMPARE(tz.offsetSecsAt("Not/AZone", double(utcMs(2026, 7, 15, 12))), 0);
    }

    void daylightFlagAndAbbreviation() {
        QVERIFY(!tz.isDaylightTime("America/New_York", double(utcMs(2026, 1, 15, 12))));
        QVERIFY(tz.isDaylightTime("America/New_York", double(utcMs(2026, 7, 15, 12))));
        QVERIFY(!tz.isDaylightTime("Asia/Tokyo", double(utcMs(2026, 7, 15, 12))));
        QVERIFY(!tz.isDaylightTime("Not/AZone", double(utcMs(2026, 7, 15, 12))));
        // Abbreviations are locale/tzdata dependent, so assert only that the two
        // sides of the year DIFFER for a DST zone and match for a non-DST one.
        const QString w = tz.abbreviationAt("America/New_York", double(utcMs(2026, 1, 15, 12)));
        const QString s = tz.abbreviationAt("America/New_York", double(utcMs(2026, 7, 15, 12)));
        QVERIFY(!w.isEmpty());
        QVERIFY(w != s);
        QCOMPARE(tz.abbreviationAt("Asia/Tokyo", double(utcMs(2026, 1, 15, 12))),
                 tz.abbreviationAt("Asia/Tokyo", double(utcMs(2026, 7, 15, 12))));
    }

    // ~600 zones, versus the 20 a hand-written table carried.
    void idsCoverTheRealTzdataSet() {
        const QStringList ids = tz.ids();
        QVERIFY2(ids.size() > 300, qPrintable(QString("only %1 zones").arg(ids.size())));
        QVERIFY(ids.contains("America/New_York"));
        QVERIFY(ids.contains("Europe/Berlin"));
        QVERIFY(ids.contains("Asia/Tokyo"));
        // Sorted, so a picker is stable.
        QStringList sorted = ids;
        sorted.sort();
        QCOMPARE(ids, sorted);
    }
};

QTEST_MAIN(TstTimeZoneBridge)
#include "tst_timezone_bridge.moc"

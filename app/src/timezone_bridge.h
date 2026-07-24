#pragma once

#include <QDateTime>
#include <QLocale>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimeZone>

// ─────────────────────────────────────────────────────────────────────────────
// TimeZoneBridge - real IANA time zones for QML.
//
// QML cannot do this on its own, and the ways it appears to are traps:
//   • `Intl` DOES NOT EXIST in Qt's V4 engine (verified on 6.11, which is ahead of
//     CI's 6.7 - so it is absent everywhere we run).
//   • `Date.toLocaleString(locale, { timeZone })` SILENTLY IGNORES the option and
//     returns host-local time. No error, just a wrong clock.
//
// The alternative - encoding DST laws in QML - was tried and rejected: it covers
// only the zones someone hand-listed, and it goes silently wrong the moment a
// country changes its rules (the EU has repeatedly debated abolishing DST; Brazil
// dropped it in 2019; Mexico changed in 2022). QTimeZone is backed by the OS tzdata,
// so it covers every zone and stays correct through a `tzdata` package update with
// no code change here.
//
// Formatting happens HERE, not in QML, and that is the point. The QML-side trick of
// "shift a Date by the offset, then format it locally" is wrong at instants whose
// target wall clock lands in the HOST's spring-forward gap - an hour that does not
// exist locally, so no local Date can represent it. QDateTime carries the zone
// itself, so the gap never arises.
// ─────────────────────────────────────────────────────────────────────────────
class TimeZoneBridge : public QObject {
    Q_OBJECT
public:
    explicit TimeZoneBridge(QObject* parent = nullptr) : QObject(parent) {}

    // Is this a zone the OS tzdata knows? QML uses this to fall back rather than
    // render a wrong time for a zone id from a newer build.
    Q_INVOKABLE bool isValid(const QString& zoneId) const { return _zone(zoneId).isValid(); }

    // Format the given instant AS SEEN IN `zoneId`, using Qt's date/time format
    // spec (the same one Qt.formatTime/formatDate take, e.g. "HH:mm:ss",
    // "dddd, MMMM d yyyy"). Empty string if the zone is unknown - callers must
    // treat that as "fall back", never as a time.
    //
    // msEpoch is a double because QML numbers are doubles; it is milliseconds since
    // the Unix epoch (i.e. Date.now() / date.getTime()).
    Q_INVOKABLE QString format(const QString& zoneId, double msEpoch, const QString& fmt) const {
        const QTimeZone tz = _zone(zoneId);
        if (!tz.isValid()) return QString();
        // QLocale().toString(), NOT QDateTime::toString(): the latter renders day and
        // month names in the C locale, so a German user's "Montag" would silently
        // become "Monday" the moment their clock gained a zone. QML's
        // Qt.formatDate/formatTime use the default locale, and this must match them -
        // the same tile formats through both paths depending on customZone.
        return QLocale().toString(QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(msEpoch), tz), fmt);
    }

    // Locale-aware companion used by clocks with an explicit language/region.
    // An empty locale name deliberately preserves the process locale.
    Q_INVOKABLE QString formatLocale(const QString& zoneId, double msEpoch, const QString& fmt,
                                     const QString& localeName) const {
        const QTimeZone tz = _zone(zoneId);
        if (!tz.isValid()) return QString();
        const QLocale locale = localeName.trimmed().isEmpty() ? QLocale() : QLocale(localeName);
        return locale.toString(QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(msEpoch), tz), fmt);
    }

    // Offset from UTC in SECONDS at the given instant, DST included. Callers that
    // need arithmetic (a countdown, a day boundary) use this rather than parsing a
    // formatted string. Returns 0 for an unknown zone - pair it with isValid().
    Q_INVOKABLE int offsetSecsAt(const QString& zoneId, double msEpoch) const {
        const QTimeZone tz = _zone(zoneId);
        if (!tz.isValid()) return 0;
        return tz.offsetFromUtc(QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(msEpoch), tz));
    }

    // True when the zone is in DST at that instant (for a "summer time" hint).
    Q_INVOKABLE bool isDaylightTime(const QString& zoneId, double msEpoch) const {
        const QTimeZone tz = _zone(zoneId);
        if (!tz.isValid()) return false;
        return tz.isDaylightTime(QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(msEpoch), tz));
    }

    // The zone's short abbreviation at that instant ("EST"/"EDT", "CET"/"CEST").
    Q_INVOKABLE QString abbreviationAt(const QString& zoneId, double msEpoch) const {
        const QTimeZone tz = _zone(zoneId);
        if (!tz.isValid()) return QString();
        return tz.abbreviation(QDateTime::fromMSecsSinceEpoch(static_cast<qint64>(msEpoch), tz));
    }

    // ONE guarded resolver behind every entry point. An empty id must be invalid
    // here: QTimeZone(QByteArray()) does NOT reject it, so format("") returned a real
    // time while isValid("") returned false - and QML keys its fallback off exactly
    // that pair. Guarding in each method separately is how they drifted apart.
    QTimeZone _zone(const QString& zoneId) const {
        if (zoneId.isEmpty()) return QTimeZone();
        return QTimeZone(zoneId.toUtf8());
    }

    // Every IANA id the OS knows (~600), for a zone picker. Sorted for a stable UI.
    Q_INVOKABLE QStringList ids() const {
        QStringList out;
        const auto avail = QTimeZone::availableTimeZoneIds();
        out.reserve(avail.size());
        for (const QByteArray& id : avail) out << QString::fromUtf8(id);
        out.sort();
        return out;
    }
};

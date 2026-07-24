#include "mpris_state.h"

#include <QFileInfo>
#include <QUrl>
#include <QtDBus/QDBusArgument>   // qdbus_cast

namespace {
const QString kPrefix = QStringLiteral("org.mpris.MediaPlayer2.");
}

namespace mpris {

bool isMprisService(const QString& busName) { return busName.startsWith(kPrefix); }

QString playerNameFromService(const QString& service) { return service.mid(kPrefix.length()); }

QString choosePlayer(const QStringList& order, const QMap<QString, QString>& statuses,
                     const QString& current, const QString& preferred) {
    if (order.isEmpty())
        return QString();
    const QString wanted = preferred.trimmed();
    if (!wanted.isEmpty()) {
        for (const QString& candidate : order) {
            if (candidate.compare(wanted, Qt::CaseInsensitive) == 0 ||
                playerNameFromService(candidate).compare(wanted, Qt::CaseInsensitive) == 0)
                return candidate;
        }
    }
    QString chosen;
    for (const QString& cand : order)
        if (statuses.value(cand) == QStringLiteral("Playing")) { chosen = cand; break; }
    if (chosen.isEmpty())
        chosen = order.contains(current) ? current : order.first();
    return chosen;
}

TrackState resolveTrack(const QVariantMap& props, const QString& service) {
    TrackState s;
    s.status = props.value(QStringLiteral("PlaybackStatus")).toString();
    s.canPlayPause = props.value(QStringLiteral("CanControl"), true).toBool() &&
                     (props.value(QStringLiteral("CanPlay"), true).toBool() ||
                      props.value(QStringLiteral("CanPause"), true).toBool());
    s.canGoNext = props.value(QStringLiteral("CanGoNext"), true).toBool();
    s.canGoPrevious = props.value(QStringLiteral("CanGoPrevious"), true).toBool();
    s.canSeek = props.value(QStringLiteral("CanSeek"), false).toBool() &&
                props.value(QStringLiteral("CanControl"), true).toBool();

    const QVariantMap meta = qdbus_cast<QVariantMap>(props.value(QStringLiteral("Metadata")));
    s.title = meta.value(QStringLiteral("xesam:title")).toString();

    // xesam:artist is "as" in the spec and arrives as a QDBusArgument, which
    // qdbus_cast demarshals. A few players send a bare string instead - that
    // ALSO works, but via qdbus_cast's own fall-through to QVariant's
    // QString->QStringList conversion, NOT via the toStringList() line below.
    //
    // That line is vestigial, and measured to be so (2026-07-17): it only runs
    // when the cast yields an empty list, which happens solely for an absent
    // key, an empty list, or a wrong-typed value - and toStringList() yields
    // empty for all three, so it cannot change the result. It is kept only
    // because it is harmless and removing it is a behaviour change nobody has a
    // reason to risk on an exotic QDBusArgument shape. Do not mistake it for the
    // thing that handles the bare-string case; tst_mpris_state.cpp's
    // artistFromBareString pins the real mechanism.
    QStringList artists = qdbus_cast<QStringList>(meta.value(QStringLiteral("xesam:artist")));
    if (artists.isEmpty())
        artists = meta.value(QStringLiteral("xesam:artist")).toStringList();
    s.artist = artists.join(QStringLiteral(", "));

    s.album = meta.value(QStringLiteral("xesam:album")).toString();
    s.artUrl = meta.value(QStringLiteral("mpris:artUrl")).toString();
    // Artwork is rendered by QML Image, outside the widget NetHub choke point.
    // Accept only a readable local file (or our own qrc resource); otherwise a
    // player-controlled http(s)/data/custom URL could bypass the Hub's offline and
    // host-allowlist policy. Chromium also commonly advertises stale file URLs,
    // which are cleared so QML does not emit a misleading "Cannot open" warning.
    const QUrl art(s.artUrl);
    if (art.scheme().compare(QStringLiteral("qrc"), Qt::CaseInsensitive) == 0) {
        // Bundled application resource: no egress and Qt resolves it itself.
    } else if (art.isLocalFile()) {
        const QString local = art.toLocalFile();
        if (local.isEmpty() || !QFileInfo(local).isReadable())
            s.artUrl.clear();
    } else {
        s.artUrl.clear();
    }
    s.lengthUs = meta.value(QStringLiteral("mpris:length")).toLongLong();
    s.playerName = playerNameFromService(service);

    // A service can be registered on the bus (CanControl: true) with no track
    // actually loaded - e.g. a browser tab with audio capability but nothing
    // played yet, or a player that was just stopped. Treat that as genuinely
    // "nothing playing" rather than showing a blank card: require either a real
    // title or an active Playing/Paused status.
    const bool hasTrack = !s.title.isEmpty();
    const bool isActive = s.status == QStringLiteral("Playing") ||
                          s.status == QStringLiteral("Paused");
    s.available = hasTrack || isActive;
    if (!s.available) {
        s.title = s.artist = s.album = s.artUrl = QString();
        s.lengthUs = 0;
    }
    return s;
}

bool visiblyDiffers(const TrackState& a, const TrackState& b) {
    return a.available != b.available || a.status != b.status || a.title != b.title ||
           a.artist != b.artist || a.album != b.album || a.artUrl != b.artUrl ||
           a.playerName != b.playerName || a.canPlayPause != b.canPlayPause ||
           a.canGoNext != b.canGoNext || a.canGoPrevious != b.canGoPrevious ||
           a.canSeek != b.canSeek || a.lengthUs != b.lengthUs;
}

}  // namespace mpris

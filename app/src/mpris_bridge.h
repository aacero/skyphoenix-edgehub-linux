#ifndef MPRIS_BRIDGE_H
#define MPRIS_BRIDGE_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>
#include <QtDBus/QDBusConnection>

#include "mpris_state.h"

// MprisBridge - exposes the active MPRIS media player (Spotify, browsers /
// YouTube Music, etc.) to QML: now-playing metadata + transport control.
//
// It discovers `org.mpris.MediaPlayer2.*` services on the session bus, prefers
// whichever is Playing, watches PropertiesChanged for live updates, and polls
// Position while playing. Exposed as the `media` context property.
class MprisBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QString title READ title NOTIFY changed)
    Q_PROPERTY(QString artist READ artist NOTIFY changed)
    Q_PROPERTY(QString album READ album NOTIFY changed)
    Q_PROPERTY(QString artUrl READ artUrl NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)          // Playing/Paused/Stopped
    Q_PROPERTY(bool playing READ playing NOTIFY changed)
    Q_PROPERTY(QString playerName READ playerName NOTIFY changed)
    Q_PROPERTY(double position READ position NOTIFY positionChanged) // 0..1 fraction
    Q_PROPERTY(bool canPlayPause READ canPlayPause NOTIFY changed)
    Q_PROPERTY(bool canGoNext READ canGoNext NOTIFY changed)
    Q_PROPERTY(bool canGoPrevious READ canGoPrevious NOTIFY changed)
    Q_PROPERTY(bool canSeek READ canSeek NOTIFY changed)
    Q_PROPERTY(qlonglong positionMs READ positionMs NOTIFY positionChanged)
    Q_PROPERTY(qlonglong durationMs READ durationMs NOTIFY changed)
    Q_PROPERTY(bool busConnected READ busConnected CONSTANT)
    Q_PROPERTY(bool scanning READ scanning NOTIFY discoveryChanged)
    Q_PROPERTY(QStringList availablePlayers READ availablePlayers NOTIFY discoveryChanged)
    Q_PROPERTY(QString preferredPlayer READ preferredPlayer WRITE setPreferredPlayer NOTIFY preferredPlayerChanged)

public:
    explicit MprisBridge(QObject* parent = nullptr);
    explicit MprisBridge(const QDBusConnection& bus, QObject* parent = nullptr);
    ~MprisBridge() override;

    bool available() const { return m_available; }
    QString title() const { return m_title; }
    QString artist() const { return m_artist; }
    QString album() const { return m_album; }
    QString artUrl() const { return m_artUrl; }
    QString status() const { return m_status; }
    bool playing() const { return m_status == QStringLiteral("Playing"); }
    QString playerName() const { return m_playerName; }
    double position() const {
        return m_lengthUs > 0 ? double(m_positionUs) / double(m_lengthUs) : 0.0;
    }
    bool canPlayPause() const { return m_canPlayPause; }
    bool canGoNext() const { return m_canGoNext; }
    bool canGoPrevious() const { return m_canGoPrevious; }
    bool canSeek() const { return m_canSeek; }
    qlonglong positionMs() const { return qMax<qlonglong>(0, m_positionUs / 1000); }
    qlonglong durationMs() const { return qMax<qlonglong>(0, m_lengthUs / 1000); }
    bool busConnected() const { return m_bus.isConnected(); }
    bool scanning() const { return m_scanning; }
    QStringList availablePlayers() const { return m_availablePlayers; }
    QString preferredPlayer() const { return m_preferredPlayer; }
    void setPreferredPlayer(const QString& player);

    Q_INVOKABLE void playPause();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    Q_INVOKABLE void seekFraction(double fraction);

    // ── Test seam (no D-Bus) ─────────────────────────────────────────────────
    // Fold a Player GetAll property map into the exposed state, notifying QML
    // only when a visible field moved. Public for the same reason
    // SystemSettingsProbe::applySetting is: it is the seam tests drive with
    // crafted property maps, so the dirty-check that suppresses redundant
    // changed() (and with it the QML animation restarts) can be proven without
    // a session bus. In production it is only ever called from refresh()'s
    // async GetAll reply. See tests/cpp/tst_mpris_state.cpp.
    void applyProps(const QVariantMap& props);
    bool applyPropsReply(const QString& service, const QVariantMap& props);
    bool applyPositionReply(const QString& service, bool valid,
                            qlonglong positionUs);

    // The currently exposed state, in resolveTrack()'s shape.
    mpris::TrackState currentTrack() const;

signals:
    void changed();
    void positionChanged();
    void discoveryChanged();
    void preferredPlayerChanged();
    void transportError(const QString& action, const QString& message);

private slots:
    void onPropertiesChanged(const QString& iface, const QVariantMap& changed,
                             const QStringList& invalidated);
    void reevaluate();  // (re)pick the active player
    void poll();        // refresh Position while playing

private:
    // All D-Bus reads are ASYNC (QDBusPendingCallWatcher) so a hung player can
    // never block the GUI event loop.
    void connectTo(const QString& service);
    void chooseFrom(const QStringList& services);  // pick the active player (async fan-out)
    void refresh();                                 // GetAll → applyProps → fetchPosition
    void fetchPosition();
    void callPlayer(const char* method);

    QDBusConnection m_bus;
    QString m_service, m_playerName, m_title, m_artist, m_album, m_artUrl, m_status;
    qlonglong m_lengthUs = 0;
    qlonglong m_positionUs = 0;
    bool m_available = false;
    bool m_canPlayPause = true;
    bool m_canGoNext = true;
    bool m_canGoPrevious = true;
    bool m_canSeek = false;
    bool m_scanning = false;
    QStringList m_availablePlayers;
    QString m_preferredPlayer;
    QTimer m_poll;
    QTimer m_rescan;
};

#endif // MPRIS_BRIDGE_H

#include "mpris_bridge.h"

#include "mpris_state.h"

#include <QDebug>
#include <QMap>
#include <QSharedPointer>
#include <QStringList>
#include <QtDBus/QDBusArgument>
#include <QtDBus/QDBusMessage>
#include <QtDBus/QDBusPendingCall>
#include <QtDBus/QDBusPendingCallWatcher>
#include <QtDBus/QDBusPendingReply>
#include <QtDBus/QDBusVariant>

static const char* kPath = "/org/mpris/MediaPlayer2";
static const char* kPlayerIface = "org.mpris.MediaPlayer2.Player";
static const char* kPropsIface = "org.freedesktop.DBus.Properties";
// The bus-name prefix and every decision made from it live in mpris_state.h -
// see the note above applyProps().

// Cap on how long a D-Bus call may take before erroring. Every call here is
// ASYNC, so this bounds a hung player's reply latency without ever blocking the
// GUI thread (the old code used QDBus::Block up to 800ms, which could stack up
// to (N+1)×800ms of stall across a rescan). Building calls with createMethodCall
// (not QDBusInterface) also avoids a blocking introspection round-trip.
static constexpr int kDbusTimeoutMs = 800;

// ─────────────────────────────────────────────────────────────────────────────
// The asynchronous D-Bus conversation is exercised against isolated mock
// players in tst_mpris_bridge.cpp. That suite runs under dbus-run-session and
// cannot discover or control the developer's desktop players.

// Build a Properties.Get(iface, prop) call message.
static QDBusMessage propGetMsg(const QString& service, const QString& iface, const QString& prop) {
    QDBusMessage msg = QDBusMessage::createMethodCall(
        service, QString::fromLatin1(kPath), QString::fromLatin1(kPropsIface),
        QStringLiteral("Get"));
    msg << iface << prop;
    return msg;
}

MprisBridge::MprisBridge(QObject* parent)
    : MprisBridge(QDBusConnection::sessionBus(), parent) {}

MprisBridge::MprisBridge(const QDBusConnection& bus, QObject* parent)
    : QObject(parent), m_bus(bus) {
    if (!m_bus.isConnected()) {
        qWarning() << "MprisBridge: no session D-Bus connection; media controls disabled";
        return;   // leave the timers stopped → stays permanently unavailable
    }
    // Re-scan for players periodically (they come and go); poll position faster.
    m_rescan.setInterval(3000);
    connect(&m_rescan, &QTimer::timeout, this, &MprisBridge::reevaluate);
    m_rescan.start();

    m_poll.setInterval(1000);
    connect(&m_poll, &QTimer::timeout, this, &MprisBridge::poll);
    m_poll.start();

    reevaluate();
}

MprisBridge::~MprisBridge() {
    // Drop the PropertiesChanged match rule on the shared session bus so it
    // doesn't linger after we're gone.
    if (!m_service.isEmpty()) {
        m_bus.disconnect(m_service, kPath, kPropsIface, QStringLiteral("PropertiesChanged"),
                         this, SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
    }
}

// (Re)pick the active player: async ListNames → filter to MPRIS services.
void MprisBridge::reevaluate() {
    if (!m_scanning) {
        m_scanning = true;
        emit discoveryChanged();
    }
    QDBusMessage msg = QDBusMessage::createMethodCall(
        QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"),
        QStringLiteral("org.freedesktop.DBus"), QStringLiteral("ListNames"));
    auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(msg, kDbusTimeoutMs), this);
    connect(w, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher* self) {
        self->deleteLater();
        QDBusPendingReply<QStringList> reply = *self;
        QStringList services;
        if (reply.isValid()) {
            for (const QString& name : reply.value())
                if (mpris::isMprisService(name))
                    services << name;
        }
        QStringList players;
        players.reserve(services.size());
        for (const QString& service : services)
            players << mpris::playerNameFromService(service);
        players.sort(Qt::CaseInsensitive);
        if (players != m_availablePlayers) {
            m_availablePlayers = players;
            emit discoveryChanged();
        }
        if (m_scanning) {
            m_scanning = false;
            emit discoveryChanged();
        }
        chooseFrom(services);
    });
}

// Given the current MPRIS services, prefer one that is Playing, else keep the
// current one if still present, else the first. The PlaybackStatus probe is an
// async fan-out that decides once all replies are in.
void MprisBridge::chooseFrom(const QStringList& services) {
    if (services.isEmpty()) {
        if (m_available || !m_service.isEmpty())
            connectTo(QString());
        return;
    }
    auto order = QSharedPointer<QStringList>::create(services);
    auto statuses = QSharedPointer<QMap<QString, QString>>::create();
    auto remaining = QSharedPointer<int>::create(services.size());
    for (const QString& s : services) {
        QDBusMessage msg = propGetMsg(s, QString::fromLatin1(kPlayerIface),
                                      QStringLiteral("PlaybackStatus"));
        auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(msg, kDbusTimeoutMs), this);
        connect(w, &QDBusPendingCallWatcher::finished, this,
                [this, s, order, statuses, remaining](QDBusPendingCallWatcher* self) {
            self->deleteLater();
            QDBusPendingReply<QDBusVariant> reply = *self;
            statuses->insert(s, reply.isValid() ? reply.value().variant().toString() : QString());
            if (--(*remaining) != 0)
                return;
            // The policy itself is pure and lives in mpris_state.h; this lambda
            // only supplies the collected replies.
            const QString chosen = mpris::choosePlayer(*order, *statuses, m_service,
                                                       m_preferredPlayer);
            if (chosen != m_service)
                connectTo(chosen);
            else
                refresh();
        });
    }
}

void MprisBridge::connectTo(const QString& service) {
    if (!m_service.isEmpty()) {
        m_bus.disconnect(m_service, kPath, kPropsIface, QStringLiteral("PropertiesChanged"),
                         this, SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
    }
    m_service = service;
    if (!m_service.isEmpty()) {
        m_bus.connect(m_service, kPath, kPropsIface, QStringLiteral("PropertiesChanged"),
                      this, SLOT(onPropertiesChanged(QString, QVariantMap, QStringList)));
    }
    refresh();
}

void MprisBridge::onPropertiesChanged(const QString&, const QVariantMap&, const QStringList&) {
    refresh();
}

// GetAll the player props (async), apply them, then fetch Position (async).
void MprisBridge::refresh() {
    if (m_service.isEmpty()) {
        if (m_available) {
            m_available = false;
            m_title = m_artist = m_album = m_artUrl = m_status = m_playerName = QString();
            m_lengthUs = m_positionUs = 0;
            emit changed();
        }
        return;
    }
    QDBusMessage getAll = QDBusMessage::createMethodCall(
        m_service, QString::fromLatin1(kPath), QString::fromLatin1(kPropsIface),
        QStringLiteral("GetAll"));
    getAll << QString::fromLatin1(kPlayerIface);
    // Capture the service this reply belongs to. If the active player switched
    // while the async call was in flight, a late reply from the OLD player must
    // NOT overwrite the new one's metadata.
    const QString service = m_service;
    auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(getAll, kDbusTimeoutMs), this);
    connect(w, &QDBusPendingCallWatcher::finished, this,
            [this, service](QDBusPendingCallWatcher* self) {
        self->deleteLater();
        QDBusPendingReply<QVariantMap> reply = *self;
        if (service != m_service)
            return;   // player changed since we asked; drop the stale reply
        if (!reply.isValid()) {
            if (m_available) { m_available = false; emit changed(); }
            return;
        }
        if (!applyPropsReply(service, reply.value()))
            return;
        fetchPosition();
    });
}

// Fold one GetAll reply into the exposed state. The two decisions here - what
// the reply MEANS (mpris::resolveTrack: artist list-or-string, art-URL
// validation, the availability rule) and whether QML must be told
// (mpris::visiblyDiffers) - are pure and live in mpris_state.h, where
// tests/cpp/tst_mpris_state.cpp drives them without a bus. What is left is the
// member-state fold, which is what this test seam exists to cover.
void MprisBridge::applyProps(const QVariantMap& m) {
    const mpris::TrackState next = mpris::resolveTrack(m, m_service);
    // Dirty-check: applyProps runs on every 3s rescan, but emitting changed()
    // unconditionally re-fires every property NOTIFY and restarts QML animations
    // bound to them. Only emit when a visible field really changed.
    const bool dirty = mpris::visiblyDiffers(currentTrack(), next);

    m_status = next.status;
    m_title = next.title;
    m_artist = next.artist;
    m_album = next.album;
    m_artUrl = next.artUrl;
    m_lengthUs = next.lengthUs;
    m_playerName = next.playerName;
    m_available = next.available;
    m_canPlayPause = next.canPlayPause;
    m_canGoNext = next.canGoNext;
    m_canGoPrevious = next.canGoPrevious;
    m_canSeek = next.canSeek;

    if (dirty)
        emit changed();
}

bool MprisBridge::applyPropsReply(const QString& service,
                                  const QVariantMap& props) {
    if (service != m_service)
        return false;
    applyProps(props);
    return true;
}

bool MprisBridge::applyPositionReply(const QString& service, bool valid,
                                     qlonglong positionUs) {
    if (service != m_service || !valid)
        return false;
    m_positionUs = positionUs;
    emit positionChanged();
    return true;
}

// The exposed state, in the same shape resolveTrack() produces, so the two can
// be compared field-for-field.
mpris::TrackState MprisBridge::currentTrack() const {
    mpris::TrackState s;
    s.status = m_status;
    s.title = m_title;
    s.artist = m_artist;
    s.album = m_album;
    s.artUrl = m_artUrl;
    s.playerName = m_playerName;
    s.lengthUs = m_lengthUs;
    s.available = m_available;
    s.canPlayPause = m_canPlayPause;
    s.canGoNext = m_canGoNext;
    s.canGoPrevious = m_canGoPrevious;
    s.canSeek = m_canSeek;
    return s;
}

void MprisBridge::setPreferredPlayer(const QString& player) {
    const QString next = player.trimmed();
    if (next.compare(m_preferredPlayer, Qt::CaseInsensitive) == 0)
        return;
    m_preferredPlayer = next;
    emit preferredPlayerChanged();
    if (m_bus.isConnected())
        reevaluate();
}

void MprisBridge::fetchPosition() {
    if (m_service.isEmpty())
        return;
    QDBusMessage msg = propGetMsg(m_service, QString::fromLatin1(kPlayerIface),
                                  QStringLiteral("Position"));
    // Same identity guard as refresh(): a Position reply from a player we've since
    // switched away from must not scrub the new player's position.
    const QString service = m_service;
    auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(msg, kDbusTimeoutMs), this);
    connect(w, &QDBusPendingCallWatcher::finished, this,
            [this, service](QDBusPendingCallWatcher* self) {
        self->deleteLater();
        QDBusPendingReply<QDBusVariant> reply = *self;
        applyPositionReply(
            service, reply.isValid(),
            reply.isValid() ? reply.value().variant().toLongLong() : 0);
    });
}

void MprisBridge::poll() {
    if (!m_available || m_service.isEmpty() || m_status != QStringLiteral("Playing"))
        return;
    fetchPosition();
}

void MprisBridge::callPlayer(const char* method) {
    const QString methodName = QString::fromLatin1(method);
    if (m_service.isEmpty() || !m_available)
        return;
    if ((methodName == QStringLiteral("PlayPause") && !m_canPlayPause) ||
        (methodName == QStringLiteral("Next") && !m_canGoNext) ||
        (methodName == QStringLiteral("Previous") && !m_canGoPrevious))
        return;
    // Fire-and-forget transport control (never blocks the GUI thread), but log a
    // failed call so a broken PlayPause/Next/Previous isn't entirely invisible.
    QDBusMessage msg = QDBusMessage::createMethodCall(
        m_service, QString::fromLatin1(kPath), QString::fromLatin1(kPlayerIface),
        QString::fromLatin1(method));
    auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(w, &QDBusPendingCallWatcher::finished, this,
            [this, methodName](QDBusPendingCallWatcher* self) {
        self->deleteLater();
        QDBusPendingReply<> reply = *self;
        if (reply.isError()) {
            qWarning() << "MprisBridge:" << methodName << "failed:" << reply.error().message();
            emit transportError(methodName, reply.error().message());
        }
    });
    // Reflect the new state promptly.
    QTimer::singleShot(200, this, [this] { refresh(); });
}

void MprisBridge::seekFraction(double fraction) {
    if (m_service.isEmpty() || !m_available || !m_canSeek || m_lengthUs <= 0)
        return;
    const double bounded = qBound(0.0, fraction, 1.0);
    const qlonglong targetUs = qRound64(bounded * double(m_lengthUs));
    const qlonglong offsetUs = targetUs - m_positionUs;
    if (offsetUs == 0)
        return;
    QDBusMessage msg = QDBusMessage::createMethodCall(
        m_service, QString::fromLatin1(kPath), QString::fromLatin1(kPlayerIface),
        QStringLiteral("Seek"));
    msg << offsetUs;
    const QString service = m_service;
    const qlonglong previousUs = m_positionUs;
    auto* w = new QDBusPendingCallWatcher(m_bus.asyncCall(msg), this);
    connect(w, &QDBusPendingCallWatcher::finished, this,
            [this, service, previousUs, targetUs](QDBusPendingCallWatcher* self) {
        self->deleteLater();
        QDBusPendingReply<> reply = *self;
        if (!reply.isError())
            return;
        const QString message = reply.error().message();
        qWarning() << "MprisBridge: Seek failed:" << message;
        emit transportError(QStringLiteral("Seek"), message);
        if (service == m_service && m_positionUs == targetUs) {
            m_positionUs = previousUs;
            emit positionChanged();
        }
    });
    m_positionUs = targetUs;
    emit positionChanged();
    QTimer::singleShot(200, this, [this] { fetchPosition(); });
}

void MprisBridge::playPause() { callPlayer("PlayPause"); }
void MprisBridge::next() { callPlayer("Next"); }
void MprisBridge::previous() { callPlayer("Previous"); }

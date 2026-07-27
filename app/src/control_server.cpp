#include "control_server.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>

#include "control_protocol.h"
#include "control_socket_path.h"

ControlServer::ControlServer(QObject* parent) : QObject(parent) {}

ControlServer::~ControlServer() {
    if (m_server)
        m_server->close();
}

bool ControlServer::start() {
    const QString path = xeneon::controlSocketPath();
    if (path.isEmpty()) {
        // No private location to bind. Refusing is deliberate: a shared fallback
        // is what stranded live hubs and invited /tmp squatting. The hub runs on
        // without live Manager control; the Manager still edits config directly.
        qWarning() << "ControlServer: no safe socket location; live control disabled";
        return false;
    }

    // Clear any stale node left by a previous crashed instance. Now that the path
    // is per-user-session rather than one shared /tmp name, this can only ever
    // unlink OUR OWN leftovers - it used to unlink a live hub's socket.
    QLocalServer::removeServer(path);

    m_server = new QLocalServer(this);
    // Restrict to the current user.
    m_server->setSocketOptions(QLocalServer::UserAccessOption);
    if (!m_server->listen(path)) {
        qWarning() << "ControlServer: failed to listen on" << path << ":"
                   << m_server->errorString();
        return false;
    }
    connect(m_server, &QLocalServer::newConnection, this, &ControlServer::onNewConnection);
    qInfo() << "ControlServer listening on" << path;
    return true;
}

void ControlServer::onNewConnection() {
    while (m_server->hasPendingConnections()) {
        QLocalSocket* sock = m_server->nextPendingConnection();
        m_buffers.insert(sock, QByteArray());
        connect(sock, &QLocalSocket::readyRead, this, &ControlServer::onReadyRead);
        connect(sock, &QLocalSocket::disconnected, this, &ControlServer::onDisconnected);
    }
}

void ControlServer::onReadyRead() {
    QLocalSocket* sock = qobject_cast<QLocalSocket*>(sender());
    if (!sock)
        return;
    // Look the buffer up (don't operator[]-insert): if the socket was already
    // torn down by the oversized/disconnect path, there's nothing to append to.
    auto it = m_buffers.find(sock);
    if (it == m_buffers.end())
        return;
    it.value().append(sock->readAll());
    // Process complete lines. Re-look up the buffer each iteration and splice the
    // line out of it BEFORE dispatching: handleLine() can re-enter the event loop
    // (writeJson()'s flush, or a slot on uiStateReceived that reloads the UI) and
    // erase this socket's entry, so any reference into m_buffers held across the
    // callback could dangle. `line` is an independent copy, safe to pass along.
    while (true) {
        auto bit = m_buffers.find(sock);
        if (bit == m_buffers.end())
            return;   // socket was torn down by a previous dispatch
        const int nl = bit.value().indexOf('\n');
        if (nl < 0)
            break;
        if (nl > xeneon::kMaxControlFrameBytes) {
            qWarning() << "ControlServer: oversized message, dropping connection";
            m_buffers.remove(sock);
            sock->abort();
            sock->deleteLater();
            return;
        }
        const QByteArray line = bit.value().left(nl);
        bit.value().remove(0, nl + 1);
        if (!line.trimmed().isEmpty())
            handleLine(sock, line);
    }
    auto remaining = m_buffers.find(sock);
    if (remaining != m_buffers.end()
        && remaining.value().size() > xeneon::kMaxControlFrameBytes) {
        qWarning() << "ControlServer: oversized partial message, dropping connection";
        m_buffers.remove(sock);
        sock->abort();
        sock->deleteLater();
    }
}

void ControlServer::onDisconnected() {
    QLocalSocket* sock = qobject_cast<QLocalSocket*>(sender());
    if (!sock)
        return;
    m_buffers.remove(sock);
    sock->deleteLater();
}

void ControlServer::handleLine(QLocalSocket* sock, const QByteArray& line) {
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(line, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        writeJson(sock, QJsonDocument(QJsonObject{{"type", "error"},
                                                  {"message", "invalid json"}})
                            .toJson(QJsonDocument::Compact));
        return;
    }
    const QJsonObject obj = doc.object();
    const QString type = obj.value("type").toString();
    const QString requestId = obj.value("requestId").toString();

    if (type == "getUiState") {
        const QString state = m_provider ? m_provider() : QString();
        QJsonObject reply{{"type", "uiState"}, {"state", state}};
        // Carry the live content rotation so a connected Manager can mirror the
        // panel's orientation in its preview. Omitted when no provider is set, so
        // the reply is byte-identical for callers that don't wire one.
        if (m_rotationProvider)
            reply["rotation"] = m_rotationProvider();
        // The page the panel is currently showing, so the Manager can confirm the
        // hub mirrored its selected screen (and a test can assert it).
        if (m_pageProvider)
            reply["currentPage"] = m_pageProvider();
        if (m_stateLiveProvider)
            reply["stateLive"] = m_stateLiveProvider();
        if (m_configGenerationTokenProvider) {
            const QString token = m_configGenerationTokenProvider();
            if (!token.isEmpty())
                reply["configGenerationToken"] = token;
        }
        writeJson(sock, QJsonDocument(reply).toJson(QJsonDocument::Compact));
    } else if (type == "setActivePage") {
        // The Manager selected a screen; show it on the panel so the device
        // mirrors what the user is editing. Fire-and-forget: acks ok even with no
        // handler wired (a headless/mock hub), and clamps happen on the QML side.
        const int p = obj.value("page").toInt(-1);
        if (m_activePageHandler)
            m_activePageHandler(p);
        writeAck(sock, true, type, QString(), requestId);
    } else if (type == "setUiState") {
        const QString state = obj.value("state").toString();
        if (state.isEmpty()) {
            writeAck(sock, false, type, QStringLiteral("empty state"), requestId);
            return;
        }
        // Let the owner apply the state and report whether it stuck. The signal is
        // delivered synchronously (same-thread direct connection), so `ok` holds
        // the real result once emit returns - the ack must reflect it, otherwise
        // the Manager treats a failed persist as success and silently diverges.
        bool ok = false;
        bool liveApplied = false;
        emit uiStateReceived(state, &ok, &liveApplied);
        writeAck(
            sock,
            ok,
            type,
            QStringLiteral("failed to apply state"),
            requestId,
            QJsonObject{{QStringLiteral("liveApplied"), liveApplied},
                        {QStringLiteral("queued"), ok && !liveApplied}});
    } else if (type == "setTargetDisplay") {
        const QString connector = obj.value("connector").toString();
        const QString model = obj.value("model").toString();
        // At least one identifier is required: an all-empty target would blank the
        // hub's display match rather than express a choice.
        if (connector.isEmpty() && model.isEmpty()) {
            writeAck(sock, false, type, QStringLiteral("empty target display"), requestId);
            return;
        }
        bool ok = false;
        bool durabilityUncertain = false;
        emit targetDisplayReceived(
            connector, model, &ok, &durabilityUncertain);
        writeAck(
            sock,
            ok,
            type,
            QStringLiteral("failed to apply target display"),
            requestId,
            QJsonObject{{QStringLiteral("durabilityUncertain"),
                         ok && durabilityUncertain}});
    } else if (type == "setAutostart") {
        // Require a real bool: toBool() on a missing/garbage value silently means
        // false, which would turn a malformed request into "autostart off".
        if (!obj.value("enabled").isBool()) {
            writeAck(sock, false, type, QStringLiteral("missing enabled flag"), requestId);
            return;
        }
        bool ok = false;
        bool durabilityUncertain = false;
        emit autostartReceived(
            obj.value("enabled").toBool(), &ok, &durabilityUncertain);
        writeAck(
            sock,
            ok,
            type,
            QStringLiteral("failed to apply autostart"),
            requestId,
            QJsonObject{{QStringLiteral("durabilityUncertain"),
                         ok && durabilityUncertain}});
    } else if (type == "setLicenseKey") {
        // The `key` field must be present as a string (an absent field would be
        // an empty string → a silent CLEAR of the user's licence, which is not
        // what a malformed request should do). An empty string IS the explicit
        // "remove my key" and is allowed only when sent deliberately.
        if (!obj.value("key").isString()) {
            writeAck(sock, false, type, QStringLiteral("missing key field"), requestId);
            return;
        }
        bool ok = false;
        emit licenseKeyReceived(obj.value("key").toString(), &ok);
        writeAck(sock, ok, type, QStringLiteral("failed to apply licence key"), requestId);
    } else if (type == "ping") {
        writeJson(sock, QJsonDocument(QJsonObject{{"type", "pong"}}).toJson(QJsonDocument::Compact));
    } else if (type == "shutdown") {
        // The companion Manager asked the hub to quit cleanly (Start/Stop control).
        // Ack first so the client sees it, then let main() quit gracefully (which
        // persists config + tears down normally).
        writeAck(sock, true, type, QString(), requestId);
        emit shutdownRequested();
    } else {
        writeJson(sock, QJsonDocument(QJsonObject{{"type", "error"},
                                                  {"message", "unknown type"}})
                            .toJson(QJsonDocument::Compact));
    }
}

void ControlServer::writeAck(QLocalSocket* sock, bool ok, const QString& forType,
                             const QString& failMessage, const QString& requestId,
                             const QJsonObject& extra) {
    QJsonObject o{{"type", ok ? "ok" : "error"}, {"for", forType}};
    if (!requestId.isEmpty())
        o.insert(QStringLiteral("requestId"), requestId);
    if (!ok)
        o.insert("message", failMessage);
    for (auto it = extra.constBegin(); it != extra.constEnd(); ++it)
        o.insert(it.key(), it.value());
    writeJson(sock, QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void ControlServer::writeJson(QLocalSocket* sock, const QByteArray& compactJson) {
    if (!sock || sock->state() != QLocalSocket::ConnectedState)
        return;
    sock->write(compactJson);
    sock->write("\n");
    sock->flush();
}

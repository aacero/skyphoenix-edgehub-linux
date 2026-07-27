// Robustness tests for ManagerBackend's IPC read path (onSocketReadyRead):
//   1. An unterminated flood (no '\n') is capped by the shared protocol limit.
//      Once it exceeds that limit the Manager aborts the connection and clears
//      the pending buffer, so a stuck or hostile peer cannot grow it forever.
//   2. A malformed JSON line is LOGGED and IGNORED without desyncing the stream:
//      a valid uiState sent right after it is still adopted.
// Both drive a REAL QLocalSocket (the same seam the sync tests use) so the read
// slot runs exactly as in production. Needs a QGuiApplication (offscreen).
#include <QtTest>
#include <QLocalServer>
#include <QLocalSocket>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>

#include "manager_backend.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

// Bind exactly where production resolves it (manager_backend.h pulls in the
// same header), so the fake hub and the ManagerBackend under test cannot
// drift apart - and so this never binds the shared /tmp node a live hub used
// to own. See app/src/control_socket_path.h.
static QString kSock() { return xeneon::controlSocketPath(); }

static QStringList* gCapturedMessages = nullptr;
static void captureMessage(
    QtMsgType, const QMessageLogContext&, const QString& message) {
    if (gCapturedMessages)
        gCapturedMessages->append(message);
}

static QString testState(const char* key, int value) {
    return QString::fromUtf8(
        QJsonDocument(QJsonObject{
                          {"version", 1},
                          {"appearance", QJsonObject{}},
                          {"pages", QJsonArray{}},
                          {"settings", QJsonObject{}},
                          {"test", QJsonObject{{QString::fromLatin1(key), value}}},
                      })
            .toJson(QJsonDocument::Compact));
}

// Minimal server that hands us the connected socket so the test can write raw
// bytes (well-formed or not) straight at the Manager's read slot.
class RawHub : public QObject {
    Q_OBJECT
public:
    QLocalServer server;
    QLocalSocket* client = nullptr;
    bool start() {
        QLocalServer::removeServer(kSock());
        connect(&server, &QLocalServer::newConnection, this, [this] {
            client = server.nextPendingConnection();
        });
        return server.listen(kSock());
    }
    void sendUiState(const QString& state) {
        client->write(QJsonDocument(QJsonObject{{"type", "uiState"}, {"state", state}})
                          .toJson(QJsonDocument::Compact));
        client->write("\n");
        client->flush();
    }
    void sendRaw(const QByteArray& bytes) { client->write(bytes); client->flush(); }
};

class TstRxCap : public QObject {
    Q_OBJECT
    qint64 clockMs_ = 100000;
private slots:

    // ── An unterminated flood is bounded ──
    void unterminatedFloodIsCapped() {
        RawHub hub; QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        // Push beyond the shared cap with NO newline in chunks; pump the event
        // loop so the read slot runs between chunks (matching streamed delivery).
        const QByteArray chunk(256 * 1024, 'x');   // 256 KiB of non-newline bytes
        const int chunksToExceed =
            xeneon::kMaxControlFrameBytes / chunk.size() + 2;
        for (int i = 0; i < chunksToExceed && b.hubConnected(); ++i) {
            hub.sendRaw(chunk);
            QTest::qWait(10);
            QVERIFY2(b.rxBufferSizeForTest()
                         <= xeneon::kMaxControlFrameBytes + chunk.size(),
                     qPrintable(QStringLiteral("rx buffer grew to %1 bytes")
                                    .arg(b.rxBufferSizeForTest())));
        }
        QTRY_VERIFY_WITH_TIMEOUT(!b.hubConnected(), 1000);
        QCOMPARE(b.rxBufferSizeForTest(), 0);
    }

    // ── A malformed line is ignored without desyncing the stream ──
    void malformedLineIgnoredNoDesync() {
        RawHub hub; QVERIFY(hub.start());
        ManagerBackend b;
        b.setClockForTest([this] { return clockMs_; });
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        QSignalSpy spy(&b, &ManagerBackend::configChanged);

        // One garbage line + one blank line + one VALID uiState, all framed by '\n'
        // in a single write so they process in order. The garbage/blank must be
        // skipped and the valid line still adopted (proves framing kept us in sync).
        const QByteArray secret("MALFORMED_FRAME_PRIVATE_TOKEN");
        QByteArray msgs;
        msgs += QByteArray("{\"state\":\"") + secret + QByteArray("\", trailing ]\n");
        msgs += QByteArray("   \n");
        msgs += QJsonDocument(QJsonObject{{"type", "uiState"}, {"state", testState("ok", 9)}})
                    .toJson(QJsonDocument::Compact) + "\n";
        QStringList captured;
        gCapturedMessages = &captured;
        const QtMessageHandler previousHandler =
            qInstallMessageHandler(captureMessage);
        hub.sendRaw(msgs);
        const bool adopted =
            QTest::qWaitFor([&b] { return b.uiState() == testState("ok", 9); }, 5000);
        qInstallMessageHandler(previousHandler);
        gCapturedMessages = nullptr;

        QVERIFY(adopted);
        QCOMPARE(spy.count(), 1);   // exactly the one valid line was adopted
        QCOMPARE(b.rxBufferSizeForTest(), 0);   // all complete lines consumed
        for (const QString& message : captured)
            QVERIFY2(!message.contains(QString::fromLatin1(secret)),
                     "malformed IPC diagnostics must never include frame bytes");
    }

    void nearLimitValidFrameMayArriveAcrossReads() {
        RawHub hub;
        QVERIFY(hub.start());
        ManagerBackend b;
        QTRY_VERIFY_WITH_TIMEOUT(hub.client != nullptr, 5000);
        QTRY_VERIFY_WITH_TIMEOUT(b.hubConnected(), 5000);

        const QString state = QString::fromUtf8(
            QJsonDocument(QJsonObject{
                              {"version", 1},
                              {"appearance", QJsonObject{}},
                              {"pages", QJsonArray{}},
                              {"settings", QJsonObject{}},
                              {"padding", QString(900 * 1024, QLatin1Char('x'))},
                          })
                .toJson(QJsonDocument::Compact));
        const QByteArray frame =
            QJsonDocument(QJsonObject{{"type", "uiState"}, {"state", state}})
                .toJson(QJsonDocument::Compact);
        QVERIFY(frame.size() < xeneon::kMaxControlFrameBytes);
        QVERIFY(frame.size() > 512 * 1024);

        const int split = frame.size() / 2;
        hub.sendRaw(frame.left(split));
        QTRY_COMPARE_WITH_TIMEOUT(b.rxBufferSizeForTest(), split, 5000);
        hub.sendRaw(frame.mid(split) + "\n");
        QTRY_COMPARE_WITH_TIMEOUT(b.uiState(), state, 5000);
        QCOMPARE(b.rxBufferSizeForTest(), 0);
    }
};

QTEST_MAIN(TstRxCap)
#include "tst_rx_cap.moc"

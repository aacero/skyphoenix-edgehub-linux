#include <QtDBus>
#include <QtTest>

#include <memory>

#include "mpris_bridge.h"

namespace {

constexpr auto kPath = "/org/mpris/MediaPlayer2";

class MockPlayer final : public QObject, protected QDBusContext {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(bool CanControl READ canControl)
    Q_PROPERTY(bool CanPlay READ canPlay)
    Q_PROPERTY(bool CanPause READ canPause)
    Q_PROPERTY(bool CanGoNext READ canGoNext)
    Q_PROPERTY(bool CanGoPrevious READ canGoPrevious)
    Q_PROPERTY(bool CanSeek READ canSeek)
    Q_PROPERTY(qlonglong Position READ position)

public:
    QString status = QStringLiteral("Playing");
    QString title = QStringLiteral("Private bus track");
    qlonglong lengthUs = 1'000'000;
    qlonglong positionUs = 250'000;
    bool control = true;
    bool play = true;
    bool pause = true;
    bool goNext = true;
    bool goPrevious = true;
    bool seek = true;
    bool failNext = false;
    bool failSeek = false;
    int playPauseCalls = 0;
    int nextCalls = 0;
    int previousCalls = 0;
    QList<qlonglong> seekOffsets;

    QString playbackStatus() const { return status; }
    QVariantMap metadata() const {
        return {
            {QStringLiteral("xesam:title"), title},
            {QStringLiteral("xesam:artist"), QStringList{QStringLiteral("Test Artist")}},
            {QStringLiteral("mpris:length"), lengthUs},
        };
    }
    bool canControl() const { return control; }
    bool canPlay() const { return play; }
    bool canPause() const { return pause; }
    bool canGoNext() const { return goNext; }
    bool canGoPrevious() const { return goPrevious; }
    bool canSeek() const { return seek; }
    qlonglong position() const { return positionUs; }

public slots:
    void PlayPause() { ++playPauseCalls; }
    void Next() {
        ++nextCalls;
        if (failNext)
            sendErrorReply(QDBusError::Failed, QStringLiteral("mock Next failure"));
    }
    void Previous() { ++previousCalls; }
    void Seek(qlonglong offset) {
        seekOffsets.append(offset);
        if (failSeek) {
            sendErrorReply(QDBusError::Failed, QStringLiteral("mock Seek failure"));
            return;
        }
        positionUs += offset;
    }
};

struct RegisteredPlayer {
    QString connectionName;
    QString service;
    QDBusConnection bus;

    RegisteredPlayer(const QString& suffix, MockPlayer* player)
        : connectionName(QStringLiteral("xeneon-mpris-test-") + suffix),
          service(QStringLiteral("org.mpris.MediaPlayer2.") + suffix),
          bus(QDBusConnection::connectToBus(
              QDBusConnection::SessionBus, connectionName)) {
        if (!bus.isConnected())
            return;
        if (!bus.registerObject(
                QString::fromLatin1(kPath), player,
                QDBusConnection::ExportAllSlots |
                    QDBusConnection::ExportAllProperties)) {
            return;
        }
        bus.registerService(service);
    }

    bool valid() const {
        return bus.isConnected() &&
               bus.interface()->isServiceRegistered(service);
    }

    ~RegisteredPlayer() {
        if (bus.isConnected()) {
            bus.unregisterService(service);
            bus.unregisterObject(QString::fromLatin1(kPath));
        }
        QDBusConnection::disconnectFromPeer(connectionName);
    }
};

}  // namespace

class MprisBridgeTest final : public QObject {
    Q_OBJECT

private slots:
    void noPlayersSettlesUnavailable() {
        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.scanning(), 2000);
        QVERIFY(!bridge.available());
        QVERIFY(bridge.availablePlayers().isEmpty());
        QVERIFY(bridge.busConnected());
        QCOMPARE(bridge.position(), 0.0);
        QCOMPARE(bridge.preferredPlayer(), QString());

        bridge.playPause();
        bridge.next();
        bridge.previous();
        bridge.seekFraction(0.5);
        QVERIFY(!bridge.available());
    }

    void listNamesFailureSettlesUnavailable() {
        const QString runtimeDir = qEnvironmentVariable("XDG_RUNTIME_DIR");
        QVERIFY(!runtimeDir.isEmpty());
        QDBusServer server(
            QStringLiteral("unix:tmpdir=") + runtimeDir);
        QVERIFY(server.isConnected());

        const QString connectionName =
            QStringLiteral("xeneon-mpris-test-nonbus-peer");
        QDBusConnection peer = QDBusConnection::connectToPeer(
            server.address(), connectionName);
        QVERIFY(peer.isConnected());

        MprisBridge bridge(peer);
        QVERIFY(bridge.busConnected());
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.scanning(), 2000);
        QVERIFY(!bridge.available());
        QVERIFY(bridge.availablePlayers().isEmpty());

        QDBusConnection::disconnectFromBus(connectionName);
    }

    void discoversPlayerAndReadsProperties() {
        MockPlayer player;
        RegisteredPlayer registration(QStringLiteral("discover"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QCOMPARE(bridge.availablePlayers(),
                 QStringList{QStringLiteral("discover")});
        QCOMPARE(bridge.playerName(), QStringLiteral("discover"));
        QCOMPARE(bridge.title(), player.title);
        QCOMPARE(bridge.artist(), QStringLiteral("Test Artist"));
        QCOMPARE(bridge.album(), QString());
        QCOMPARE(bridge.artUrl(), QString());
        QVERIFY(bridge.playing());
        QVERIFY(bridge.canPlayPause());
        QVERIFY(bridge.canGoNext());
        QVERIFY(bridge.canGoPrevious());
        QVERIFY(bridge.canSeek());
        QCOMPARE(bridge.durationMs(), 1000);
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), 250, 2000);
        QCOMPARE(bridge.position(), 0.25);
    }

    void samePlayerRescanRefreshesAndPlayingPollUpdatesPosition() {
        MockPlayer player;
        RegisteredPlayer registration(QStringLiteral("refresh"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), 250, 2000);

        player.title = QStringLiteral("Refreshed title");
        QVERIFY(QMetaObject::invokeMethod(&bridge, "reevaluate"));
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.scanning(), 2000);
        QTRY_COMPARE_WITH_TIMEOUT(
            bridge.title(), QStringLiteral("Refreshed title"), 2000);

        player.positionUs = 400'000;
        QVERIFY(QMetaObject::invokeMethod(&bridge, "poll"));
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), qlonglong(400), 2000);

        player.status = QStringLiteral("Paused");
        QVERIFY(QMetaObject::invokeMethod(
            &bridge, "onPropertiesChanged",
            Q_ARG(QString, QStringLiteral("org.mpris.MediaPlayer2.Player")),
            Q_ARG(QVariantMap, QVariantMap()),
            Q_ARG(QStringList, QStringList())));
        QTRY_COMPARE_WITH_TIMEOUT(bridge.status(), QStringLiteral("Paused"), 2000);
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), qlonglong(400), 2000);

        player.positionUs = 700'000;
        QVERIFY(QMetaObject::invokeMethod(&bridge, "poll"));
        QTest::qWait(150);
        QCOMPARE(bridge.positionMs(), qlonglong(400));
    }

    void staleRepliesCannotOverwriteTheSelectedPlayer() {
        MockPlayer player;
        RegisteredPlayer registration(QStringLiteral("current"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), 250, 2000);
        const QString currentService =
            QStringLiteral("org.mpris.MediaPlayer2.current");

        QVariantMap replacementMetadata{
            {QStringLiteral("xesam:title"), QStringLiteral("Replacement")}};
        QVariantMap replacementProps{
            {QStringLiteral("PlaybackStatus"), QStringLiteral("Playing")},
            {QStringLiteral("Metadata"), replacementMetadata}};
        QSignalSpy changes(&bridge, &MprisBridge::changed);
        const int changesBefore = changes.count();

        QVERIFY(!bridge.applyPropsReply(
            QStringLiteral("org.mpris.MediaPlayer2.stale"),
            replacementProps));
        QCOMPARE(bridge.title(), player.title);
        QCOMPARE(changes.count(), changesBefore);

        QVERIFY(bridge.applyPropsReply(currentService, replacementProps));
        QCOMPARE(bridge.title(), QStringLiteral("Replacement"));
        QCOMPARE(changes.count(), changesBefore + 1);

        QSignalSpy positions(&bridge, &MprisBridge::positionChanged);
        const int positionsBefore = positions.count();
        QVERIFY(!bridge.applyPositionReply(
            QStringLiteral("org.mpris.MediaPlayer2.stale"), true, 900'000));
        QVERIFY(!bridge.applyPositionReply(currentService, false, 900'000));
        QCOMPARE(bridge.positionMs(), qlonglong(250));
        QCOMPARE(positions.count(), positionsBefore);

        QVERIFY(bridge.applyPositionReply(currentService, true, 900'000));
        QCOMPARE(bridge.positionMs(), qlonglong(900));
        QCOMPARE(positions.count(), positionsBefore + 1);
    }

    void dispatchesSupportedControlsAndClampedSeek() {
        MockPlayer player;
        RegisteredPlayer registration(QStringLiteral("controls"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), 250, 2000);

        bridge.playPause();
        bridge.next();
        bridge.previous();
        QTRY_COMPARE_WITH_TIMEOUT(player.playPauseCalls, 1, 1000);
        QTRY_COMPARE_WITH_TIMEOUT(player.nextCalls, 1, 1000);
        QTRY_COMPARE_WITH_TIMEOUT(player.previousCalls, 1, 1000);

        bridge.seekFraction(1.5);
        QTRY_COMPARE_WITH_TIMEOUT(player.seekOffsets.size(), 1, 1000);
        QCOMPARE(player.seekOffsets[0], qlonglong(750'000));
        QCOMPARE(bridge.positionMs(), qlonglong(1000));

        bridge.seekFraction(-0.5);
        QTRY_COMPARE_WITH_TIMEOUT(player.seekOffsets.size(), 2, 1000);
        QCOMPARE(player.seekOffsets[1], qlonglong(-1'000'000));
        QCOMPARE(bridge.positionMs(), qlonglong(0));

        bridge.seekFraction(0.0);
        QTest::qWait(100);
        QCOMPARE(player.seekOffsets.size(), 2);
    }

    void blocksUnsupportedControls() {
        MockPlayer player;
        player.play = false;
        player.pause = false;
        player.goNext = false;
        player.goPrevious = false;
        player.seek = false;
        RegisteredPlayer registration(QStringLiteral("unsupported"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QVERIFY(!bridge.canPlayPause());
        QVERIFY(!bridge.canGoNext());
        QVERIFY(!bridge.canGoPrevious());
        QVERIFY(!bridge.canSeek());

        bridge.playPause();
        bridge.next();
        bridge.previous();
        bridge.seekFraction(0.75);
        QTest::qWait(250);
        QCOMPARE(player.playPauseCalls, 0);
        QCOMPARE(player.nextCalls, 0);
        QCOMPARE(player.previousCalls, 0);
        QVERIFY(player.seekOffsets.isEmpty());
    }

    void reportsControlAndSeekErrors() {
        MockPlayer player;
        player.failNext = true;
        player.failSeek = true;
        RegisteredPlayer registration(QStringLiteral("errors"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), 250, 2000);
        QSignalSpy errors(&bridge, &MprisBridge::transportError);

        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "MprisBridge:.*Next.*failed:.*mock Next failure")));
        bridge.next();
        QTRY_COMPARE_WITH_TIMEOUT(errors.count(), 1, 2000);
        QCOMPARE(errors.at(0).at(0).toString(), QStringLiteral("Next"));

        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "MprisBridge: Seek failed:.*mock Seek failure")));
        bridge.seekFraction(1.0);
        QTRY_COMPARE_WITH_TIMEOUT(errors.count(), 2, 2000);
        QCOMPARE(errors.at(1).at(0).toString(), QStringLiteral("Seek"));
        QTRY_COMPARE_WITH_TIMEOUT(bridge.positionMs(), qlonglong(250), 1000);
    }

    void onlinePreferenceReselectsPlayer() {
        MockPlayer playing;
        playing.title = QStringLiteral("Playing first");
        MockPlayer preferred;
        preferred.status = QStringLiteral("Paused");
        preferred.title = QStringLiteral("Preferred second");
        RegisteredPlayer first(QStringLiteral("first"), &playing);
        RegisteredPlayer second(QStringLiteral("second"), &preferred);
        QVERIFY(first.valid());
        QVERIFY(second.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QCOMPARE(bridge.title(), playing.title);
        bridge.setPreferredPlayer(QStringLiteral("SECOND"));
        QTRY_COMPARE_WITH_TIMEOUT(bridge.title(), preferred.title, 3000);
        QCOMPARE(bridge.playerName(), QStringLiteral("second"));
    }

    void failedStatusProbeCannotBeatPlayingPlayer() {
        QDBusConnection silent = QDBusConnection::connectToBus(
            QDBusConnection::SessionBus, QStringLiteral("xeneon-mpris-test-silent"));
        QVERIFY(silent.isConnected());
        QVERIFY(silent.registerService(
            QStringLiteral("org.mpris.MediaPlayer2.silent")));

        MockPlayer player;
        RegisteredPlayer registration(QStringLiteral("working"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        QCOMPARE(bridge.playerName(), QStringLiteral("working"));
        QCOMPARE(bridge.availablePlayers(),
                 (QStringList{QStringLiteral("silent"),
                              QStringLiteral("working")}));

        silent.unregisterService(QStringLiteral("org.mpris.MediaPlayer2.silent"));
        QDBusConnection::disconnectFromBus(
            QStringLiteral("xeneon-mpris-test-silent"));
    }

    void disappearingPlayerClearsVisibleState() {
        MockPlayer player;
        auto registration =
            std::make_unique<RegisteredPlayer>(QStringLiteral("vanish"), &player);
        QVERIFY(registration->valid());

        MprisBridge bridge;
        QSignalSpy changes(&bridge, &MprisBridge::changed);
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        registration.reset();
        QVERIFY(QMetaObject::invokeMethod(&bridge, "reevaluate"));
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.scanning(), 2000);
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.available(), 2000);
        QVERIFY(bridge.availablePlayers().isEmpty());
        QVERIFY(bridge.title().isEmpty());
        QVERIFY(changes.count() >= 2);
    }

    void invalidGetAllClearsPriorVisibleStateOnce() {
        MockPlayer player;
        RegisteredPlayer registration(QStringLiteral("broken"), &player);
        QVERIFY(registration.valid());

        MprisBridge bridge;
        QSignalSpy changes(&bridge, &MprisBridge::changed);
        QTRY_VERIFY_WITH_TIMEOUT(bridge.available(), 3000);
        const int beforeFailure = changes.count();

        registration.bus.unregisterObject(QString::fromLatin1(kPath));
        QVERIFY(QMetaObject::invokeMethod(
            &bridge, "onPropertiesChanged",
            Q_ARG(QString, QStringLiteral("org.mpris.MediaPlayer2.Player")),
            Q_ARG(QVariantMap, QVariantMap()),
            Q_ARG(QStringList, QStringList())));
        QTRY_VERIFY_WITH_TIMEOUT(!bridge.available(), 2000);
        QCOMPARE(changes.count(), beforeFailure + 1);

        QVERIFY(QMetaObject::invokeMethod(
            &bridge, "onPropertiesChanged",
            Q_ARG(QString, QStringLiteral("org.mpris.MediaPlayer2.Player")),
            Q_ARG(QVariantMap, QVariantMap()),
            Q_ARG(QStringList, QStringList())));
        QTest::qWait(150);
        QCOMPARE(changes.count(), beforeFailure + 1);
    }
};

QTEST_GUILESS_MAIN(MprisBridgeTest)
#include "tst_mpris_bridge.moc"

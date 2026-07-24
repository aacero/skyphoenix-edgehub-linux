// Unit tests for the MPRIS logic extracted out of the D-Bus bridge
// (app/src/mpris_state.{h,cpp}) plus the one member-state fold that stayed
// behind (MprisBridge::applyProps).
//
// NO SESSION BUS IS USED, OR WANTED. The player-choice policy and the
// metadata/availability rules are decisions about data, not conversations with
// a bus, so they are driven here as plain function calls: fast, deterministic,
// and - unlike a bus-backed test - they run identically on a CI runner with no
// D-Bus at all. The property maps below are the shapes a real GetAll reply
// delivers, reproduced as literals.
//
// The applyProps case constructs a real MprisBridge. That is safe ONLY because
// tests/cpp/CMakeLists.txt points DBUS_SESSION_BUS_ADDRESS at a nonexistent
// socket for this test, so the ctor takes its documented no-bus path: it warns,
// leaves both timers stopped, and never scans. mprisBridgeIsOfflineInThisTest()
// asserts exactly that, so if the sandbox ever regained a bus this test would
// FAIL rather than quietly start driving the developer's real media players.
#include <QtTest>
#include <QDBusArgument>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QUrl>
#include <QtMath>

#include "mpris_bridge.h"
#include "mpris_state.h"

// Refuse to run outside a sandbox - see hermetic.h (a raw run once destroyed a
// developer's real config).
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

using mpris::TrackState;

namespace {

// A Player GetAll reply: PlaybackStatus + a Metadata a{sv}.
QVariantMap propsWith(const QString& status, const QVariantMap& metadata) {
    QVariantMap m;
    m.insert(QStringLiteral("PlaybackStatus"), status);
    m.insert(QStringLiteral("Metadata"), metadata);
    return m;
}

}  // namespace

class TstMprisState : public QObject {
    Q_OBJECT
private slots:

    // ── The bus-name prefix rules ───────────────────────────────────────────

    void mprisServiceFilter() {
        QVERIFY(mpris::isMprisService("org.mpris.MediaPlayer2.spotify"));
        QVERIFY(mpris::isMprisService("org.mpris.MediaPlayer2.chromium.instance123"));
        // Near-misses that ListNames really does return alongside the players.
        QVERIFY(!mpris::isMprisService("org.freedesktop.DBus"));
        QVERIFY(!mpris::isMprisService("org.mpris.MediaPlayer"));   // no trailing dot
        QVERIFY(!mpris::isMprisService(""));
        QVERIFY(!mpris::isMprisService("com.example.org.mpris.MediaPlayer2.x"));  // not a prefix
    }

    void playerNameStripsPrefix() {
        QCOMPARE(mpris::playerNameFromService("org.mpris.MediaPlayer2.spotify"), QString("spotify"));
        QCOMPARE(mpris::playerNameFromService("org.mpris.MediaPlayer2.chromium.instance7"),
                 QString("chromium.instance7"));
        QCOMPARE(mpris::playerNameFromService(QString()), QString());
    }

    // ── The player-choice policy ────────────────────────────────────────────
    // (was a lambda inside chooseFrom's async fan-out; pure all along)

    // Rule 1: a Playing player wins, wherever it sits in the list.
    void choosePrefersPlaying() {
        const QStringList order{"a", "b", "c"};
        QMap<QString, QString> st{{"a", "Paused"}, {"b", "Playing"}, {"c", "Stopped"}};
        QCOMPARE(mpris::choosePlayer(order, st, QString()), QString("b"));
        // ...even when the current pick is a different, still-present player.
        QCOMPARE(mpris::choosePlayer(order, st, "a"), QString("b"));
    }

    // Rule 1, tie-break: the FIRST Playing in `order` wins, not the last.
    void choosePrefersFirstPlaying() {
        const QStringList order{"a", "b", "c"};
        QMap<QString, QString> st{{"a", "Stopped"}, {"b", "Playing"}, {"c", "Playing"}};
        QCOMPARE(mpris::choosePlayer(order, st, QString()), QString("b"));
        QCOMPARE(mpris::choosePlayer(order, st, "c"), QString("b"));
    }

    // Rule 2: nobody playing → keep the current player if it is still there.
    // This is what stops the card flapping between two idle players every 3s.
    void chooseKeepsCurrentWhenNonePlaying() {
        const QStringList order{"a", "b", "c"};
        QMap<QString, QString> st{{"a", "Paused"}, {"b", "Paused"}, {"c", "Stopped"}};
        QCOMPARE(mpris::choosePlayer(order, st, "c"), QString("c"));
        QCOMPARE(mpris::choosePlayer(order, st, "b"), QString("b"));
    }

    // Rule 3: nobody playing and the current player is gone (or there is none)
    // → fall back to the first.
    void chooseFallsBackToFirst() {
        const QStringList order{"a", "b"};
        QMap<QString, QString> st{{"a", "Paused"}, {"b", "Stopped"}};
        QCOMPARE(mpris::choosePlayer(order, st, "vanished"), QString("a"));
        QCOMPARE(mpris::choosePlayer(order, st, QString()), QString("a"));
    }

    // A player that never answered the PlaybackStatus probe has "" recorded for
    // it (see the fan-out's reply.isValid() branch). It must not count as
    // Playing, and must not crash the ordering.
    void chooseIgnoresNonAnsweringPlayers() {
        const QStringList order{"silent", "b"};
        QMap<QString, QString> st{{"silent", QString()}, {"b", "Playing"}};
        QCOMPARE(mpris::choosePlayer(order, st, QString()), QString("b"));

        // Nobody playing, nobody answering → still deterministic: first.
        QMap<QString, QString> none{{"silent", QString()}, {"b", QString()}};
        QCOMPARE(mpris::choosePlayer(order, none, QString()), QString("silent"));

        // A status map missing an entry entirely behaves the same as "".
        QCOMPARE(mpris::choosePlayer(order, QMap<QString, QString>(), QString()),
                 QString("silent"));
    }

    // The empty case: chooseFrom() short-circuits before calling this, but the
    // policy must still be total rather than dereference order->first().
    void chooseWithNoServices() {
        QCOMPARE(mpris::choosePlayer({}, {}, "was-playing"), QString());
    }

    // Status matching is exact - MPRIS spells it "Playing".
    void chooseStatusMatchIsExact() {
        const QStringList order{"a", "b"};
        QMap<QString, QString> st{{"a", "playing"}, {"b", "PLAYING"}};
        // Neither is the spec spelling → rule 3, not rule 1.
        QCOMPARE(mpris::choosePlayer(order, st, QString()), QString("a"));
    }

    void chooseHonoursPreferredPlayerIdentity() {
        const QStringList order{"org.mpris.MediaPlayer2.vlc",
                                "org.mpris.MediaPlayer2.spotify"};
        QMap<QString, QString> st{{order[0], "Playing"}, {order[1], "Paused"}};
        QCOMPARE(mpris::choosePlayer(order, st, order[0], "spotify"), order[1]);
        QCOMPARE(mpris::choosePlayer(order, st, order[0],
                                     "ORG.MPRIS.MEDIAPLAYER2.SPOTIFY"), order[1]);
        QCOMPARE(mpris::choosePlayer(order, st, order[0], "missing"), order[0]);
    }

    // ── resolveTrack: artist list-or-string ─────────────────────────────────

    // The spec shape: xesam:artist is "as", which Qt demarshals to a QStringList.
    void artistFromList() {
        QVariantMap meta{{"xesam:title", "Song"},
                         {"xesam:artist", QStringList{"A", "B"}}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QCOMPARE(s.artist, QString("A, B"));
    }

    // The off-spec shape a few players send: a bare string. It must survive as
    // the artist rather than becoming empty.
    //
    // HONESTY NOTE: this passes via qdbus_cast's own QString->QStringList
    // conversion, NOT via the `if (artists.isEmpty())` fallback below it -
    // deleting that fallback leaves this test green (verified by sabotage,
    // 2026-07-17). The fallback is vestigial; see the comment in
    // mpris_state.cpp. This test pins the mechanism that actually works, and
    // deliberately does not pretend to cover the one that does not.
    void artistFromBareString() {
        QVariantMap meta{{"xesam:title", "Song"},
                         {"xesam:artist", QString("Solo Artist")}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QCOMPARE(s.artist, QString("Solo Artist"));
    }

    // Nonsense-typed artist (a player sending the wrong signature) degrades to
    // no artist rather than to garbage - and does not take the track down with
    // it, since the title still makes it available.
    void artistWrongTypeDegradesToEmpty() {
        QVariantMap meta{{"xesam:title", "Song"}, {"xesam:artist", 42}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QCOMPARE(s.artist, QString());
        QVERIFY(s.available);
    }

    // An empty list is not an artist.
    void artistAbsentOrEmpty() {
        QVariantMap meta{{"xesam:title", "Song"}, {"xesam:artist", QStringList{}}};
        QCOMPARE(mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x").artist,
                 QString());
        QVariantMap none{{"xesam:title", "Song"}};
        QCOMPARE(mpris::resolveTrack(propsWith("Playing", none), "org.mpris.MediaPlayer2.x").artist,
                 QString());
    }

    // ── resolveTrack: art-URL validation ────────────────────────────────────

    // A readable file:// path is kept verbatim.
    void artUrlReadableFileIsKept() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = dir.filePath("cover.png");
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("png");
        f.close();
        const QString url = QUrl::fromLocalFile(path).toString();
        QVERIFY(url.startsWith("file://"));

        QVariantMap meta{{"xesam:title", "Song"}, {"mpris:artUrl", url}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QCOMPARE(s.artUrl, url);
    }

    // The Chromium case: a stale file:// path that no longer exists is CLEARED,
    // so QML's Image never tries it and never logs "Cannot open".
    void artUrlUnreadableFileIsCleared() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString path = dir.filePath("gone.png");
        QVERIFY(!QFile::exists(path));
        const QString url = QUrl::fromLocalFile(path).toString();

        QVariantMap meta{{"xesam:title", "Song"}, {"mpris:artUrl", url}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QCOMPARE(s.artUrl, QString());
    }

    // file:// with no path at all resolves to an empty local file → cleared.
    void artUrlEmptyLocalFileIsCleared() {
        QVariantMap meta{{"xesam:title", "Song"}, {"mpris:artUrl", QString("file://")}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QCOMPARE(s.artUrl, QString());
    }

    // Remote artwork would be fetched by QML Image outside NetHub, bypassing the
    // global offline/allowlist policy. Suppress it rather than creating a hidden
    // egress path controlled by an arbitrary player on the session bus.
    void artUrlRemoteIsSuppressed() {
        for (const QString& url : {QStringLiteral("https://i.scdn.co/image/abc"),
                                   QStringLiteral("http://example.org/a.png")}) {
            QVariantMap meta{{"xesam:title", "Song"}, {"mpris:artUrl", url}};
            const TrackState s = mpris::resolveTrack(propsWith("Playing", meta),
                                                     "org.mpris.MediaPlayer2.x");
            QCOMPARE(s.artUrl, QString());
        }
    }

    void artUrlUnknownAndDataSchemesAreSuppressed() {
        for (const QString& url : {QStringLiteral("ftp://example.org/a.png"),
                                   QStringLiteral("data:image/png;base64,AAAA"),
                                   QStringLiteral("/tmp/untrusted-bare-path.png")}) {
            QVariantMap meta{{"xesam:title", "Song"}, {"mpris:artUrl", url}};
            QCOMPARE(mpris::resolveTrack(propsWith("Playing", meta),
                                         "org.mpris.MediaPlayer2.x").artUrl,
                     QString());
        }
    }

    // ── resolveTrack: the availability rule ─────────────────────────────────
    // A service can sit on the bus with nothing loaded. `available` needs a real
    // title OR an active status, else every field is blanked - this is what stops
    // a blank now-playing card being shown.

    void availableWithTitleAndStatus() {
        QVariantMap meta{{"xesam:title", "Song"},
                         {"xesam:artist", QStringList{"A"}},
                         {"xesam:album", "Alb"},
                         {"mpris:length", qlonglong(240000000)}};
        const TrackState s = mpris::resolveTrack(propsWith("Playing", meta),
                                                 "org.mpris.MediaPlayer2.spotify");
        QVERIFY(s.available);
        QCOMPARE(s.title, QString("Song"));
        QCOMPARE(s.artist, QString("A"));
        QCOMPARE(s.album, QString("Alb"));
        QCOMPARE(s.lengthUs, qlonglong(240000000));
        QCOMPARE(s.playerName, QString("spotify"));
        QCOMPARE(s.status, QString("Playing"));
    }

    // A title with no status (some players omit it mid-transition) still counts.
    void availableWithTitleOnly() {
        QVariantMap meta{{"xesam:title", "Song"}};
        const TrackState s = mpris::resolveTrack(propsWith(QString(), meta),
                                                 "org.mpris.MediaPlayer2.x");
        QVERIFY(s.available);
        QCOMPARE(s.title, QString("Song"));
    }

    // Paused with no title (a stream that has not sent metadata yet) still counts:
    // there IS an active player to show and control.
    void availableWhenPausedWithoutTitle() {
        const TrackState s = mpris::resolveTrack(propsWith("Paused", QVariantMap()),
                                                 "org.mpris.MediaPlayer2.x");
        QVERIFY(s.available);
        QCOMPARE(s.status, QString("Paused"));
    }

    void availableWhenPlayingWithoutTitle() {
        const TrackState s = mpris::resolveTrack(propsWith("Playing", QVariantMap()),
                                                 "org.mpris.MediaPlayer2.x");
        QVERIFY(s.available);
    }

    // THE case this rule exists for: a browser tab registered on the bus, Stopped,
    // nothing loaded. Not available, and every field blanked - including the art
    // and length the player still advertises.
    void unavailableStoppedWithNoTrackBlanksEverything() {
        QVariantMap meta{{"xesam:artist", QStringList{"Ghost"}},
                         {"xesam:album", "Stale Album"},
                         {"mpris:artUrl", QString("https://example.org/stale.png")},
                         {"mpris:length", qlonglong(999)}};
        const TrackState s = mpris::resolveTrack(propsWith("Stopped", meta),
                                                 "org.mpris.MediaPlayer2.chromium");
        QVERIFY(!s.available);
        QCOMPARE(s.title, QString());
        QCOMPARE(s.artist, QString());
        QCOMPARE(s.album, QString());
        QCOMPARE(s.artUrl, QString());
        QCOMPARE(s.lengthUs, qlonglong(0));
        // status and playerName are NOT blanked - they describe the player, and
        // the card uses them to stay attached to it.
        QCOMPARE(s.status, QString("Stopped"));
        QCOMPARE(s.playerName, QString("chromium"));
    }

    // Wholly empty reply (a player that answers GetAll with nothing).
    void unavailableOnEmptyProps() {
        const TrackState s = mpris::resolveTrack(QVariantMap(), "org.mpris.MediaPlayer2.x");
        QVERIFY(!s.available);
        QCOMPARE(s.status, QString());
        QCOMPARE(s.title, QString());
    }

    void transportCapabilitiesAreResolved() {
        QVariantMap meta{{"xesam:title", "Stream"}};
        QVariantMap props = propsWith("Playing", meta);
        props.insert("CanControl", true);
        props.insert("CanPlay", false);
        props.insert("CanPause", false);
        props.insert("CanGoNext", false);
        props.insert("CanGoPrevious", true);
        props.insert("CanSeek", true);
        const TrackState s = mpris::resolveTrack(props, "org.mpris.MediaPlayer2.radio");
        QVERIFY(!s.canPlayPause);
        QVERIFY(!s.canGoNext);
        QVERIFY(s.canGoPrevious);
        QVERIFY(s.canSeek);

        props.insert("CanControl", false);
        QVERIFY(!mpris::resolveTrack(props, "org.mpris.MediaPlayer2.radio").canSeek);
    }

    // ── visiblyDiffers: the dirty-check policy ──────────────────────────────

    void identicalStatesDoNotDiffer() {
        QVariantMap meta{{"xesam:title", "Song"}, {"xesam:artist", QStringList{"A"}}};
        const TrackState a = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        const TrackState b = mpris::resolveTrack(propsWith("Playing", meta), "org.mpris.MediaPlayer2.x");
        QVERIFY(!mpris::visiblyDiffers(a, b));
    }

    void everyVisibleFieldIsWatched() {
        // Each visible field, moved one at a time, must register as dirty. If a
        // field is ever dropped from visiblyDiffers, exactly one of these fails.
        TrackState base;
        base.available = true;
        base.status = "Playing";
        base.title = "T";
        base.artist = "A";
        base.album = "Al";
        base.artUrl = "U";
        base.playerName = "P";

        TrackState t;
        t = base; t.available = false;   QVERIFY2(mpris::visiblyDiffers(base, t), "available");
        t = base; t.status = "Paused";   QVERIFY2(mpris::visiblyDiffers(base, t), "status");
        t = base; t.title = "T2";        QVERIFY2(mpris::visiblyDiffers(base, t), "title");
        t = base; t.artist = "A2";       QVERIFY2(mpris::visiblyDiffers(base, t), "artist");
        t = base; t.album = "Al2";       QVERIFY2(mpris::visiblyDiffers(base, t), "album");
        t = base; t.artUrl = "U2";       QVERIFY2(mpris::visiblyDiffers(base, t), "artUrl");
        t = base; t.playerName = "P2";   QVERIFY2(mpris::visiblyDiffers(base, t), "playerName");
        t = base; t.canPlayPause = false; QVERIFY2(mpris::visiblyDiffers(base, t), "canPlayPause");
        t = base; t.canGoNext = false;    QVERIFY2(mpris::visiblyDiffers(base, t), "canGoNext");
        t = base; t.canGoPrevious = false;
        QVERIFY2(mpris::visiblyDiffers(base, t), "canGoPrevious");
        t = base; t.canSeek = true;       QVERIFY2(mpris::visiblyDiffers(base, t), "canSeek");
        t = base; t.lengthUs = 1000;      QVERIFY2(mpris::visiblyDiffers(base, t), "lengthUs");
    }

    // Duration is rendered as elapsed/total and therefore must notify QML.
    void lengthChangeIsVisible() {
        TrackState a;
        a.available = true;
        a.title = "T";
        a.lengthUs = 1000;
        TrackState b = a;
        b.lengthUs = 2000;
        QVERIFY(mpris::visiblyDiffers(a, b));
    }

    // ── The member-state fold (MprisBridge::applyProps) ─────────────────────

    // Guard the guard: this test is only safe, and only meaningful, if the
    // bridge really is offline here. If DBUS_SESSION_BUS_ADDRESS ever pointed at
    // a live bus, MprisBridge's ctor would start scanning it - so assert the
    // no-bus contract instead of assuming it. Fails loudly; never skips.
    void mprisBridgeIsOfflineInThisTest() {
        QVERIFY2(!QDBusConnection::sessionBus().isConnected(),
                 "This test must never touch a real session bus: it would scan and "
                 "control the developer's actual media players. tests/cpp/CMakeLists.txt "
                 "must point DBUS_SESSION_BUS_ADDRESS at a nonexistent socket.");
    }

    // applyProps must notify QML when a visible field moves...
    void applyPropsNotifiesOnVisibleChange() {
        MprisBridge bridge;
        QSignalSpy spy(&bridge, &MprisBridge::changed);
        QVERIFY(spy.isValid());

        QVariantMap meta{{"xesam:title", "Song"}, {"xesam:artist", QStringList{"A"}}};
        bridge.applyProps(propsWith("Playing", meta));
        QCOMPARE(spy.count(), 1);
        QVERIFY(bridge.available());
        QCOMPARE(bridge.title(), QString("Song"));
        QCOMPARE(bridge.artist(), QString("A"));
        QVERIFY(bridge.playing());

        QVariantMap meta2{{"xesam:title", "Other"}, {"xesam:artist", QStringList{"A"}}};
        bridge.applyProps(propsWith("Playing", meta2));
        QCOMPARE(spy.count(), 2);
        QCOMPARE(bridge.title(), QString("Other"));
    }

    // ...and MUST NOT when nothing visible moved. This is the whole point of the
    // dirty-check: applyProps runs on every 3s rescan, and an unconditional
    // changed() re-fires every NOTIFY, restarting the QML animations bound to
    // them. Ten identical rescans must produce exactly one notification.
    void applyPropsSuppressesRedundantNotify() {
        MprisBridge bridge;
        QSignalSpy spy(&bridge, &MprisBridge::changed);

        QVariantMap meta{{"xesam:title", "Song"}, {"xesam:artist", QStringList{"A"}}};
        const QVariantMap props = propsWith("Playing", meta);
        for (int i = 0; i < 10; ++i)
            bridge.applyProps(props);
        QCOMPARE(spy.count(), 1);
    }

    // A duration move updates the visible total time and must notify.
    void applyPropsStoresLengthAndNotifies() {
        MprisBridge bridge;
        QSignalSpy spy(&bridge, &MprisBridge::changed);

        QVariantMap meta{{"xesam:title", "Song"}, {"mpris:length", qlonglong(100)}};
        bridge.applyProps(propsWith("Playing", meta));
        QCOMPARE(spy.count(), 1);

        QVariantMap meta2{{"xesam:title", "Song"}, {"mpris:length", qlonglong(200)}};
        bridge.applyProps(propsWith("Playing", meta2));
        QCOMPARE(spy.count(), 2);
        QCOMPARE(bridge.currentTrack().lengthUs, qlonglong(200));
        QCOMPARE(bridge.durationMs(), qlonglong(0));
    }

    // Every property QML binds to must reflect the applied reply - this is the
    // whole point of the bridge, and each getter below is a Q_PROPERTY READ.
    void bridgeExposesResolvedStateToQml() {
        MprisBridge bridge;
        QVariantMap meta{{"xesam:title", "Song"},
                         {"xesam:artist", QStringList{"A", "B"}},
                         {"xesam:album", "Alb"},
                         {"mpris:artUrl", QString("https://example.org/a.png")},
                         {"mpris:length", qlonglong(200)}};
        bridge.applyProps(propsWith("Paused", meta));

        QVERIFY(bridge.available());
        QCOMPARE(bridge.title(), QString("Song"));
        QCOMPARE(bridge.artist(), QString("A, B"));
        QCOMPARE(bridge.album(), QString("Alb"));
        QVERIFY2(bridge.artUrl().isEmpty(),
                 "remote artwork is suppressed before QML sees it");
        QCOMPARE(bridge.status(), QString("Paused"));
        QVERIFY(!bridge.playing());        // Paused is not Playing
        // playerName is derived from the service, which is empty with no bus -
        // resolveTrack's prefix-strip is pinned by playerNameStripsPrefix above.
        QCOMPARE(bridge.playerName(), QString());
        QCOMPARE(bridge.durationMs(), qlonglong(0));
        QVERIFY(!bridge.canSeek());
    }

    void bridgeStoresPreferenceWithoutABus() {
        MprisBridge bridge;
        QSignalSpy spy(&bridge, &MprisBridge::preferredPlayerChanged);
        bridge.setPreferredPlayer(" spotify ");
        QCOMPARE(bridge.preferredPlayer(), QString("spotify"));
        QCOMPARE(spy.count(), 1);
        bridge.setPreferredPlayer("SPOTIFY");
        QCOMPARE(spy.count(), 1);
        bridge.setPreferredPlayer(QString());
        QCOMPARE(spy.count(), 2);
    }

    // position() is a fraction of the track length. Nothing here can move
    // m_positionUs (that needs a bus - see the report), so what IS pinned is the
    // divide-by-zero guard: a zero/absent length must yield 0.0, not NaN or inf.
    void positionIsZeroWithoutLength() {
        MprisBridge bridge;
        // Available via status, no mpris:length at all → lengthUs == 0.
        bridge.applyProps(propsWith("Playing", QVariantMap()));
        QCOMPARE(bridge.currentTrack().lengthUs, qlonglong(0));
        QCOMPARE(bridge.position(), 0.0);
        QVERIFY(!qIsNaN(bridge.position()));

        // With a length, position is still 0.0 (0/200) but via the divide arm.
        QVariantMap meta{{"xesam:title", "Song"}, {"mpris:length", qlonglong(200)}};
        bridge.applyProps(propsWith("Playing", meta));
        QCOMPARE(bridge.currentTrack().lengthUs, qlonglong(200));
        QCOMPARE(bridge.position(), 0.0);
    }

    // Going unavailable is itself a visible change (the card must come down).
    void applyPropsNotifiesWhenTrackGoesAway() {
        MprisBridge bridge;
        QSignalSpy spy(&bridge, &MprisBridge::changed);

        QVariantMap meta{{"xesam:title", "Song"}};
        bridge.applyProps(propsWith("Playing", meta));
        QCOMPARE(spy.count(), 1);
        QVERIFY(bridge.available());

        bridge.applyProps(propsWith("Stopped", QVariantMap()));
        QCOMPARE(spy.count(), 2);
        QVERIFY(!bridge.available());
        QCOMPARE(bridge.title(), QString());
    }
};

QTEST_GUILESS_MAIN(TstMprisState)
#include "tst_mpris_state.moc"

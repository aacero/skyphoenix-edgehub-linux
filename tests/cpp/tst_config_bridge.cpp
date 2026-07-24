// Tests for ConfigBridge + WizardBridge against the REAL Rust config (hermetic
// temp XDG_CONFIG_HOME / HOME via the ctest ENVIRONMENT). GUILESS.
#include <QtTest>
#include <QFile>
#include <QDir>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QVariantMap>

#include <cstring>
#include <utility>

#include "config_bridge.h"
#include "xeneon_core.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstConfigBridge : public QObject {
    Q_OBJECT
    ConfigHandle* cfg_ = nullptr;
private slots:
    void init() { cfg_ = xeneon_config_load(); QVERIFY(cfg_); }
    void cleanup() { if (cfg_) { xeneon_config_free(cfg_); cfg_ = nullptr; } }

    void uiStateRoundTrip() {
        ConfigBridge b(cfg_);
        const QString json = QStringLiteral("{\"widgets\":[{\"id\":\"clock\"}]}");
        QVERIFY(b.saveUiState(json));
        QCOMPARE(b.uiState(), json);
    }

    void applyExternalUiStatePersists() {
        ConfigBridge b(cfg_);
        QVERIFY(!b.applyExternalUiState(QString()));         // empty rejected
        const QString json = QStringLiteral("{\"a\":1}");
        QVERIFY(b.applyExternalUiState(json));
        QCOMPARE(b.uiState(), json);
    }

    void imageUrl_data() {
        QTest::addColumn<QString>("in");
        QTest::addColumn<QString>("out");
        QTest::newRow("empty")     << "" << "";
        QTest::newRow("qrc")       << "qrc:/img/x.png" << "qrc:/img/x.png";
        QTest::newRow("http")      << "http://h/x.png" << "http://h/x.png";
        QTest::newRow("file")      << "file:///x.png"  << "file:///x.png";
        // QUrl::toString() is PrettyDecoded: a space stays literal, but reserved
        // chars like '#' (which would otherwise start a fragment) are encoded.
        QTest::newRow("abs-space") << "/tmp/a b.png"   << "file:///tmp/a b.png";
        QTest::newRow("abs-hash")  << "/tmp/a#b.png"   << "file:///tmp/a%23b.png";
        QTest::newRow("relative")  << "rel.png"        << "rel.png";
    }
    void imageUrl() {
        QFETCH(QString, in);
        QFETCH(QString, out);
        ConfigBridge b(cfg_);
        QCOMPARE(b.imageUrl(in), out);
    }

    void configJsonIsStructuredAndRedacted() {
        const QByteArray key("XE1.HUB_LICENSE_CANARY.HUB_IDENTITY_CANARY");
        const QByteArray state(
            "{\"pages\":[{\"name\":\"HUB_PRIVATE_PAGE_CANARY\","
            "\"tiles\":[{\"type\":\"notes\"}]}],\"settings\":{"
            "\"notes-1\":{\"notes\":\"HUB_PRIVATE_NOTES_CANARY\"},"
            "\"http-1\":{\"authToken\":\"HUB_PRIVATE_AUTH_CANARY\"},"
            "\"calendar-1\":{\"url\":\"https://HUB_PRIVATE_URL_CANARY\"}}}");
        QCOMPARE(xeneon_config_set_license_key(cfg_, key.constData()), 0);
        QCOMPARE(xeneon_config_set_ui_state(cfg_, state.constData()), 0);

        ConfigBridge b(cfg_);
        const QString rendered = b.configJson();
        QVERIFY(!rendered.isEmpty());
        for (const QString& canary : {
                 QStringLiteral("HUB_LICENSE_CANARY"),
                 QStringLiteral("HUB_IDENTITY_CANARY"),
                 QStringLiteral("HUB_PRIVATE_PAGE_CANARY"),
                 QStringLiteral("HUB_PRIVATE_NOTES_CANARY"),
                 QStringLiteral("HUB_PRIVATE_AUTH_CANARY"),
                 QStringLiteral("HUB_PRIVATE_URL_CANARY")}) {
            QVERIFY2(!rendered.contains(canary), qPrintable("diagnostics leaked " + canary));
        }
        const QJsonObject summary = QJsonDocument::fromJson(rendered.toUtf8()).object();
        QCOMPARE(summary.value(QStringLiteral("format")).toString(),
                 QStringLiteral("xeneon-config-diagnostics-v1"));
        QCOMPARE(summary.value(QStringLiteral("redaction")).toObject()
                     .value(QStringLiteral("sensitive_values_omitted")).toBool(), true);
        QCOMPARE(summary.value(QStringLiteral("license")).toObject()
                     .value(QStringLiteral("configured")).toBool(), true);
    }

    void versionAndStarterLayoutSurface() {
        QCOMPARE(xeneon_config_set_starter_layout(cfg_, "gaming"), 0);
        ConfigBridge b(cfg_);
        QCOMPARE(b.starterLayout(), QStringLiteral("gaming"));
        QVERIFY2(!b.appVersion().isEmpty(), "the QML version surface must never be blank");
    }

    // E3's native bridge intentionally does only the filesystem work QML cannot:
    // enumerate one directory level, return raw manifests, and report each unsafe
    // or unusable manifest without parsing/loading it. Exercise every outcome with
    // a private XDG data root so this proves the real wire contract hermetically.
    void userWidgetFilesystemContract() {
        ConfigBridge b(cfg_);

        const QByteArray savedDataHome = qgetenv("XDG_DATA_HOME");
        const bool hadDataHome = qEnvironmentVariableIsSet("XDG_DATA_HOME");

        // With no override the documented stable location is under ~/.local/share.
        qunsetenv("XDG_DATA_HOME");
        const QString defaultRoot = b.userWidgetsDir();
        if (hadDataHome) qputenv("XDG_DATA_HOME", savedDataHome);
        else qunsetenv("XDG_DATA_HOME");
        QCOMPARE(defaultRoot,
                 QDir::homePath() + QStringLiteral("/.local/share/xeneon-edge-hub/widgets"));

        QTemporaryDir dataHome;
        QVERIFY(dataHome.isValid());
        const QString root = dataHome.path() + QStringLiteral("/xeneon-edge-hub/widgets");

        // A missing root is a normal empty catalog, not an error object.
        qputenv("XDG_DATA_HOME", QFile::encodeName(dataHome.path()));
        const QStringList absent = b.listUserWidgets();
        if (hadDataHome) qputenv("XDG_DATA_HOME", savedDataHome);
        else qunsetenv("XDG_DATA_HOME");
        QVERIFY(absent.isEmpty());

        const QString valid = root + QStringLiteral("/a-valid");
        const QString missing = root + QStringLiteral("/b-missing");
        const QString large = root + QStringLiteral("/c-large");
        const QString unreadable = root + QStringLiteral("/d-unreadable");
        QVERIFY(QDir().mkpath(valid));
        QVERIFY(QDir().mkpath(missing));
        QVERIFY(QDir().mkpath(large));
        QVERIFY(QDir().mkpath(unreadable));

        const QByteArray manifest = R"({"id":"example","entry":"Main.qml"})";
        QFile validManifest(valid + QStringLiteral("/manifest.json"));
        QVERIFY(validManifest.open(QIODevice::WriteOnly));
        QCOMPARE(validManifest.write(manifest), manifest.size());
        validManifest.close();
        QFile qml(valid + QStringLiteral("/Main.qml"));
        QVERIFY(qml.open(QIODevice::WriteOnly));
        QCOMPARE(qml.write("import QtQuick\nItem {}\n"), qint64(23));
        qml.close();

        QFile oversized(large + QStringLiteral("/manifest.json"));
        QVERIFY(oversized.open(QIODevice::WriteOnly));
        QVERIFY(oversized.resize(256 * 1024 + 1));
        oversized.close();

        // QFile refuses to open a directory as a regular file, which reaches the
        // distinct "exists but unreadable" result without relying on permissions
        // (the suite may legitimately run as a privileged CI/container user).
        QVERIFY(QDir().mkpath(unreadable + QStringLiteral("/manifest.json")));

        qputenv("XDG_DATA_HOME", QFile::encodeName(dataHome.path()));
        const QString resolvedRoot = b.userWidgetsDir();
        const QStringList rows = b.listUserWidgets();
        if (hadDataHome) qputenv("XDG_DATA_HOME", savedDataHome);
        else qunsetenv("XDG_DATA_HOME");

        QCOMPARE(resolvedRoot, root);
        QCOMPARE(rows.size(), 4);
        QHash<QString, QJsonObject> byName;
        for (const QString& row : rows) {
            QJsonParseError err{};
            const QJsonDocument doc = QJsonDocument::fromJson(row.toUtf8(), &err);
            QCOMPARE(err.error, QJsonParseError::NoError);
            QVERIFY(doc.isObject());
            const QJsonObject object = doc.object();
            byName.insert(object.value(QStringLiteral("dirName")).toString(), object);
        }

        QCOMPARE(byName.value(QStringLiteral("a-valid")).value(QStringLiteral("manifest")).toString(),
                 QString::fromUtf8(manifest));
        const QJsonArray validFiles =
            byName.value(QStringLiteral("a-valid")).value(QStringLiteral("files")).toArray();
        QCOMPARE(validFiles.size(), 2);
        QCOMPARE(validFiles.at(0).toString(), QStringLiteral("Main.qml"));
        QCOMPARE(validFiles.at(1).toString(), QStringLiteral("manifest.json"));
        QCOMPARE(byName.value(QStringLiteral("b-missing")).value(QStringLiteral("error")).toString(),
                 QStringLiteral("missing manifest.json"));
        QCOMPARE(byName.value(QStringLiteral("c-large")).value(QStringLiteral("error")).toString(),
                 QStringLiteral("manifest.json larger than 256 KiB"));
        QCOMPARE(byName.value(QStringLiteral("d-unreadable")).value(QStringLiteral("error")).toString(),
                 QStringLiteral("manifest.json is not readable"));
    }

    void metricFileReaderAcceptsOnlyBoundedRegularFiles() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString metric = root.filePath(QStringLiteral("metric.txt"));
        QFile good(metric);
        QVERIFY(good.open(QIODevice::WriteOnly));
        QCOMPARE(good.write("42\n"), qint64(3));
        good.close();

        const QVariantMap ok =
            ConfigBridge::readMetricFileFromRoots(metric, {root.path()});
        QVERIFY(ok.value(QStringLiteral("ok")).toBool());
        QCOMPARE(ok.value(QStringLiteral("body")).toString(), QStringLiteral("42\n"));
        QVERIFY(ok.value(QStringLiteral("error")).toString().isEmpty());

        const QString tooLarge = root.filePath(QStringLiteral("large"));
        QFile large(tooLarge);
        QVERIFY(large.open(QIODevice::WriteOnly));
        QVERIFY(large.resize(1024 * 1024 + 1));
        large.close();
        const QVariantMap largeResult =
            ConfigBridge::readMetricFileFromRoots(tooLarge, {root.path()});
        QVERIFY(!largeResult.value(QStringLiteral("ok")).toBool());
        QCOMPARE(largeResult.value(QStringLiteral("error")).toString(),
                 QStringLiteral("too-large"));

        const QVariantMap directory =
            ConfigBridge::readMetricFileFromRoots(root.path(), {root.path()});
        QVERIFY(!directory.value(QStringLiteral("ok")).toBool());
        QCOMPARE(directory.value(QStringLiteral("error")).toString(),
                 QStringLiteral("not-regular-file"));
    }

    void metricFileReaderRejectsEscapeTraversalAndLinks() {
        QTemporaryDir allowed;
        QTemporaryDir outside;
        QVERIFY(allowed.isValid());
        QVERIFY(outside.isValid());
        const QString secret = outside.filePath(QStringLiteral("secret"));
        QFile file(secret);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("private");
        file.close();

        const QVariantMap escaped =
            ConfigBridge::readMetricFileFromRoots(secret, {allowed.path()});
        QCOMPARE(escaped.value(QStringLiteral("error")).toString(),
                 QStringLiteral("outside-approved-roots"));

        const QString link = allowed.filePath(QStringLiteral("linked"));
        QVERIFY(QFile::link(secret, link));
        const QVariantMap linked =
            ConfigBridge::readMetricFileFromRoots(link, {allowed.path()});
        QVERIFY(!linked.value(QStringLiteral("ok")).toBool());
        QVERIFY(linked.value(QStringLiteral("error")).toString() ==
                    QStringLiteral("outside-approved-roots") ||
                linked.value(QStringLiteral("error")).toString() ==
                    QStringLiteral("symlink"));

        QVERIFY(QDir().mkpath(allowed.filePath(QStringLiteral("nested"))));
        const QString traversal =
            allowed.filePath(QStringLiteral("nested/../nested/value"));
        const QVariantMap traversed =
            ConfigBridge::readMetricFileFromRoots(traversal, {allowed.path()});
        QCOMPARE(traversed.value(QStringLiteral("error")).toString(),
                 QStringLiteral("traversal"));
    }

    void metricFileReaderRejectsMissingAndSpecialFiles() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QVariantMap missing =
            ConfigBridge::readMetricFileFromRoots(root.filePath(QStringLiteral("missing")),
                                                  {root.path()});
        QCOMPARE(missing.value(QStringLiteral("error")).toString(),
                 QStringLiteral("not-found"));

        const QString fifoPath = root.filePath(QStringLiteral("pipe"));
        QCOMPARE(::mkfifo(QFile::encodeName(fifoPath).constData(), 0600), 0);
        const QVariantMap fifo =
            ConfigBridge::readMetricFileFromRoots(fifoPath, {root.path()});
        QCOMPARE(fifo.value(QStringLiteral("error")).toString(),
                 QStringLiteral("not-regular-file"));
    }

    void metricFileReaderRejectsInvalidPathShapes() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QStringList roots{root.path()};
        for (const QString& path : {
                 QString(),
                 QStringLiteral("relative/value"),
                 QStringLiteral("https://example.test/value"),
                 QStringLiteral("file://remote-host/value"),
                 root.path() + QString(QChar::Null) + QStringLiteral("/value"),
                 root.filePath(QStringLiteral("./value")),
                 root.filePath(QStringLiteral("nested/.."))}) {
            const QVariantMap result =
                ConfigBridge::readMetricFileFromRoots(path, roots);
            QVERIFY(!result.value(QStringLiteral("ok")).toBool());
            QVERIFY(!result.value(QStringLiteral("error")).toString().isEmpty());
        }
    }

    void metricFileReaderAcceptsLocalFileUrlAndCleanedRoot() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString metric = root.filePath(QStringLiteral("metric"));
        QFile file(metric);
        QVERIFY(file.open(QIODevice::WriteOnly));
        QCOMPARE(file.write("7"), qint64(1));
        file.close();

        const QString noncanonicalRoot =
            root.filePath(QStringLiteral("missing/.."));
        const QVariantMap result = ConfigBridge::readMetricFileFromRoots(
            QUrl::fromLocalFile(metric).toString(), {noncanonicalRoot});
        QVERIFY(result.value(QStringLiteral("ok")).toBool());
        QCOMPARE(result.value(QStringLiteral("body")).toString(),
                 QStringLiteral("7"));
    }

    void metricFileOpenErrorsAreClassified() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString metric = root.filePath(QStringLiteral("metric"));
        QFile file(metric);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("1");
        file.close();

        for (const auto entry : {
                 std::pair{ELOOP, QStringLiteral("symlink")},
                 std::pair{EACCES, QStringLiteral("unreadable")}}) {
            ConfigBridge::MetricFileOps ops;
            ops.openFile = [error = entry.first](const char*, int) {
                errno = error;
                return -1;
            };
            const QVariantMap result =
                ConfigBridge::readMetricFileFromRootsWithOps(
                    metric, {root.path()}, ops);
            QCOMPARE(result.value(QStringLiteral("error")).toString(),
                     entry.second);
        }
    }

    void metricFileFstatFailureClosesDescriptor() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString metric = root.filePath(QStringLiteral("metric"));
        QFile file(metric);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("1");
        file.close();

        int closed = -1;
        ConfigBridge::MetricFileOps ops;
        ops.openFile = [](const char*, int) { return 77; };
        ops.statFile = [](int, struct stat*) {
            errno = EIO;
            return -1;
        };
        ops.closeFile = [&closed](int fd) {
            closed = fd;
            return 0;
        };
        const QVariantMap result =
            ConfigBridge::readMetricFileFromRootsWithOps(
                metric, {root.path()}, ops);
        QCOMPARE(result.value(QStringLiteral("error")).toString(),
                 QStringLiteral("unreadable"));
        QCOMPARE(closed, 77);
    }

    void metricFileReadRetriesEintr() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString metric = root.filePath(QStringLiteral("metric"));
        QFile file(metric);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("seed");
        file.close();

        int reads = 0;
        int closes = 0;
        ConfigBridge::MetricFileOps ops;
        ops.openFile = [](const char*, int) { return 88; };
        ops.statFile = [](int, struct stat* out) {
            out->st_mode = S_IFREG | 0600;
            out->st_size = 0;
            return 0;
        };
        ops.readFile = [&reads](int, void* bytes, size_t) -> ssize_t {
            ++reads;
            if (reads == 1) {
                errno = EINTR;
                return -1;
            }
            if (reads == 2) {
                static_cast<char*>(bytes)[0] = '9';
                return 1;
            }
            return 0;
        };
        ops.closeFile = [&closes](int) {
            ++closes;
            return 0;
        };
        const QVariantMap result =
            ConfigBridge::readMetricFileFromRootsWithOps(
                metric, {root.path()}, ops);
        QVERIFY(result.value(QStringLiteral("ok")).toBool());
        QCOMPARE(result.value(QStringLiteral("body")).toString(),
                 QStringLiteral("9"));
        QCOMPARE(reads, 3);
        QCOMPARE(closes, 1);
    }

    void metricFileReadFailureAndGrowthFailClosed() {
        QTemporaryDir root;
        QVERIFY(root.isValid());
        const QString metric = root.filePath(QStringLiteral("metric"));
        QFile file(metric);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write("seed");
        file.close();

        ConfigBridge::MetricFileOps readFailure;
        readFailure.openFile = [](const char*, int) { return 91; };
        readFailure.statFile = [](int, struct stat* out) {
            out->st_mode = S_IFREG | 0600;
            out->st_size = 0;
            return 0;
        };
        readFailure.readFile = [](int, void*, size_t) -> ssize_t {
            errno = EIO;
            return -1;
        };
        readFailure.closeFile = [](int) { return 0; };
        const QVariantMap failed =
            ConfigBridge::readMetricFileFromRootsWithOps(
                metric, {root.path()}, readFailure);
        QCOMPARE(failed.value(QStringLiteral("error")).toString(),
                 QStringLiteral("unreadable"));

        int reads = 0;
        ConfigBridge::MetricFileOps growing = readFailure;
        growing.readFile = [&reads](int, void* bytes, size_t size) -> ssize_t {
            ++reads;
            std::memset(bytes, 'x', size);
            return static_cast<ssize_t>(size);
        };
        const QVariantMap tooLarge =
            ConfigBridge::readMetricFileFromRootsWithOps(
                metric, {root.path()}, growing);
        QCOMPARE(tooLarge.value(QStringLiteral("error")).toString(),
                 QStringLiteral("too-large"));
        QCOMPARE(reads, 129);
    }

    void unusablePolicyJsonFailsClosed() {
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "Policy FFI returned an unusable answer.*")));
        const QVariantMap failed =
            ConfigBridge::policyFromJson(QStringLiteral("{not-json"));
        QVERIFY(failed.value(QStringLiteral("active")).toBool());
        QCOMPARE(failed.value(QStringLiteral("source")).toString(),
                 QStringLiteral("fail-closed"));
        QVERIFY(failed.value(QStringLiteral("netOffline")).toBool());
        QVERIFY(failed.value(QStringLiteral("disableUserWidgets")).toBool());

        const QVariantMap valid = ConfigBridge::policyFromJson(
            QStringLiteral("{\"active\":false,\"source\":\"absent\"}"));
        QVERIFY(!valid.value(QStringLiteral("active")).toBool());
        QCOMPARE(valid.value(QStringLiteral("source")).toString(),
                 QStringLiteral("absent"));
    }

    // --- E7 Phase A: credential-reference resolution -------------------------
    // The bridge is what QML calls, so it owns the FFI's two-allocation contract
    // (value AND error must be freed). These run under the same ctest as the rest,
    // so a leak here shows up under the sanitizers/coverage build.

    void resolveSecret_envRef() {
        qputenv("XENEON_BRIDGE_TEST_TOKEN", "bridge-token");
        ConfigBridge b(cfg_);
        const QVariantMap r = b.resolveSecret("${env:XENEON_BRIDGE_TEST_TOKEN}");
        QCOMPARE(r["ok"].toBool(), true);
        QCOMPARE(r["value"].toString(), QStringLiteral("bridge-token"));
        QVERIFY(r["error"].toString().isEmpty());
        QCOMPARE(r["plaintext"].toBool(), false);
        qunsetenv("XENEON_BRIDGE_TEST_TOKEN");
    }

    void resolveSecret_fileRef() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString p = dir.filePath("tok");
        QFile f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("file-token\n");   // trailing newline is the realistic case
        f.close();

        ConfigBridge b(cfg_);
        const QVariantMap r = b.resolveSecret("file:" + p);
        QCOMPARE(r["ok"].toBool(), true);
        QCOMPARE(r["value"].toString(), QStringLiteral("file-token"));
    }

    // A missing ref must fail with a reason - not silently resolve to empty, which
    // would send an unauthenticated request that looks like a server-side 401.
    void resolveSecret_missingRefReportsWhy() {
        qunsetenv("XENEON_BRIDGE_ABSENT");
        ConfigBridge b(cfg_);
        const QVariantMap r = b.resolveSecret("${env:XENEON_BRIDGE_ABSENT}");
        QCOMPARE(r["ok"].toBool(), false);
        QVERIFY(r["value"].toString().isEmpty());
        QVERIFY2(r["error"].toString().contains("XENEON_BRIDGE_ABSENT"),
                 qPrintable("error should name the var: " + r["error"].toString()));
    }

    // Legacy plaintext keeps working (E1 shipped the field) but is flagged so the
    // UI can tell the user it is sitting in config.toml.
    void resolveSecret_plaintextWorksButIsFlagged() {
        ConfigBridge b(cfg_);
        const QVariantMap r = b.resolveSecret("ghp_legacy_literal");
        QCOMPARE(r["ok"].toBool(), true);
        QCOMPARE(r["value"].toString(), QStringLiteral("ghp_legacy_literal"));
        QCOMPARE(r["plaintext"].toBool(), true);
    }

    // An unconfigured token is a success with no value - not an error, and not a
    // plaintext warning about a secret that does not exist.
    void resolveSecret_emptyIsANoOpSuccess() {
        ConfigBridge b(cfg_);
        const QVariantMap r = b.resolveSecret(QString());
        QCOMPARE(r["ok"].toBool(), true);
        QVERIFY(r["value"].toString().isEmpty());
        QCOMPARE(r["plaintext"].toBool(), false);
    }

    void resolveSecret_keyringIsNotYetSupported() {
        ConfigBridge b(cfg_);
        const QVariantMap r = b.resolveSecret("secret://edge/ci");
        QCOMPARE(r["ok"].toBool(), false);
        QVERIFY(!r["error"].toString().isEmpty());
    }

    // S10: the formerly write-only display keys are now readable through the bridge
    // and round-trip whatever the FFI setters wrote (independent of defaults).
    void disconnectKeysExposedThroughBridge() {
        xeneon_config_set_reconnect(cfg_, 1);
        xeneon_config_set_notify_disconnect(cfg_, 0);
        QCOMPARE(xeneon_config_set_fallback_behavior(cfg_, "notify"), 0);
        ConfigBridge b(cfg_);
        QCOMPARE(b.reconnectOnHotplug(), true);
        QCOMPARE(b.notifyOnDisconnect(), false);
        QCOMPARE(b.fallbackBehavior(), QStringLiteral("notify"));

        xeneon_config_set_reconnect(cfg_, 0);
        xeneon_config_set_notify_disconnect(cfg_, 1);
        QCOMPARE(xeneon_config_set_fallback_behavior(cfg_, "hide"), 0);
        QCOMPARE(b.reconnectOnHotplug(), false);
        QCOMPARE(b.notifyOnDisconnect(), true);
        QCOMPARE(b.fallbackBehavior(), QStringLiteral("hide"));

        // Detached → guarded defaults, never a use-after-free.
        b.detach();
        QCOMPARE(b.reconnectOnHotplug(), false);
        QCOMPARE(b.notifyOnDisconnect(), false);
        QVERIFY(b.fallbackBehavior().isEmpty());
    }

    // Reconnect only migrates when enabled AND the added screen is the target.
    // The full removal policy lives in display_match.* and is covered by
    // tst_display_match; a second copy here previously drifted out of sync.
    void reconnectPolicyDecisionTable() {
        QVERIFY(shouldReconnectToScreen(true, true));
        QVERIFY(!shouldReconnectToScreen(false, true));
        QVERIFY(!shouldReconnectToScreen(true, false));
        QVERIFY(!shouldReconnectToScreen(false, false));
    }

    // After detach the bridge must become a guarded no-op (no use-after-free of the
    // freed config handle at shutdown).
    void detachGuards() {
        ConfigBridge b(cfg_);
        b.detach();
        QVERIFY(b.uiState().isEmpty());
        QVERIFY(!b.saveUiState(QStringLiteral("{\"x\":1}")));
        QVERIFY(b.starterLayout().isEmpty());
        QVERIFY(b.configJson().isEmpty());
    }

    void wizardNullConfigFails() {
        WizardBridge w(nullptr);
        QVERIFY(!w.completeWizard("h", "DP-3", "XENEON", "gaming", "dark", "#f00",
                                  false, true, true));
    }

    void wizardReportsSaveFailure() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const QString blockerPath = dir.filePath(QStringLiteral("not-a-directory"));
        QFile blocker(blockerPath);
        QVERIFY(blocker.open(QIODevice::WriteOnly));
        blocker.write("x");
        blocker.close();

        const QByteArray savedConfigHome = qgetenv("XDG_CONFIG_HOME");
        const bool hadConfigHome = qEnvironmentVariableIsSet("XDG_CONFIG_HOME");
        qputenv("XDG_CONFIG_HOME", QFile::encodeName(blockerPath + QStringLiteral("/nested")));
        WizardBridge w(cfg_);
        const bool ok = w.completeWizard(QString(), QString(), QString(), QString(),
                                         QString(), QString(), false, false, false);
        if (hadConfigHome) qputenv("XDG_CONFIG_HOME", savedConfigHome);
        else qunsetenv("XDG_CONFIG_HOME");
        QVERIFY(!ok);
    }

    void wizardPersistsAndMarksFirstRunComplete() {
        WizardBridge w(cfg_);
        QVERIFY(w.completeWizard("hash1", "DP-3", "XENEON EDGE", "productivity",
                                 "dark", "#00ff00", /*autostart*/ false,
                                 /*reconnect*/ true, /*notifyDisconnect*/ true));
        // Reload from disk and confirm it stuck.
        ConfigHandle* fresh = xeneon_config_load();
        QVERIFY(fresh);
        QCOMPARE(xeneon_config_is_first_run(fresh), 0);
        char* layout = xeneon_config_get_starter_layout(fresh);
        QCOMPARE(QString::fromUtf8(layout), QStringLiteral("productivity"));
        xeneon_string_free(layout);
        xeneon_config_free(fresh);
    }
};

QTEST_GUILESS_MAIN(TstConfigBridge)
#include "tst_config_bridge.moc"

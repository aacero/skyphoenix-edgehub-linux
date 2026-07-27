// Smoke test: launch the REAL hub binary offscreen with XENEON_GRAB → it must
// render, save a non-empty PNG, and exit 0. Exercises main(), screen matching,
// the metrics thread lifecycle, and doubles as the XENEON_GRAB use-after-free
// regression (the deferred grab lambda now captures grabPath by value).
#include <QtTest>
#include <QProcess>
#include <QProcessEnvironment>
#include <QDir>
#include <QFile>
#include <QImage>

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstSmokeHub : public QObject {
    Q_OBJECT
private slots:
    void versionWorksWithoutDisplay() {
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.remove("QT_QPA_PLATFORM");
        env.remove("DISPLAY");
        env.remove("WAYLAND_DISPLAY");

        QProcess p;
        p.setProcessEnvironment(env);
        p.setProcessChannelMode(QProcess::MergedChannels);
        p.setProgram(QStringLiteral(HUB_BIN));
        p.setArguments({QStringLiteral("--version")});
        p.start();
        QVERIFY2(p.waitForStarted(5000), "hub --version failed to start");
        QVERIFY2(p.waitForFinished(5000), "hub --version did not exit in time");

        const QByteArray output = p.readAll();
        QCOMPARE(p.exitStatus(), QProcess::NormalExit);
        QCOMPARE(p.exitCode(), 0);
        QVERIFY2(output.contains("Xeneon Edge Linux Hub"), output.constData());
    }

    void grabsAndExitsClean() {
        // The grab hook is compiled out unless -DXENEON_QA_HOOKS=ON (product
        // builds must ignore XENEON_GRAB). Without it the hub renders normally
        // and never exits, so this test can only time out - skip with the real
        // reason instead. scripts/run_cpp_tests.sh and CI both configure it ON.
        if (!QA_HOOKS_BUILD)
            QSKIP("hub built without XENEON_QA_HOOKS: XENEON_GRAB is compiled out, "
                  "so it cannot render-and-exit. Configure -DXENEON_QA_HOOKS=ON.");

        const QString grab = QDir::tempPath() + "/xeneon-smoke-hub.png";
        QFile::remove(grab);

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert("QT_QPA_PLATFORM", "offscreen");
        env.insert("XENEON_GRAB", grab);
        env.insert("XENEON_GRAB_W", "800");
        env.insert("XENEON_GRAB_H", "480");

        QProcess p;
        p.setProcessEnvironment(env);
        p.setProgram(QStringLiteral(HUB_BIN));
        p.start();
        QVERIFY2(p.waitForStarted(5000), "hub failed to start");
        QVERIFY2(p.waitForFinished(30000), "hub did not exit in time");

        QCOMPARE(p.exitStatus(), QProcess::NormalExit);
        QCOMPARE(p.exitCode(), 0);

        QVERIFY2(QFile::exists(grab), "grab PNG was not written");
        QVERIFY2(QFileInfo(grab).size() > 0, "grab PNG is empty");
        QImage img(grab);
        QVERIFY2(!img.isNull(), "grab PNG is not a valid image");
        QFile::remove(grab);
    }

    void configuredMissingTargetNeverFullscreensPrimary() {
        if (!QA_HOOKS_BUILD)
            QSKIP("hub built without XENEON_QA_HOOKS: bounded process exit is unavailable");

        const QString configRoot = qEnvironmentVariable("XDG_CONFIG_HOME")
                                   + QStringLiteral("/missing-target-startup");
        const QString appConfigDir = configRoot + QStringLiteral("/xeneon-edge-hub");
        QVERIFY(QDir().mkpath(appConfigDir));

        QFile config(appConfigDir + QStringLiteral("/config.toml"));
        QVERIFY(config.open(QIODevice::WriteOnly | QIODevice::Truncate));
        const QByteArray configToml = QByteArrayLiteral(
            "schema_version = 1\n"
            "first_run_complete = true\n"
            "[display]\n"
            "target_edid_hash = \"definitely-not-the-offscreen-display\"\n"
            "target_connector = \"DP-MISSING\"\n"
            "target_model = \"MISSING TARGET\"\n"
            "fallback_behavior = \"ask\"\n"
            "[theme]\n"
            "mode = \"nord\"\n"
            "accent_color = \"#58A6FF\"\n"
            "reduced_motion = false\n"
            "[startup]\n"
            "autostart = false\n"
            "reconnect_on_hotplug = true\n"
            "notify_on_disconnect = true\n"
            "[widgets]\n"
            "version = 1\n"
            "instances = []\n");
        QCOMPARE(config.write(configToml), configToml.size());
        config.close();

        const QString grab = configRoot + QStringLiteral("/missing-target.png");
        QFile::remove(grab);

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert("QT_QPA_PLATFORM", "offscreen");
        env.insert("XDG_CONFIG_HOME", configRoot);
        env.insert("XENEON_GRAB", grab);
        env.insert("XENEON_GRAB_W", "800");
        env.insert("XENEON_GRAB_H", "480");
        env.insert("XENEON_SIMULATE_TARGET_REMOVAL", "1");

        QProcess p;
        p.setProcessEnvironment(env);
        p.setProcessChannelMode(QProcess::MergedChannels);
        p.setProgram(QStringLiteral(HUB_BIN));
        p.start();
        QVERIFY2(p.waitForStarted(5000), "hub failed to start");
        QVERIFY2(p.waitForFinished(30000), "hub did not exit in time");

        const QByteArray log = p.readAll();
        QCOMPARE(p.exitStatus(), QProcess::NormalExit);
        QCOMPARE(p.exitCode(), 0);
        QVERIFY2(log.contains("keeping window hidden and waiting for reconnect"),
                 log.constData());
        QVERIFY2(log.contains("Hub QA simulated target removal; visible: false"),
                 log.constData());
        QVERIFY2(log.contains("Hub: desktop disconnect notice:"), log.constData());
        QVERIFY2(log.contains("Open Xeneon Edge Manager to select a display"),
                 log.constData());
        QVERIFY2(!log.contains("Fullscreen on"), log.constData());
        QFile::remove(grab);

        // The deliberate recovery command remains usable, but it must never
        // turn the missing-target fallback into a fullscreen primary takeover.
        const QString recoveryGrab = configRoot + QStringLiteral("/recovery.png");
        QFile::remove(recoveryGrab);
        env.insert("XENEON_GRAB", recoveryGrab);
        env.remove("XENEON_SIMULATE_TARGET_REMOVAL");

        QProcess recovery;
        recovery.setProcessEnvironment(env);
        recovery.setProcessChannelMode(QProcess::MergedChannels);
        recovery.setProgram(QStringLiteral(HUB_BIN));
        recovery.setArguments({QStringLiteral("--reset-wizard")});
        recovery.start();
        QVERIFY2(recovery.waitForStarted(5000), "recovery hub failed to start");
        QVERIFY2(recovery.waitForFinished(30000), "recovery hub did not exit in time");

        const QByteArray recoveryLog = recovery.readAll();
        QCOMPARE(recovery.exitStatus(), QProcess::NormalExit);
        QCOMPARE(recovery.exitCode(), 0);
        QVERIFY2(recoveryLog.contains("showing windowed recovery on primary screen"),
                 recoveryLog.constData());
        QVERIFY2(!recoveryLog.contains("Fullscreen on"), recoveryLog.constData());
        QFile::remove(recoveryGrab);
    }

    void unreadableConfigurationFlagsFailClosed_data() {
        QTest::addColumn<QString>("argument");
        QTest::newRow("diagnostics") << QStringLiteral("--diagnostics");
        QTest::newRow("safe-mode") << QStringLiteral("--safe-mode");
    }

    void unreadableConfigurationFlagsFailClosed() {
        QFETCH(QString, argument);
        const QString root =
            qEnvironmentVariable("XDG_CONFIG_HOME") + QStringLiteral("/recovery-")
            + argument.mid(2);
        const QString configDir = root + QStringLiteral("/xeneon-edge-hub");
        QVERIFY(QDir().mkpath(configDir));
        const QString configPath = configDir + QStringLiteral("/config.toml");
        const QByteArray futureConfig =
            QByteArrayLiteral("schema_version = 99\nfuture_only = \"KEEP_EXACTLY\"\n");
        QFile config(configPath);
        QVERIFY(config.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QCOMPARE(config.write(futureConfig), futureConfig.size());
        config.close();

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert("QT_QPA_PLATFORM", "offscreen");
        env.insert("XDG_CONFIG_HOME", root);

        QProcess process;
        process.setProcessEnvironment(env);
        process.setProcessChannelMode(QProcess::MergedChannels);
        process.setProgram(QStringLiteral(HUB_BIN));
        process.setArguments({argument});
        process.start();
        QVERIFY2(process.waitForStarted(5000), "hub recovery process failed to start");
        QVERIFY2(process.waitForFinished(10000), "hub recovery process did not exit");

        const QByteArray output = process.readAll();
        QCOMPARE(process.exitStatus(), QProcess::NormalExit);
        QCOMPARE(process.exitCode(), 1);
        QVERIFY2(output.contains("file was left untouched"), output.constData());
        QVERIFY2(output.contains("cannot start Diagnostics or Safe Mode"), output.constData());
        QVERIFY2(output.contains("config.toml.bak"), output.constData());
        QVERIFY2(output.contains("xeneon-edge-hub --reset"), output.constData());

        QFile preserved(configPath);
        QVERIFY(preserved.open(QIODevice::ReadOnly));
        QCOMPARE(preserved.readAll(), futureConfig);
    }
};

QTEST_GUILESS_MAIN(TstSmokeHub)
#include "tst_smoke_hub.moc"

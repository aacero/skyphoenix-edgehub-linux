// Smoke test: launch the REAL manager binary offscreen with XENEON_GRAB → it must
// render, save a non-empty PNG, and exit 0. Exercises main(), the ManagerBackend
// construction/teardown, and the QML load path.
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

class TstSmokeManager : public QObject {
    Q_OBJECT
private slots:
    void grabsAndExitsClean() {
        // See tst_smoke_hub.cpp: XENEON_GRAB is compiled out unless
        // -DXENEON_QA_HOOKS=ON, so without it the manager never exits and this
        // test could only time out. Skip with the real reason.
        if (!QA_HOOKS_BUILD)
            QSKIP("manager built without XENEON_QA_HOOKS: XENEON_GRAB is compiled out, "
                  "so it cannot render-and-exit. Configure -DXENEON_QA_HOOKS=ON.");

        const QString grab = QDir::tempPath() + "/xeneon-smoke-manager.png";
        QFile::remove(grab);

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert("QT_QPA_PLATFORM", "offscreen");
        env.insert("XENEON_GRAB", grab);

        QProcess p;
        p.setProcessEnvironment(env);
        p.setProgram(QStringLiteral(MGR_BIN));
        p.start();
        QVERIFY2(p.waitForStarted(5000), "manager failed to start");
        QVERIFY2(p.waitForFinished(30000), "manager did not exit in time");

        QCOMPARE(p.exitStatus(), QProcess::NormalExit);
        QCOMPARE(p.exitCode(), 0);

        QVERIFY2(QFile::exists(grab), "grab PNG was not written");
        QVERIFY2(QFileInfo(grab).size() > 0, "grab PNG is empty");
        QImage img(grab);
        QVERIFY2(!img.isNull(), "grab PNG is not a valid image");
        QFile::remove(grab);
    }

    void unreadableConfigurationFailsClosedWithUsableRecovery() {
        const QString root =
            qEnvironmentVariable("XDG_CONFIG_HOME") + QStringLiteral("/recovery");
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
        process.setProgram(QStringLiteral(MGR_BIN));
        process.start();
        QVERIFY2(process.waitForStarted(5000), "manager recovery process failed to start");
        QVERIFY2(process.waitForFinished(10000), "manager recovery process did not exit");

        const QByteArray output = process.readAll();
        QCOMPARE(process.exitStatus(), QProcess::NormalExit);
        QCOMPARE(process.exitCode(), 1);
        QVERIFY2(output.contains("file was left untouched"), output.constData());
        QVERIFY2(output.contains("cannot open Diagnostics"), output.constData());
        QVERIFY2(output.contains("config.toml.bak"), output.constData());
        QVERIFY2(output.contains("xeneon-edge-hub --reset"), output.constData());

        QFile preserved(configPath);
        QVERIFY(preserved.open(QIODevice::ReadOnly));
        QCOMPARE(preserved.readAll(), futureConfig);
    }
};

QTEST_GUILESS_MAIN(TstSmokeManager)
#include "tst_smoke_manager.moc"

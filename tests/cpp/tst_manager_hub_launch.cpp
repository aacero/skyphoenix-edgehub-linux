#include <QtTest>

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcessEnvironment>
#include <QSaveFile>
#include <QTemporaryDir>

#include "manager_hub_launch.h"

namespace {

constexpr auto kCaptureArgument = "--capture-hub-environment";
constexpr auto kSentinelName = "XENEON_HUB_LAUNCH_TEST_SENTINEL";

QJsonObject waitForCapture(const QString& path) {
    for (int attempt = 0; attempt < 100; ++attempt) {
        QFile file(path);
        if (file.open(QIODevice::ReadOnly)) {
            const QJsonDocument document =
                QJsonDocument::fromJson(file.readAll());
            if (document.isObject())
                return document.object();
        }
        QTest::qWait(25);
    }
    return {};
}

} // namespace

class TstManagerHubLaunch : public QObject {
    Q_OBJECT

private slots:
    void managerInjectedPlatformIsRemovedFromDetachedHub() {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QString capturePath = directory.filePath(QStringLiteral("injected.json"));

        QProcessEnvironment inherited = QProcessEnvironment::systemEnvironment();
        inherited.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("xcb"));
        inherited.insert(
            QString::fromLatin1(kSentinelName), QStringLiteral("preserved"));

        const HubLaunchCommand command{
            QCoreApplication::applicationFilePath(),
            {QString::fromLatin1(kCaptureArgument), capturePath}};
        QVERIFY(startHubDetached(command, true, inherited));

        const QJsonObject capture = waitForCapture(capturePath);
        QVERIFY2(!capture.isEmpty(), "detached child did not publish its environment");
        QCOMPARE(capture.value(QStringLiteral("platformSet")).toBool(), false);
        QCOMPARE(
            capture.value(QStringLiteral("sentinel")).toString(),
            QStringLiteral("preserved"));
    }

    void userExplicitPlatformIsPreservedForDetachedHub() {
        QTemporaryDir directory;
        QVERIFY(directory.isValid());
        const QString capturePath = directory.filePath(QStringLiteral("explicit.json"));

        QProcessEnvironment inherited = QProcessEnvironment::systemEnvironment();
        inherited.insert(
            QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("wayland"));
        inherited.insert(
            QString::fromLatin1(kSentinelName), QStringLiteral("preserved"));

        const HubLaunchCommand command{
            QCoreApplication::applicationFilePath(),
            {QString::fromLatin1(kCaptureArgument), capturePath}};
        QVERIFY(startHubDetached(command, false, inherited));

        const QJsonObject capture = waitForCapture(capturePath);
        QVERIFY2(!capture.isEmpty(), "detached child did not publish its environment");
        QCOMPARE(
            capture.value(QStringLiteral("platform")).toString(),
            QStringLiteral("wayland"));
        QCOMPARE(capture.value(QStringLiteral("platformSet")).toBool(), true);
        QCOMPARE(
            capture.value(QStringLiteral("sentinel")).toString(),
            QStringLiteral("preserved"));
    }
};

int main(int argc, char** argv) {
    if (argc == 3 && QByteArray(argv[1]) == kCaptureArgument) {
        const QJsonObject capture{
            {QStringLiteral("platformSet"),
             qEnvironmentVariableIsSet("QT_QPA_PLATFORM")},
            {QStringLiteral("platform"),
             qEnvironmentVariable("QT_QPA_PLATFORM")},
            {QStringLiteral("sentinel"),
             qEnvironmentVariable(kSentinelName)}};
        QSaveFile file(QString::fromLocal8Bit(argv[2]));
        if (!file.open(QIODevice::WriteOnly))
            return 2;
        if (file.write(QJsonDocument(capture).toJson(QJsonDocument::Compact))
            < 0) {
            return 3;
        }
        return file.commit() ? 0 : 4;
    }

    QCoreApplication application(argc, argv);
    TstManagerHubLaunch test;
    return QTest::qExec(&test, argc, argv);
}

#include "tst_manager_hub_launch.moc"

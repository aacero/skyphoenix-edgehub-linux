#include <QtTest>

#include "control_socket_path.h"

namespace {

xeneon::ControlSocketFs privateDirectoryFs(const QString& tempPath) {
    xeneon::ControlSocketFs fs;
    fs.tempPath = tempPath;
    fs.uid = 4242;
    fs.makeDir = [](const char*, mode_t) { return 0; };
    fs.statPath = [uid = fs.uid](const char*, struct stat* out) {
        out->st_mode = S_IFDIR | 0700;
        out->st_uid = uid;
        return 0;
    };
    return fs;
}

}  // namespace

class ControlSocketPathTest final : public QObject {
    Q_OBJECT

private slots:
    void runtimePathIsStableAndAbsolute() {
        xeneon::ControlSocketFs fs;
        const QString path = xeneon::controlSocketPathFor(
            QStringLiteral("/run/user/4242"), fs);
        QCOMPARE(path,
                 QStringLiteral("/run/user/4242/xeneon-edge-hub-ctl"));
        QVERIFY(QDir::isAbsolutePath(path));
    }

    void byteLengthBoundaryIsEnforced() {
        QCOMPARE(QFile::encodeName(QString(107, QLatin1Char('a'))).size(), 107);
        QVERIFY(xeneon::controlSocketPathFits(
            QString(107, QLatin1Char('a'))));
        QVERIFY(!xeneon::controlSocketPathFits(
            QString(108, QLatin1Char('a'))));
        QVERIFY(!xeneon::controlSocketPathFits(
            QString(40, QChar(0x20ac))));
    }

    void runtimePathTooLongFailsClosed() {
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: XDG_RUNTIME_DIR yields a path too long.*")));
        const QString path = xeneon::controlSocketPathFor(
            QStringLiteral("/") + QString(110, QLatin1Char('r')),
            xeneon::ControlSocketFs{});
        QVERIFY(path.isEmpty());
    }

    void privateFallbackIsAccepted() {
        const auto fs = privateDirectoryFs(QStringLiteral("/safe"));
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: XDG_RUNTIME_DIR is unset.*")));
        QCOMPARE(
            xeneon::controlSocketPathFor(QString(), fs),
            QStringLiteral("/safe/xeneon-edge-hub-4242/"
                           "xeneon-edge-hub-ctl"));
    }

    void mkdirFailureFailsClosed() {
        auto fs = privateDirectoryFs(QStringLiteral("/blocked"));
        fs.makeDir = [](const char*, mode_t) {
            errno = EACCES;
            return -1;
        };
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: cannot create fallback dir.*Permission denied")));
        QVERIFY(xeneon::controlSocketPathFor(QString(), fs).isEmpty());
    }

    void lstatFailureFailsClosed() {
        auto fs = privateDirectoryFs(QStringLiteral("/vanished"));
        fs.statPath = [](const char*, struct stat*) {
            errno = ENOENT;
            return -1;
        };
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: cannot stat fallback dir.*")));
        QVERIFY(xeneon::controlSocketPathFor(QString(), fs).isEmpty());
    }

    void nonDirectoryFailsClosed() {
        auto fs = privateDirectoryFs(QStringLiteral("/file"));
        fs.statPath = [&fs](const char*, struct stat* out) {
            out->st_mode = S_IFREG | 0600;
            out->st_uid = fs.uid;
            return 0;
        };
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: refusing fallback dir.*not a directory")));
        QVERIFY(xeneon::controlSocketPathFor(QString(), fs).isEmpty());
    }

    void wrongOwnerFailsClosed() {
        auto fs = privateDirectoryFs(QStringLiteral("/other-owner"));
        fs.statPath = [](const char*, struct stat* out) {
            out->st_mode = S_IFDIR | 0700;
            out->st_uid = 9001;
            return 0;
        };
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: refusing fallback dir.*owned by another user")));
        QVERIFY(xeneon::controlSocketPathFor(QString(), fs).isEmpty());
    }

    void unsafePermissionsFailClosed() {
        auto fs = privateDirectoryFs(QStringLiteral("/shared"));
        fs.statPath = [&fs](const char*, struct stat* out) {
            out->st_mode = S_IFDIR | 0750;
            out->st_uid = fs.uid;
            return 0;
        };
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: refusing fallback dir.*access is enabled")));
        QVERIFY(xeneon::controlSocketPathFor(QString(), fs).isEmpty());
    }

    void fallbackPathTooLongFailsClosed() {
        const auto fs =
            privateDirectoryFs(QStringLiteral("/") +
                               QString(90, QLatin1Char('t')));
        QTest::ignoreMessage(
            QtWarningMsg,
            QRegularExpression(QStringLiteral(
                "ControlSocket: fallback path is too long.*")));
        QVERIFY(xeneon::controlSocketPathFor(QString(), fs).isEmpty());
    }
};

QTEST_GUILESS_MAIN(ControlSocketPathTest)
#include "tst_control_socket_path.moc"

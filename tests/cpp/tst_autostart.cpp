// Tests for applyAutostart(): install/remove the XDG autostart .desktop entry,
// with the honest disable return (real QFile::remove result). HOME is redirected
// to a per-test temp dir via the ctest ENVIRONMENT. GUILESS (needs QCoreApplication
// for applicationFilePath()).
#include <QtTest>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <sys/stat.h>
#include <unistd.h>

#include "autostart.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstAutostart : public QObject {
    Q_OBJECT
    QString path_;
private slots:
    void initTestCase() {
        // ConfigLocation, matching the code under test - homePath() was the BUG:
        // it ignores XDG_CONFIG_HOME, so an isolated hub wrote the REAL autostart
        // dir (and cleanup deleted the user's genuine entry). The hermetic harness
        // gives this test a sandboxed XDG_CONFIG_HOME, which is the point.
        path_ = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                + "/autostart/xeneon-edge-hub.desktop";
        QFile::remove(path_);
    }

    // The regression itself: with HOME and XDG_CONFIG_HOME pointing at DIFFERENT
    // places (exactly the escaped-sandbox shape), the entry must land under
    // XDG_CONFIG_HOME and $HOME/.config/autostart must stay untouched.
    void entryFollowsXdgNotHome() {
        const QString homeSide = QDir::homePath() + "/.config/autostart/xeneon-edge-hub.desktop";
        QVERIFY2(homeSide != path_,
                 "hermetic env must diverge HOME from XDG_CONFIG_HOME for this test to bite");
        QFile::remove(homeSide);
        QVERIFY(applyAutostart(true));
        QVERIFY2(QFile::exists(path_), "entry lands under XDG_CONFIG_HOME");
        QVERIFY2(!QFile::exists(homeSide), "and NEVER under $HOME/.config - the escape is closed");
        QVERIFY(applyAutostart(false));
    }
    void cleanup() {
        // Restore write on the entry dir first so a test that dropped permissions
        // (and may have asserted mid-way) doesn't leave a read-only dir behind.
        const QString dir = QFileInfo(path_).absolutePath();
        QFileInfo fi(dir);
        if (fi.exists() && fi.isDir())
            QFile(dir).setPermissions(QFile::ReadUser | QFile::WriteUser | QFile::ExeUser);
        QFile::remove(path_);
    }

    void enableCreatesEntry() {
        const QString directory = QFileInfo(path_).absolutePath();
        QVERIFY(QDir().mkpath(directory));
        QVERIFY(QFile(directory).setPermissions(
            QFileDevice::ReadOwner | QFileDevice::WriteOwner
            | QFileDevice::ExeOwner | QFileDevice::ReadGroup
            | QFileDevice::ExeGroup | QFileDevice::ReadOther
            | QFileDevice::ExeOther));
        QVERIFY(applyAutostart(true));
        QVERIFY(QFile::exists(path_));
        QFile f(path_);
        QVERIFY(f.open(QIODevice::ReadOnly | QIODevice::Text));
        const QByteArray content = f.readAll();
        QCOMPARE(
            content,
            hubAutostartDesktopEntry(QCoreApplication::applicationFilePath()));

        // QFileInfo reports both Qt's Owner and User aliases when the current
        // process owns a Unix file. Assert the actual POSIX mode instead, so a
        // secure 0600 file is not mistaken for group-readable 0660.
        struct stat fileStat {};
        QVERIFY(::stat(QFile::encodeName(path_).constData(), &fileStat) == 0);
        QCOMPARE(static_cast<uint>(fileStat.st_mode & 07777), uint(0600));

        struct stat directoryStat {};
        QVERIFY(
            ::stat(QFile::encodeName(directory).constData(), &directoryStat)
            == 0);
        QCOMPARE(
            static_cast<uint>(directoryStat.st_mode & 07777), uint(0700));
        QCOMPARE(QFileInfo(path_).ownerId(), static_cast<uint>(::geteuid()));
    }

    void managerProgramUsesTheSharedExactEntry() {
        const QString nativeHubProgram =
            QStringLiteral("/opt/SkyPhoenix Edge/bin/xeneon-edge-hub");
        QVERIFY(applyAutostartForProgram(true, nativeHubProgram));

        QFile entry(path_);
        QVERIFY(entry.open(QIODevice::ReadOnly));
        QCOMPARE(entry.readAll(), hubAutostartDesktopEntry(nativeHubProgram));
    }

    void shortWritePreservesPreviousBytes() {
        const QByteArray previous =
            QByteArrayLiteral("previous desktop entry bytes\n");
        QVERIFY(QDir().mkpath(QFileInfo(path_).absolutePath()));
        QFile existing(path_);
        QVERIFY(existing.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QCOMPARE(existing.write(previous), qint64(previous.size()));
        existing.close();

        AutostartAtomicWriteHooks hooks;
        hooks.write = [](QSaveFile& file, const QByteArray& contents) {
            return file.write(contents.constData(), contents.size() - 1);
        };
        QVERIFY(!applyAutostartForProgram(
            true, QStringLiteral("/new/hub"), hooks));

        QVERIFY(existing.open(QIODevice::ReadOnly));
        QCOMPARE(existing.readAll(), previous);
    }

    void commitFailurePreservesPreviousBytes() {
        const QByteArray previous =
            QByteArrayLiteral("another previous desktop entry\n");
        QVERIFY(QDir().mkpath(QFileInfo(path_).absolutePath()));
        QFile existing(path_);
        QVERIFY(existing.open(QIODevice::WriteOnly | QIODevice::Truncate));
        QCOMPARE(existing.write(previous), qint64(previous.size()));
        existing.close();

        AutostartAtomicWriteHooks hooks;
        hooks.commit = [](QSaveFile&) { return false; };
        QVERIFY(!applyAutostartForProgram(
            true, QStringLiteral("/new/hub"), hooks));

        QVERIFY(existing.open(QIODevice::ReadOnly));
        QCOMPARE(existing.readAll(), previous);
    }

    void disableRemovesEntry() {
        QVERIFY(applyAutostart(true));
        QVERIFY(QFile::exists(path_));
        QVERIFY(applyAutostart(false));      // real remove → true
        QVERIFY(!QFile::exists(path_));
    }

    // Disabling a non-existent entry is already "off" → honest success, not a lie
    // about a removal that didn't happen.
    void disableWhenAbsentIsSuccess() {
        QFile::remove(path_);
        QVERIFY(!QFile::exists(path_));
        QVERIFY(applyAutostart(false));
    }

    // Honest return regression: when the removal genuinely fails (parent dir made
    // read-only so unlink is denied), applyAutostart(false) must report false -
    // the hub previously returned true unconditionally on the disable path.
    void disableReturnsRealRemoveResult() {
        if (::geteuid() == 0)
            QSKIP("running as root ignores directory permissions");
        QVERIFY(applyAutostart(true));
        const QString dir = QFileInfo(path_).absolutePath();
        QFile dirFile(dir);
        QVERIFY(dirFile.setPermissions(QFile::ReadUser | QFile::ExeUser));  // drop write
        const bool r = applyAutostart(false);
        // Restore write so cleanup() can delete the file.
        dirFile.setPermissions(QFile::ReadUser | QFile::WriteUser | QFile::ExeUser);
        QVERIFY2(!r, "disable must return the real (failed) remove result");
        QVERIFY(QFile::exists(path_));  // removal really was denied
    }

    // Enable-path failure: when the entry can't be written (dir made read-only so
    // QFile::open fails), applyAutostart(true) must report false, not lie success.
    void enableReturnsFalseWhenDirUnwritable() {
        if (::geteuid() == 0)
            QSKIP("running as root ignores directory permissions");
        const QString dir = QFileInfo(path_).absolutePath();
        QVERIFY(QDir().mkpath(dir));
        QFile::remove(path_);
        QFile dirFile(dir);
        QVERIFY(dirFile.setPermissions(QFile::ReadUser | QFile::ExeUser));  // drop write
        const bool r = applyAutostart(true);
        // Restore write so cleanup() can operate.
        dirFile.setPermissions(QFile::ReadUser | QFile::WriteUser | QFile::ExeUser);
        QVERIFY2(!r, "enable must fail when the entry file can't be opened for write");
        QVERIFY(!QFile::exists(path_));  // nothing was written
    }

    // Exec quoting: a program path containing a space must be double-quoted in the
    // .desktop Exec line (else it parses as multiple arguments); a plain path is left
    // untouched. This is the seam applyAutostart() uses for its Exec= value.
    void execQuotingHandlesSpaces() {
        QCOMPARE(quoteExecForDesktop(QStringLiteral("/usr/bin/xeneon-edge-hub")),
                 QStringLiteral("/usr/bin/xeneon-edge-hub"));
        QCOMPARE(quoteExecForDesktop(QStringLiteral("/opt/My Apps/xeneon-edge-hub")),
                 QStringLiteral("\"/opt/My Apps/xeneon-edge-hub\""));
        // A path with multiple spaces is wrapped exactly once, as a whole.
        QCOMPARE(quoteExecForDesktop(QStringLiteral("/a b/c d/hub")),
                 QStringLiteral("\"/a b/c d/hub\""));
        QCOMPARE(quoteExecForDesktop(QStringLiteral("/opt/Cost $5/Hub")),
                 QStringLiteral("\"/opt/Cost \\$5/Hub\""));
        QCOMPARE(quoteExecForDesktop(QStringLiteral("/opt/100%/Hub")),
                 QStringLiteral("/opt/100%%/Hub"));
        QCOMPARE(quoteExecForDesktop(QStringLiteral("/opt/a\"b/Hub")),
                 QStringLiteral("\"/opt/a\\\"b/Hub\""));
    }

    void appImageUsesPersistentOriginalForAutostart() {
        QTemporaryDir imageDir(
            QStandardPaths::writableLocation(QStandardPaths::TempLocation)
            + QStringLiteral("/Edge Hub AppImage.XXXXXX"));
        QVERIFY(imageDir.isValid());
        const QString imagePath =
            imageDir.filePath(QStringLiteral("EdgeHub $ Candidate.AppImage"));
        QFile image(imagePath);
        QVERIFY(image.open(QIODevice::WriteOnly));
        QCOMPARE(image.write("#!/bin/sh\n"), qint64(10));
        image.close();
        QVERIFY(image.setPermissions(
            QFile::ReadUser | QFile::WriteUser | QFile::ExeUser));

        const bool hadAppImage = qEnvironmentVariableIsSet("APPIMAGE");
        const QByteArray previousAppImage = qgetenv("APPIMAGE");
        qputenv("APPIMAGE", imagePath.toUtf8());
        const HubLaunchCommand command =
            hubLaunchCommand(QStringLiteral("/tmp/.mount-edge/usr/bin/xeneon-edge-hub"));
        const QString execLine = hubAutostartExecLine(
            QStringLiteral("/tmp/.mount-edge/usr/bin/xeneon-edge-hub"));
        const QByteArray expectedEntry = hubAutostartDesktopEntry(
            QStringLiteral("/tmp/.mount-edge/usr/bin/xeneon-edge-hub"));
        const bool applied = applyAutostart(true);
        QFile entry(path_);
        const bool opened = entry.open(QIODevice::ReadOnly | QIODevice::Text);
        const QString contents =
            opened ? QString::fromUtf8(entry.readAll()) : QString();
        entry.close();
        if (hadAppImage)
            qputenv("APPIMAGE", previousAppImage);
        else
            qunsetenv("APPIMAGE");

        QVERIFY(applied);
        QVERIFY(opened);
        QCOMPARE(command.program, imagePath);
        QCOMPARE(command.arguments, QStringList{QStringLiteral("--hub")});
        QCOMPARE(execLine,
                 quoteExecForDesktop(imagePath) + QStringLiteral(" --hub"));
        QVERIFY(contents.contains(QStringLiteral("Exec=") + execLine + u'\n'));
        QCOMPARE(contents.toUtf8(), expectedEntry);
    }
};

QTEST_GUILESS_MAIN(TstAutostart)
#include "tst_autostart.moc"

#include <QCoreApplication>
#include <QObject>
#include <QtQuickTest/quicktest.h>

// The complete shipped Hub and Manager resource collections are linked into this
// executable by CMake. Product QML is still loaded from the committed source-tree
// imports selected by each test, while every qrc URL resolves exactly as it does
// in the packaged binaries. Stock qmltestrunner has none of these resources,
// which made image and rendered-pixel assertions vacuous.
class XeneonQuickTestSetup final : public QObject
{
    Q_OBJECT

public slots:
    void applicationAvailable()
    {
        QCoreApplication::setOrganizationName(QStringLiteral("SkyPhoenix"));
        QCoreApplication::setOrganizationDomain(QStringLiteral("skyphoenix.eu"));
        QCoreApplication::setApplicationName(QStringLiteral("xeneon-edge-tests"));
    }
};

QUICK_TEST_MAIN_WITH_SETUP(xeneon_gui, XeneonQuickTestSetup)

#include "runner.moc"

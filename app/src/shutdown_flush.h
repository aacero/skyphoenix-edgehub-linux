#pragma once

#include <QList>
#include <QMetaObject>
#include <QObject>
#include <QVariant>

namespace xeneon {

struct ShutdownFlushResult {
    int invoked = 0;
    int failed = 0;

    bool ok() const { return invoked > 0 && failed == 0; }
};

// Ask each QML root that implements flushPendingUiState() to commit pending
// widget editor buffers and its DashboardStore while the persistence bridge is
// still attached. Roots without that method are ignored so diagnostics or
// alternate test shells cannot turn shutdown into a crash.
inline ShutdownFlushResult flushPendingUiState(const QList<QObject*>& roots)
{
    ShutdownFlushResult result;
    for (QObject* root : roots) {
        if (!root)
            continue;
        QVariant returned;
        if (!QMetaObject::invokeMethod(root, "flushPendingUiState",
                                       Qt::DirectConnection,
                                       Q_RETURN_ARG(QVariant, returned)))
            continue;
        ++result.invoked;
        if (!returned.toBool())
            ++result.failed;
    }
    return result;
}

} // namespace xeneon

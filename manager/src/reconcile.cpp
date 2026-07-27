#include "reconcile.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>

namespace {

bool jsonValuesEqual(const QJsonValue& left, const QJsonValue& right) {
    if (left.type() != right.type())
        return false;

    if (left.isArray()) {
        const QJsonArray leftArray = left.toArray();
        const QJsonArray rightArray = right.toArray();
        if (leftArray.size() != rightArray.size())
            return false;
        for (qsizetype i = 0; i < leftArray.size(); ++i) {
            if (!jsonValuesEqual(leftArray.at(i), rightArray.at(i)))
                return false;
        }
        return true;
    }

    if (left.isObject()) {
        const QJsonObject leftObject = left.toObject();
        const QJsonObject rightObject = right.toObject();
        if (leftObject.size() != rightObject.size())
            return false;
        for (auto it = leftObject.constBegin(); it != leftObject.constEnd(); ++it) {
            const auto rightIt = rightObject.constFind(it.key());
            if (rightIt == rightObject.constEnd()
                || !jsonValuesEqual(it.value(), rightIt.value())) {
                return false;
            }
        }
        return true;
    }

    return left == right;
}

bool uiStatesEqual(const QString& left, const QString& right) {
    if (left == right)
        return true;

    QJsonParseError leftError;
    QJsonParseError rightError;
    const QJsonDocument leftDocument =
        QJsonDocument::fromJson(left.toUtf8(), &leftError);
    const QJsonDocument rightDocument =
        QJsonDocument::fromJson(right.toUtf8(), &rightError);
    if (leftError.error != QJsonParseError::NoError
        || rightError.error != QJsonParseError::NoError
        || leftDocument.isNull() || rightDocument.isNull()) {
        return false;
    }

    if (leftDocument.isObject() && rightDocument.isObject()) {
        return jsonValuesEqual(QJsonValue(leftDocument.object()),
                               QJsonValue(rightDocument.object()));
    }
    if (leftDocument.isArray() && rightDocument.isArray()) {
        return jsonValuesEqual(QJsonValue(leftDocument.array()),
                               QJsonValue(rightDocument.array()));
    }
    return false;
}

} // namespace

ReconcileAction reconcileOnPull(bool awaitingHub, bool havePendingPush,
                                const QString& pulled, const QString& lastHub,
                                bool suppressed) {
    if (awaitingHub) {
        // The hub changed while we were offline only if it now reports a non-empty
        // state that differs semantically from the last one we knew it held.
        const bool hubChanged =
            !pulled.isEmpty() && !lastHub.isEmpty() && !uiStatesEqual(pulled, lastHub);
        if (hubChanged)
            return havePendingPush ? ReconcileAction::RequireConflict
                                   : ReconcileAction::AdoptHub;
        // Empty baseline: we have NO prior successfully-pulled hub state (first run, or
        // the socket never completed a pull before), yet the hub now reports a NON-EMPTY
        // state. We cannot prove our buffered offline edit is newer than what's actually
        // on the device. Neither document may be silently chosen. Preserve the
        // buffered edit and require an explicit Retry or Discard decision.
        // An empty pull carries nothing to clobber, so there we keep our edit.
        if (lastHub.isEmpty() && !pulled.isEmpty())
            return havePendingPush ? ReconcileAction::RequireConflict
                                   : ReconcileAction::AdoptHub;
        if (havePendingPush)
            return ReconcileAction::KeepAndPushEdit;
    }
    if (suppressed)
        return ReconcileAction::Ignore;
    return ReconcileAction::AdoptHub;
}

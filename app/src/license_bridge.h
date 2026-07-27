#pragma once

#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QString>

#include "config_transaction.h"
#include "xeneon_core.h"
#include "xeneon_string.h"

// --- LicenseBridge: the tier, exposed to QML, live ---
//
// Wraps the hub's ConfigHandle and answers the only question the UI ever asks -
// "am I Pro?" - reactively, so a key pasted in the Manager (pushed over the
// control socket) re-gates premium features WITHOUT a restart. Verification is
// the Rust path (`xeneon_config_license_status_json`): offline, fails-soft, and
// identical to the pasted-key verify (they share `Status::to_json`), so a stored
// key and a freshly-entered one can never disagree.
//
// `isPro` is what QML GATES ON. `state`/`issuedTo`/`expires` are for WORDING only
// (e.g. "expired - renew" vs "free"). None of these grant anything on their own;
// the entitlement is always recomputed from the signed key, never trusted from a
// stored boolean.
class LicenseBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool isPro READ isPro NOTIFY changed)
    Q_PROPERTY(QString tier READ tier NOTIFY changed)
    Q_PROPERTY(QString state READ state NOTIFY changed)
    Q_PROPERTY(QString issuedTo READ issuedTo NOTIFY changed)
    Q_PROPERTY(double expires READ expires NOTIFY changed)  // Unix seconds, 0 = none
    Q_PROPERTY(bool hasKey READ hasKey NOTIFY changed)

public:
    explicit LicenseBridge(ConfigHandle* config, QObject* parent = nullptr)
        : QObject(parent), m_config(config) {
        refresh();
    }

    bool isPro() const { return m_tier == QLatin1String("pro"); }
    QString tier() const { return m_tier; }
    QString state() const { return m_state; }
    QString issuedTo() const { return m_issuedTo; }
    double expires() const { return m_expires; }
    bool hasKey() const { return m_hasKey; }

    // Verify a candidate key WITHOUT storing it - for the dialog to preview
    // "this key unlocks Pro for <name>" (or "expired"/"not a valid key") before
    // the user commits. Returns the same JSON shape as the status properties.
    Q_INVOKABLE QString verifyCandidate(const QString& key) const {
        XeneonString js(xeneon_license_verify_json(key.toUtf8().constData()));
        return js.qstring();
    }

    // Persist a key (or clear it with an empty string) and re-evaluate the tier.
    // This is the HUB-OWNS-CONFIG path: the hub writes its own config directly.
    // The Manager, which must not race the hub's writer, goes through IPC
    // instead (ManagerBackend::setLicenseKey) - that lands here on the hub via
    // applyExternalKey(). Returns whether the persist succeeded.
    Q_INVOKABLE bool setKey(const QString& key) {
        if (!m_config) return false;
        ConfigTransaction transaction(m_config);
        if (!transaction)
            return false;
        const QByteArray utf8 = key.toUtf8();
        if (xeneon_config_set_license_key(
                transaction.candidate(),
                key.isEmpty() ? nullptr : utf8.constData()) != 0)
            return false;
        const bool ok = transaction.commit();
        if (ok) {
            if (transaction.durabilityUncertain())
                emit persistenceWarning(QStringLiteral(
                    "The licence was published, but storage could not confirm crash durability."));
            refresh();
        }
        return ok;
    }

    Q_INVOKABLE bool clear() { return setKey(QString()); }

    // A key pushed from the Manager over the control socket: persist + refresh,
    // exactly like setKey but named for the call site so intent is explicit (and
    // so a future audit can see every place the tier can change).
    bool applyExternalKey(const QString& key) { return setKey(key); }

    // Re-read the effective entitlement from the stored key. Called on
    // construction, after any set, and whenever the config is reloaded.
    void refresh() {
        QString tier = QStringLiteral("free");
        QString state = QStringLiteral("unlicensed");
        QString issuedTo;
        double expires = 0;
        bool hasKey = false;

        if (m_config) {
            XeneonString keyStr(xeneon_config_get_license_key(m_config));
            hasKey = !keyStr.isNull() && !keyStr.qstring().isEmpty();
            XeneonString js(xeneon_config_license_status_json(m_config));
            const QJsonObject o =
                QJsonDocument::fromJson(js.qstring().toUtf8()).object();
            tier = o.value(QStringLiteral("tier")).toString(QStringLiteral("free"));
            state =
                o.value(QStringLiteral("state")).toString(QStringLiteral("unlicensed"));
            issuedTo = o.value(QStringLiteral("issuedTo")).toString();
            // `expires` is a JSON number or null.
            const QJsonValue exp = o.value(QStringLiteral("expires"));
            expires = exp.isDouble() ? exp.toDouble() : 0;
        }

        const bool moved = tier != m_tier || state != m_state ||
                           issuedTo != m_issuedTo || expires != m_expires ||
                           hasKey != m_hasKey;
        m_tier = tier;
        m_state = state;
        m_issuedTo = issuedTo;
        m_expires = expires;
        m_hasKey = hasKey;
        if (moved) emit changed();
    }

signals:
    void changed();
    void persistenceWarning(const QString& message);

private:
    ConfigHandle* m_config = nullptr;
    QString m_tier = QStringLiteral("free");
    QString m_state = QStringLiteral("unlicensed");
    QString m_issuedTo;
    double m_expires = 0;
    bool m_hasKey = false;
};

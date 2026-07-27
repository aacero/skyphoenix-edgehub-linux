// E9 managed/org policy: ConfigBridge::policy() + the xeneon_policy_json FFI
// against the REAL Rust core, driven entirely through the XENEON_POLICY_PATH
// test seam (never the real /etc - a real deployment relies on /etc being
// root-owned; the env override exists precisely so tests don't touch it).
#include <QtTest>
#include <QFile>
#include <QTemporaryDir>
#include <QVariantMap>

#include "config_bridge.h"
#include "xeneon_core.h"

// Refuse to run outside a sandbox: these tests link the real core. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstPolicy : public QObject {
    Q_OBJECT
    QTemporaryDir dir_;

    QString writePolicy(const char* name, const QByteArray& contents) {
        const QString p = dir_.filePath(QString::fromLatin1(name));
        QFile f(p);
        if (!f.open(QIODevice::WriteOnly)) return QString();
        f.write(contents);
        f.close();
        return p;
    }

private slots:
    void initTestCase() { QVERIFY(dir_.isValid()); }
    void cleanup() { qunsetenv("XENEON_POLICY_PATH"); }

    // No policy file → inactive, every field at its permissive default. This is
    // the "default behaviour unchanged" half of the contract: an unmanaged box
    // must see exactly what it saw before E9.
    void absentPolicyIsInactive() {
        qputenv("XENEON_POLICY_PATH", dir_.filePath("does-not-exist.toml").toUtf8());
        ConfigBridge b(nullptr);
        const QVariantMap p = b.policy();
        QCOMPARE(p["active"].toBool(), false);
        QCOMPARE(p["source"].toString(), QStringLiteral("absent"));
        QCOMPARE(p["netOffline"].toBool(), false);
        QCOMPARE(p["disableUserWidgets"].toBool(), false);
        QVERIFY(p["forcePreset"].toString().isEmpty());
        QVERIFY(p["allowedHosts"].toList().isEmpty());
        QVERIFY(p["disabledWidgetTypes"].toList().isEmpty());
    }

    // A well-formed policy is exposed field-for-field.
    void validPolicyIsExposed() {
        const QString path = writePolicy("valid.toml",
            "policy_version = 1\n"
            "force_preset = \"remote-work\"\n"
            "net_offline = true\n"
            "allowed_hosts = [\"api.internal.example\", \"metrics.internal.example\"]\n"
            "disable_user_widgets = true\n"
            "disable_widget_types = [\"httpjson\", \"kpi\"]\n");
        QVERIFY(!path.isEmpty());
        qputenv("XENEON_POLICY_PATH", path.toUtf8());

        ConfigBridge b(nullptr);
        const QVariantMap p = b.policy();
        QCOMPARE(p["active"].toBool(), true);
        QCOMPARE(p["source"].toString(), QStringLiteral("policy"));
        QCOMPARE(p["forcePreset"].toString(), QStringLiteral("remote-work"));
        QCOMPARE(p["netOffline"].toBool(), true);
        const QVariantList hosts = p["allowedHosts"].toList();
        QCOMPARE(hosts.size(), 2);
        QCOMPARE(hosts[0].toString(), QStringLiteral("api.internal.example"));
        QCOMPARE(p["disableUserWidgets"].toBool(), true);
        const QVariantList types = p["disabledWidgetTypes"].toList();
        QCOMPARE(types.size(), 2);
        QCOMPARE(types[0].toString(), QStringLiteral("httpjson"));
    }

    // The fail-closed core: a policy the org WROTE but this build cannot use is
    // never silently ignored - the restrictive interpretation applies.
    void corruptPolicyFailsClosed() {
        const QString path = writePolicy("corrupt.toml", "not = = toml at all");
        qputenv("XENEON_POLICY_PATH", path.toUtf8());
        ConfigBridge b(nullptr);
        const QVariantMap p = b.policy();
        QCOMPARE(p["active"].toBool(), true);
        QCOMPARE(p["source"].toString(), QStringLiteral("fail-closed"));
        QVERIFY(!p["reason"].toString().isEmpty());
        QCOMPARE(p["netOffline"].toBool(), true);
        QCOMPARE(p["disableUserWidgets"].toBool(), true);
        QVERIFY(p["forcePreset"].toString().isEmpty());
    }

    // A typo'd key must not load as a WEAKER policy than the org wrote.
    void unknownKeyFailsClosed() {
        const QString path = writePolicy("typo.toml",
            "policy_version = 1\nallowed_host = [\"api.internal.example\"]\n");
        qputenv("XENEON_POLICY_PATH", path.toUtf8());
        ConfigBridge b(nullptr);
        const QVariantMap p = b.policy();
        QCOMPARE(p["source"].toString(), QStringLiteral("fail-closed"));
        QCOMPARE(p["netOffline"].toBool(), true);
    }

    // A future schema version cannot be interpreted → fail closed, not fail open.
    void futureVersionFailsClosed() {
        const QString path = writePolicy("v99.toml", "policy_version = 99\n");
        qputenv("XENEON_POLICY_PATH", path.toUtf8());
        ConfigBridge b(nullptr);
        const QVariantMap p = b.policy();
        QCOMPARE(p["source"].toString(), QStringLiteral("fail-closed"));
        QCOMPARE(p["netOffline"].toBool(), true);
        QCOMPARE(p["disableUserWidgets"].toBool(), true);
    }

    // The fail-closed reason must name the failure mode WITHOUT echoing file
    // contents - allowed_hosts values are internal infrastructure names.
    void failClosedReasonNeverEchoesHostValues() {
        const QString path = writePolicy("hosts-typo.toml",
            "policy_version = 1\n"
            "allowed_host = [\"SECRET-INTERNAL-HOST.example\"]\n");
        qputenv("XENEON_POLICY_PATH", path.toUtf8());
        ConfigBridge b(nullptr);
        const QString reason = b.policy()["reason"].toString();
        QVERIFY(!reason.isEmpty());
        QVERIFY2(!reason.contains("SECRET-INTERNAL-HOST"),
                 qPrintable("fail-closed reason leaked a host value: " + reason));
    }

    // policy() is independent of the user-config handle: a detached/null bridge
    // still answers (policy comes from /etc, not from config.toml).
    void policyIndependentOfConfigHandle() {
        const QString path = writePolicy("independent.toml",
            "policy_version = 1\nnet_offline = true\n");
        qputenv("XENEON_POLICY_PATH", path.toUtf8());
        ConfigBridge b(nullptr);   // no ConfigHandle at all
        const QVariantMap p = b.policy();
        QCOMPARE(p["active"].toBool(), true);
        QCOMPARE(p["netOffline"].toBool(), true);
    }

    // The bridge caches per instance (the file is static per launch): the map
    // handed out after the file changes is the one read first.
    void policyIsCachedPerBridgeInstance() {
        const QString path = writePolicy("cached.toml",
            "policy_version = 1\nnet_offline = true\n");
        qputenv("XENEON_POLICY_PATH", path.toUtf8());
        ConfigBridge b(nullptr);
        QCOMPARE(b.policy()["netOffline"].toBool(), true);
        // Rewrite the file more permissively; the cached answer must not weaken.
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write("policy_version = 1\nnet_offline = false\n");
        f.close();
        QCOMPARE(b.policy()["netOffline"].toBool(), true);
    }

    void forcedPresetRejectsExternalLayoutWithoutChangingOneByte() {
        const QString policyPath = writePolicy(
            "forced-layout.toml",
            "policy_version = 1\n"
            "force_preset = \"remote-work\"\n");
        QVERIFY(!policyPath.isEmpty());
        qputenv("XENEON_POLICY_PATH", policyPath.toUtf8());

        ConfigHandle* config = xeneon_config_load();
        QVERIFY(config);
        const QByteArray current(
            "{\"version\":1,\"pages\":[],\"marker\":\"managed-current\"}");
        const QByteArray pushed(
            "{\"version\":1,\"pages\":[],\"marker\":\"manager-push\"}");
        QCOMPARE(
            xeneon_config_set_ui_state(config, current.constData()), 0);
        QVERIFY(xeneon_config_save(config) >= 0);

        char* directoryRaw = xeneon_config_dir();
        QVERIFY(directoryRaw);
        const QString configPath =
            QString::fromUtf8(directoryRaw) + QStringLiteral("/config.toml");
        xeneon_string_free(directoryRaw);
        QFile file(configPath);
        QVERIFY(file.open(QIODevice::ReadOnly));
        const QByteArray before = file.readAll();
        file.close();

        ConfigBridge bridge(config);
        QVERIFY(!bridge.externalUiStateAllowed());
        QVERIFY(!bridge.applyExternalUiState(QString::fromUtf8(pushed)));
        QCOMPARE(bridge.uiState(), QString::fromUtf8(current));
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), before);
        xeneon_config_free(config);
    }

    // Raw FFI contract: never null, always parseable JSON.
    void rawFfiNeverReturnsNull() {
        qputenv("XENEON_POLICY_PATH", dir_.filePath("nope.toml").toUtf8());
        char* s = xeneon_policy_json();
        QVERIFY(s != nullptr);
        const QJsonDocument doc = QJsonDocument::fromJson(QByteArray(s));
        QVERIFY(doc.isObject());
        xeneon_string_free(s);
    }
};

QTEST_GUILESS_MAIN(TstPolicy)
#include "tst_policy.moc"

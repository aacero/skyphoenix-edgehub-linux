#pragma once

#include <QJsonDocument>
#include <QJsonObject>
#include <QDateTime>
#include <QObject>
#include <QString>
#include <QThread>
#include <QTimer>
#include <QVariantMap>
#include <memory>

#include "xeneon_core.h"

// ─────────────────────────────────────────────────────────────────────────────
// DistroBridge - the distro's identity, installed-package count and install date
// for QML, resolved by the Rust core (core/src/distro.rs).
//
// QML cannot do any of this: it has no filesystem read, no directory listing and
// no way to reach /etc/os-release. The whole answer therefore comes over the FFI
// as one JSON blob.
//
// THREADING. The probe is filesystem work, and on a dpkg system it parses
// /var/lib/dpkg/status - ~10 MB of text on a full desktop, tens of milliseconds.
// That is several dropped frames if it lands on the GUI thread, so the probe runs
// on a worker thread (the same shape as MetricsWorker) and the result is pushed
// back as a queued signal. Nothing here ever touches the filesystem on the GUI
// thread.
//
// CACHING. Unlike metrics, this answer is nearly static - a package count changes
// when the user installs something, and an install date never changes at all.
// So: probe ONCE at construction, then refresh on a long timer (kRefreshMs) and
// on an explicit refresh(). Polling this every 2s like metrics would be pure
// waste (a 10 MB re-parse for a number that changes weekly).
//
// Until the first probe lands, `ready` is false and `info` is empty - widgets
// must render a placeholder rather than a zero. See PackagesWidget.qml.
// ─────────────────────────────────────────────────────────────────────────────

// Runs the probe. Lives on the worker thread; owns no state beyond the root.
class DistroProbeWorker : public QObject {
    Q_OBJECT

    // RAII for the FFI string, scoped to this class ON PURPOSE.
    //
    // app/src/xeneon_string.h looks like the right include, but this header is
    // pulled into BOTH apps and manager_backend.h defines its own `XeneonString`
    // - including the shared one here is a hard redefinition error in the
    // Manager's TU. Keeping the helper class-scoped adds no global name to
    // either app, so neither can collide with it.
    struct FreeCString {
        void operator()(char* p) const { xeneon_string_free(p); }   // null-safe
    };
    using OwnedString = std::unique_ptr<char, FreeCString>;

public slots:
    // `root` is "" for the real system, or a fixture tree in tests. It is echoed
    // back with the result so the bridge can drop a stale answer - see _onProbed.
    void probe(const QString& root) {
        const QByteArray r = root.toUtf8();
        OwnedString s(xeneon_distro_probe_json(root.isEmpty() ? nullptr : r.constData()));
        emit done(root, s ? QString::fromUtf8(s.get()) : QString());
    }
signals:
    void done(const QString& root, const QString& json);
};

class DistroBridge : public QObject {
    Q_OBJECT
    // One map, not a property per field: the fields are meaningless apart (a
    // count without its family is unreadable) and they always change together.
    Q_PROPERTY(QVariantMap info READ info NOTIFY infoChanged)
    // False until the first probe returns. QML keys its placeholder off this -
    // an empty map and "0 packages" must never be confusable.
    Q_PROPERTY(bool ready READ ready NOTIFY infoChanged)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY infoChanged)
    Q_PROPERTY(qint64 refreshedAtMs READ refreshedAtMs NOTIFY infoChanged)

public:
    // The probe is cheap-ish but not free, and the answer changes on the order of
    // days. 15 minutes keeps a fresh count visible after an install without
    // re-parsing dpkg's status file for no reason.
    static constexpr int kRefreshMs = 15 * 60 * 1000;

    explicit DistroBridge(QObject* parent = nullptr) : QObject(parent) {
        m_worker = new DistroProbeWorker;
        m_worker->moveToThread(&m_thread);
        // The worker is parentless and lives on m_thread, so it must be destroyed
        // BY that thread - deleteLater on finished() is the only safe point.
        connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
        connect(this, &DistroBridge::_requestProbe, m_worker, &DistroProbeWorker::probe);
        connect(m_worker, &DistroProbeWorker::done, this, &DistroBridge::_onProbed);
        m_thread.start();

        m_timer.setInterval(kRefreshMs);
        connect(&m_timer, &QTimer::timeout, this, &DistroBridge::refresh);
        m_timer.start();

        refresh();   // first answer as soon as the thread picks it up
    }

    ~DistroBridge() override {
        m_thread.quit();
        // A probe in flight is bounded filesystem work, so this returns promptly;
        // the wait is what guarantees the worker is gone before we are.
        m_thread.wait();
    }

    QVariantMap info() const { return m_info; }
    bool ready() const { return m_ready; }
    bool refreshing() const { return m_refreshing; }
    qint64 refreshedAtMs() const { return m_refreshedAtMs; }

    // Which root actually produced the current `info`. Distinct from the root we
    // last ASKED for: after setRoot() the old answer is still published until the
    // new probe lands. Tests wait on this; production never changes root.
    QString probedRoot() const { return m_probedRoot; }

    // Re-probe. Safe to call at any time: the result simply replaces the cache.
    Q_INVOKABLE void refresh() {
        m_refreshing = true;
        emit infoChanged();
        emit _requestProbe(m_root);
    }

    // Root the probe at a fixture tree instead of "/". FOR TESTS - it lets the
    // C++ suite assert real behaviour against crafted /etc + /var trees without
    // depending on (or touching) the host's. Triggers a re-probe.
    void setRoot(const QString& root) {
        m_root = root;
        refresh();
    }

signals:
    void infoChanged();
    // Internal: hops onto the worker thread. Not for QML.
    void _requestProbe(const QString& root);

private slots:
    void _onProbed(const QString& root, const QString& json) {
        // Drop an answer for a root we are no longer asking about. Probes are
        // queued, so a setRoot() issued while one is in flight would otherwise
        // let the OLD result land second and overwrite the new one. (Caught by
        // the C++ suite on the dev box, where the fixture and the real system are
        // both `id=cachyos` and the stale answer looked entirely plausible.)
        if (root != m_root) return;

        const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
        // A malformed/absent blob must leave the widget in its "unknown" state
        // rather than half-populated - so only a real object is published.
        if (doc.isObject()) {
            m_info = doc.object().toVariantMap();
            m_probedRoot = root;
            m_ready = true;
            m_refreshedAtMs = QDateTime::currentMSecsSinceEpoch();
        }
        m_refreshing = false;
        emit infoChanged();
    }

private:
    QThread m_thread;
    DistroProbeWorker* m_worker = nullptr;
    QTimer m_timer;
    QVariantMap m_info;
    QString m_root;         // "" = the real system - the root we are ASKING about
    QString m_probedRoot;   // the root that produced m_info
    bool m_ready = false;
    bool m_refreshing = false;
    qint64 m_refreshedAtMs = 0;
};

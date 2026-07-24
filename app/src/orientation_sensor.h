#pragma once

#include <QObject>
#include <QList>
#include <QString>
#include <QTimer>

class QSocketNotifier;

// OrientationSensor - reads the Corsair Xeneon Edge's orientation from its vendor
// HID pipe (/dev/hidrawN, vendor 1b1c product 1d0d). The Edge pushes an unsolicited
// 64-byte report whenever the panel is rotated; byte 7 carries the orientation:
//   0x03 = portrait (upright)   0x00 = +90° CW    0x01 = 180°   0x02 = -90° CW
// which we map to the content rotation (degrees, clockwise) that keeps the UI
// upright. Requires read access to the hidraw node (see the 99-xeneon-edge udev
// rule); if the node is missing or unreadable the sensor simply stays inactive.
class OrientationSensor : public QObject {
    Q_OBJECT
public:
    explicit OrientationSensor(QObject* parent = nullptr);
    ~OrientationSensor() override;

    // Locate + open the Edge hidraw node and begin watching it. Returns true if
    // the device was opened and is being read.
    bool start();
    bool active() const { return m_fd >= 0; }

    // Current content rotation (0/90/180/270), or -1 if unknown/no reading yet.
    int rotation() const { return m_rotation; }

    // Map an orientation byte (report[7]) to a content rotation, or -1 if unknown.
    //   0x03→0, 0x00→270, 0x01→180, 0x02→90, else→-1
    // Public + static so it can be unit-tested without opening a hidraw node.
    static int byteToRotation(unsigned char b);

    // ── Test seams (no hardware) ──
    // Open + watch an arbitrary path (e.g. a FIFO) as if it were the Edge hidraw
    // node, so the read/EOF/error → retry-timer path can be exercised headlessly.
    bool openForTest(const QString& path) { return openAndWatch(path); }
    // Whether the reopen retry timer is currently armed (device-lost recovery).
    bool retryActiveForTest() const { return m_retry.isActive(); }
    // Startup acquisition is deliberately separate from the unplug/reopen timer:
    // a remembered rotation may render immediately, but must never suppress
    // bounded GET_REPORT retries for the panel's current physical state.
    bool startupRetryActiveForTest() const { return m_startupRetry.isActive(); }
    int startupAttemptCountForTest() const { return m_startupAttemptCount; }
    bool hasDeviceReadingForTest() const { return m_hasDeviceReading; }
    void setStartupRetryScheduleForTest(const QList<int>& delays) {
        m_startupRetryDelays = delays;
    }

    // Remember the last orientation across runs. Some panels answer no GET_REPORT
    // and only push a report on physical *change*, so a restart would otherwise
    // start mis-rotated until the user turns the panel. With a state file, a restart
    // restores the last-seen orientation immediately. Set before start().
    void setStatePath(const QString& path) { m_statePath = path; }

signals:
    void rotationChanged(int rotation);

private slots:
    void onReadable();
    // Poll for the device coming back after an unplug and re-open it transparently.
    void tryReopen();
    void onStartupRetry();

private:
    // Open the hidraw node, wire up the notifier, and seed the initial orientation.
    bool openAndWatch(const QString& path);
    // Disable the notifier + close the fd (on a fatal read error / device unplug),
    // so QSocketNotifier stops re-firing on a hung-up fd (which would busy-loop).
    void stopWatching();
    // stopWatching() + arm the reopen timer, for the device-lost (unplug) case.
    void handleDeviceLost();
    // Actively query the current orientation during the bounded startup window.
    // Returns true only for a real HID result, never for persisted fallback.
    bool queryInitialOrientation();
    void scheduleStartupRetry();
    void applyDeviceRotation(int rot);
    // Adopt a rotation: update m_rotation, emit, and persist it (single path so
    // every source - GET_REPORT, a pushed report, or the restored state - is saved).
    void applyRotation(int rot);
    // Persist / restore the last orientation to m_statePath (a plain integer file).
    void persistRotation() const;
    int restorePersistedRotation() const;   // -1 if none/unreadable
    // Scan /sys/class/hidraw for the Edge; returns "/dev/hidrawN" or empty.
    static QString findEdgeHidraw();

    int m_fd = -1;
    int m_rotation = -1;
    QString m_statePath;   // where the last orientation is remembered across runs
    QSocketNotifier* m_notifier = nullptr;
    QTimer m_retry;   // polls for the hidraw node to reappear after an unplug
    QTimer m_startupRetry;
    QList<int> m_startupRetryDelays{250, 500, 750, 1000, 1500};
    int m_startupRetryIndex = 0;
    int m_startupAttemptCount = 0;
    bool m_hasDeviceReading = false;
};

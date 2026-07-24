#include "orientation_sensor.h"

#include <QSocketNotifier>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QRegularExpression>
#include <QTimer>
#include <QDebug>

#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <sys/ioctl.h>
#include <linux/hidraw.h>

OrientationSensor::OrientationSensor(QObject* parent) : QObject(parent) {
    // Poll timer used only after an unplug, to re-open the node when it returns.
    m_retry.setInterval(3000);
    connect(&m_retry, &QTimer::timeout, this, &OrientationSensor::tryReopen);
    m_startupRetry.setSingleShot(true);
    connect(&m_startupRetry, &QTimer::timeout, this, &OrientationSensor::onStartupRetry);
}

// GCOVR_EXCL_START (dtor teardown of a live hidraw fd/notifier; the FIFO test tears
// down via EOF before destruction, so these hardware-cleanup branches aren't taken).
OrientationSensor::~OrientationSensor() {
    if (m_notifier) {
        m_notifier->setEnabled(false);
        delete m_notifier;
    }
    if (m_fd >= 0)
        ::close(m_fd);
}
// GCOVR_EXCL_STOP

// GCOVR_EXCL_START (hardware: scans /sys/class/hidraw for the Corsair Xeneon Edge -
// no such device in headless CI; the open/read/EOF path is tested via a FIFO seam).
QString OrientationSensor::findEdgeHidraw() {
    // The kernel exposes each hidraw as /sys/class/hidraw/hidrawN with a
    // device/uevent carrying HID_ID=BUS:VVVVVVVV:PPPPPPPP. Match Corsair 1b1c /
    // Xeneon Edge 1d0d (hex, uppercase in uevent).
    // Match the exact HID_ID vendor:product field (e.g. HID_ID=0003:00001B1C:00001D0D)
    // rather than loose substrings anywhere in the uevent: two independent
    // "contains" checks could both hit on an unrelated device whose numbers merely
    // happen to include 1B1C and 1D0D somewhere, or on a Corsair device with a
    // different product id. Anchoring on HID_ID=<bus>:<vid>:<pid> ties them together.
    static const QRegularExpression hidIdRe(
        QStringLiteral("HID_ID=[0-9A-F]+:0*1B1C:0*1D0D"),
        QRegularExpression::CaseInsensitiveOption);
    QDir dir(QStringLiteral("/sys/class/hidraw"));
    const auto entries = dir.entryList(QStringList{QStringLiteral("hidraw*")}, QDir::Dirs | QDir::NoDotAndDotDot);
    for (const QString& name : entries) {
        QFile uevent(QStringLiteral("/sys/class/hidraw/") + name + QStringLiteral("/device/uevent"));
        if (!uevent.open(QIODevice::ReadOnly | QIODevice::Text))
            continue;
        const QString text = QString::fromUtf8(uevent.readAll());
        if (hidIdRe.match(text).hasMatch())
            return QStringLiteral("/dev/") + name;
    }
    return QString();
}
// GCOVR_EXCL_STOP

int OrientationSensor::byteToRotation(unsigned char b) {
    // Content rotation (clockwise degrees) that keeps the UI upright for each
    // physical orientation the Edge reports. Calibrated ON-DEVICE:
    //   0x03 upright portrait → 0°, 0x01 inverted portrait → 180° (both verified
    //   upright); the two landscapes needed swapping (they came out inverted at
    //   90/270): 0x00 (+90°CW) → 270°, 0x02 (-90°CW) → 90°.
    switch (b) {
    case 0x03: return 0;
    case 0x00: return 270;
    case 0x01: return 180;
    case 0x02: return 90;
    default:   return -1;
    }
}

// GCOVR_EXCL_START (production entry: locates the real hidraw node via findEdgeHidraw;
// tests drive openAndWatch() directly through the openForTest FIFO seam instead).
bool OrientationSensor::start() {
    const QString path = findEdgeHidraw();
    if (path.isEmpty()) {
        qInfo() << "OrientationSensor: no Xeneon Edge hidraw node found (auto-rotate disabled)";
        return false;
    }
    return openAndWatch(path);
}
// GCOVR_EXCL_STOP

bool OrientationSensor::openAndWatch(const QString& path) {
    m_fd = ::open(path.toUtf8().constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (m_fd < 0) {
        qWarning() << "OrientationSensor: cannot open" << path << "-" << strerror(errno)
                   << "(install the 99-xeneon-edge udev rule to grant access; auto-rotate disabled)";
        return false;
    }
    m_notifier = new QSocketNotifier(m_fd, QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, &OrientationSensor::onReadable);
    qInfo() << "OrientationSensor: watching" << path << "for Xeneon Edge orientation";
    m_startupRetry.stop();
    m_startupRetryIndex = 0;
    m_startupAttemptCount = 0;
    m_hasDeviceReading = false;
    // The panel only pushes a report when the orientation *changes*, so actively
    // query the current state once - otherwise the UI stays at its default (the
    // native-portrait framebuffer, so it looks portrait even when mounted
    // horizontally) until the user physically rotates the panel.
    queryInitialOrientation();
    // Also drain any immediately-available change report.
    onReadable();
    // Still nothing? Restore the orientation remembered from the last run, so a
    // restart isn't stuck mis-rotated on panels that answer no GET_REPORT (they only
    // push on physical change). A later real report overrides this immediately.
    if (!m_hasDeviceReading && m_rotation < 0) {
        const int saved = restorePersistedRotation();
        if (saved >= 0) {
            qInfo() << "OrientationSensor: restored last-known orientation" << saved
                    << "deg while startup hardware acquisition continues";
            applyRotation(saved);
        }
    }
    // Device enumeration and firmware readiness can lag the hidraw node. Continue
    // acquisition for a bounded four-second stepped-backoff window even when a
    // remembered rotation is already rendering. A real pushed report also stops it.
    if (!m_hasDeviceReading)
        scheduleStartupRetry();
    return true;
}

void OrientationSensor::scheduleStartupRetry() {
    if (m_fd < 0 || m_hasDeviceReading || m_startupRetry.isActive())
        return;
    if (m_startupRetryIndex >= m_startupRetryDelays.size()) {
        int windowMs = 0;
        for (const int delay : m_startupRetryDelays)
            windowMs += qMax(1, delay);
        qWarning() << "OrientationSensor: no startup HID orientation after"
                   << m_startupAttemptCount << "attempts over" << windowMs
                   << "ms; keeping the"
                      "remembered/default orientation and following pushed reports";
        return;
    }
    const int delay = qMax(1, m_startupRetryDelays.at(m_startupRetryIndex));
    ++m_startupRetryIndex;
    m_startupRetry.start(delay);
}

void OrientationSensor::onStartupRetry() {
    if (m_fd < 0 || m_hasDeviceReading)
        return;
    if (!queryInitialOrientation())
        scheduleStartupRetry();
}

// Single place a new rotation is adopted: update, notify, and remember it.
void OrientationSensor::applyRotation(int rot) {
    if (rot < 0 || rot == m_rotation)
        return;
    m_rotation = rot;
    persistRotation();
    emit rotationChanged(m_rotation);
}

void OrientationSensor::applyDeviceRotation(int rot) {
    if (rot < 0)
        return;
    m_hasDeviceReading = true;
    m_startupRetry.stop();
    applyRotation(rot);
}

void OrientationSensor::persistRotation() const {
    if (m_statePath.isEmpty() || m_rotation < 0)
        return;
    QDir().mkpath(QFileInfo(m_statePath).absolutePath());
    QSaveFile f(m_statePath);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(QByteArray::number(m_rotation));
        f.commit();
    }
}

int OrientationSensor::restorePersistedRotation() const {
    if (m_statePath.isEmpty())
        return -1;
    QFile f(m_statePath);
    if (!f.open(QIODevice::ReadOnly))
        return -1;
    bool ok = false;
    const int v = f.readAll().trimmed().toInt(&ok);
    // Only accept the four legal content rotations.
    if (ok && (v == 0 || v == 90 || v == 180 || v == 270))
        return v;
    return -1;
}

bool OrientationSensor::queryInitialOrientation() {
    if (m_fd < 0)
        return false;
    ++m_startupAttemptCount;
    unsigned char buf[64];
    // 1) GET_REPORT on the INPUT report the panel pushes on rotation (id 0x01,
    //    orientation byte at [7]). Many devices, however, refuse GET_REPORT on an
    //    input report...
    std::memset(buf, 0, sizeof(buf));
    buf[0] = 0x01;
    int n = ::ioctl(m_fd, HIDIOCGINPUT(sizeof(buf)), buf);
    int rot = (n >= 8 && buf[0] == 0x01) ? byteToRotation(buf[7]) : -1;
    const char* via = "input report";
    // 2) ...so if that failed, fall back to GET_REPORT on the FEATURE report, which
    //    is the report class devices are actually required to answer.
    if (rot < 0) {
        std::memset(buf, 0, sizeof(buf));
        buf[0] = 0x01;
        n = ::ioctl(m_fd, HIDIOCGFEATURE(sizeof(buf)), buf);
        rot = (n >= 8) ? byteToRotation(buf[7]) : -1;
        via = "feature report";
    }
    if (rot < 0) {
        // Neither GET_REPORT worked (the FIFO test seam lands here too). The
        // bounded startup scheduler decides whether another attempt remains.
        return false;
    }
    // GCOVR_EXCL_START (a successful GET_REPORT needs a real hidraw node; over the
    // FIFO test seam both ioctls fail and we return at the guard above).
    qInfo() << "OrientationSensor: initial orientation from" << via << "-> rotation"
            << rot << "deg";
    applyDeviceRotation(rot);
    // GCOVR_EXCL_STOP
    return true;
}

void OrientationSensor::stopWatching() {
    m_startupRetry.stop();
    m_hasDeviceReading = false;
    if (m_notifier) {
        m_notifier->setEnabled(false);
        m_notifier->deleteLater();
        m_notifier = nullptr;
    }
    if (m_fd >= 0) {
        ::close(m_fd);
        m_fd = -1;
    }
}

void OrientationSensor::handleDeviceLost() {
    stopWatching();
    // The node may reappear (device re-plugged / re-enumerated by the kernel).
    // Poll for it and re-open transparently so auto-rotate recovers without a hub
    // restart. active() reports false meanwhile (m_fd < 0).
    if (!m_retry.isActive())
        m_retry.start();
}

// GCOVR_EXCL_START (device-reappear recovery: the retry timer re-scans /sys via
// findEdgeHidraw for the panel to return - a real-hardware unplug/replug cycle).
void OrientationSensor::tryReopen() {
    if (m_fd >= 0) {   // already recovered by a prior attempt
        m_retry.stop();
        return;
    }
    const QString path = findEdgeHidraw();
    if (path.isEmpty())
        return;   // not back yet; keep polling
    if (openAndWatch(path))
        m_retry.stop();
}
// GCOVR_EXCL_STOP

void OrientationSensor::onReadable() {
    if (m_fd < 0)
        return;
    unsigned char buf[64];
    // Consume all pending reports; keep the last valid orientation.
    while (true) {
        const ssize_t n = ::read(m_fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            // GCOVR_EXCL_START (EINTR is a nondeterministic signal race; the -ENODEV
            // fatal path requires a real hidraw unplug - the EOF equivalent IS tested).
            if (errno == EINTR)
                continue;
            // Fatal (e.g. -ENODEV on unplug): the fd is hung up, so the notifier
            // would keep firing and spin/log-spam forever. Stop watching, then
            // poll for the device to come back.
            qWarning() << "OrientationSensor: read error" << strerror(errno)
                       << "- stopping auto-rotate (will retry if the panel returns)";
            handleDeviceLost();
            return;
            // GCOVR_EXCL_STOP
        }
        if (n == 0) {
            // EOF: the device went away. Same treatment as a fatal error.
            qWarning() << "OrientationSensor: device closed (EOF) - stopping auto-rotate"
                       << "(will retry if the panel returns)";
            handleDeviceLost();
            return;
        }
        if (n < 8)
            continue;
        // Orientation notification: report id 0x01, header byte 0x11, value at [7].
        if (buf[0] != 0x01 || buf[1] != 0x11)
            continue;
        applyDeviceRotation(byteToRotation(buf[7]));
    }
}

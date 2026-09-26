// Orientation byte → content rotation mapping (calibrated on-device). Pure static
// function, no hardware. GUILESS.
#include <QtTest>

#include "orientation_sensor.h"

// Refuse to run outside a sandbox: this test would otherwise clobber the
// developer's real config / running hub. See hermetic.h.
#include "hermetic.h"
XENEON_REQUIRE_HERMETIC_ENV();

class TstOrientationByte : public QObject {
    Q_OBJECT
private slots:
    void mapping_data() {
        QTest::addColumn<int>("byte");
        QTest::addColumn<int>("rotation");
        QTest::newRow("0x00-landscape") << 0x00 << 0;
        QTest::newRow("0x03-portrait")  << 0x03 << 90;
        QTest::newRow("0x02-inv-land")  << 0x02 << 180;
        QTest::newRow("0x01-inv-port")  << 0x01 << 270;
        QTest::newRow("0x04-unknown")   << 0x04 << -1;
        QTest::newRow("0xFF-unknown")   << 0xFF << -1;
        QTest::newRow("0x10-unknown")   << 0x10 << -1;
    }
    void mapping() {
        QFETCH(int, byte);
        QFETCH(int, rotation);
        QCOMPARE(OrientationSensor::byteToRotation(static_cast<unsigned char>(byte)), rotation);
    }
};

QTEST_GUILESS_MAIN(TstOrientationByte)
#include "tst_orientation_byte.moc"

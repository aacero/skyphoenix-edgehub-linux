#include <QtTest>

#include "hermetic.h"
#include "shutdown_flush.h"

XENEON_REQUIRE_HERMETIC_ENV();

class FlushRoot final : public QObject {
    Q_OBJECT
public:
    bool succeeds = true;
    int calls = 0;

    Q_INVOKABLE QVariant flushPendingUiState()
    {
        ++calls;
        return succeeds;
    }
};

class BareRoot final : public QObject {
    Q_OBJECT
};

class ShutdownFlushTest final : public QObject {
    Q_OBJECT
private slots:
    void refusesToClaimSuccessWithoutAFlushSurface()
    {
        BareRoot bare;
        const auto result = xeneon::flushPendingUiState({nullptr, &bare});
        QCOMPARE(result.invoked, 0);
        QCOMPARE(result.failed, 0);
        QVERIFY(!result.ok());
    }

    void invokesEveryAvailableRootAndReportsSuccess()
    {
        BareRoot bare;
        FlushRoot first;
        FlushRoot second;
        const auto result = xeneon::flushPendingUiState({&bare, &first, &second});
        QCOMPARE(first.calls, 1);
        QCOMPARE(second.calls, 1);
        QCOMPARE(result.invoked, 2);
        QCOMPARE(result.failed, 0);
        QVERIFY(result.ok());
    }

    void propagatesARejectedQmlFlush()
    {
        FlushRoot good;
        FlushRoot bad;
        bad.succeeds = false;
        const auto result = xeneon::flushPendingUiState({&good, &bad});
        QCOMPARE(good.calls, 1);
        QCOMPARE(bad.calls, 1);
        QCOMPARE(result.invoked, 2);
        QCOMPARE(result.failed, 1);
        QVERIFY(!result.ok());
    }
};

QTEST_GUILESS_MAIN(ShutdownFlushTest)
#include "tst_shutdown_flush.moc"

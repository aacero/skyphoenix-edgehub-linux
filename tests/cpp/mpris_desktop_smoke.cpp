#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>

#include <cstdio>

#include "mpris_bridge.h"

#ifndef XENEON_EVIDENCE_SOURCE_COMMIT
#error "mpris_desktop_smoke must be built with XENEON_EVIDENCE_SOURCE_COMMIT"
#endif

namespace {

enum class Phase {
    Discover,
    ObserveIntermediate,
    ObserveRestoration,
    Finished,
};

void logEvent(const QJsonObject& event) {
    QJsonObject record = event;
    record.insert(
        QStringLiteral("timestamp"),
        QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
    record.insert(
        QStringLiteral("source_commit"),
        QStringLiteral(XENEON_EVIDENCE_SOURCE_COMMIT));
    const QByteArray payload = QJsonDocument(record).toJson(QJsonDocument::Compact);
    fprintf(stdout, "EDGEHUB_MPRIS_EVIDENCE %s\n", payload.constData());
    fflush(stdout);
}

bool isRestorableState(const QString& state) {
    return state == QStringLiteral("Playing") ||
           state == QStringLiteral("Paused");
}

}  // namespace

int main(int argc, char* argv[]) {
    QCoreApplication app(argc, argv);
    if (argc != 2 || QString::fromLocal8Bit(argv[1]).trimmed().isEmpty()) {
        qCritical() << "usage: mpris_desktop_smoke PLAYER_NAME_OR_BUS_NAME";
        return 64;
    }
    const QString requested = QString::fromLocal8Bit(argv[1]).trimmed();

    MprisBridge bridge;
    bridge.setPreferredPlayer(requested);

    Phase phase = Phase::Discover;
    QElapsedTimer phaseTimer;
    phaseTimer.start();
    QString beforeState;
    QString intermediateState;
    QString selectedService;
    QString transportError;

    auto targetSelected = [&] {
        if (!bridge.available())
            return false;
        if (requested.startsWith(QStringLiteral("org.mpris.MediaPlayer2."))) {
            return bridge.serviceName().compare(
                       requested, Qt::CaseInsensitive) == 0;
        }
        return bridge.playerName().compare(requested, Qt::CaseInsensitive) == 0;
    };

    auto finish = [&](int code, const QString& reason) {
        if (phase == Phase::Finished)
            return;
        phase = Phase::Finished;
        logEvent({
            {QStringLiteral("event"),
             code == 0 ? QStringLiteral("complete")
                       : QStringLiteral("failed")},
            {QStringLiteral("player_bus_name"), selectedService},
            {QStringLiteral("action"), QStringLiteral("PlayPause")},
            {QStringLiteral("before_state"), beforeState},
            {QStringLiteral("intermediate_state"), intermediateState},
            {QStringLiteral("current_state"), bridge.status()},
            {QStringLiteral("reason"), reason},
        });
        app.exit(code);
    };

    QObject::connect(
        &bridge, &MprisBridge::transportError, &app,
        [&](const QString& action, const QString& message) {
            transportError = message;
            logEvent({
                {QStringLiteral("event"), QStringLiteral("transport_error")},
                {QStringLiteral("player_bus_name"), bridge.serviceName()},
                {QStringLiteral("action"), action},
                {QStringLiteral("message"), message},
                {QStringLiteral("state"), bridge.status()},
            });
        });

    QTimer waitForPlayer;
    waitForPlayer.setInterval(50);
    QObject::connect(&waitForPlayer, &QTimer::timeout, &app, [&] {
        if (phase == Phase::Finished)
            return;

        if (!transportError.isEmpty()) {
            const QString detail =
                phase == Phase::ObserveRestoration
                    ? QStringLiteral(
                          "restoration transport failed; manually restore the player")
                    : QStringLiteral("transport failed before a proven state change");
            finish(3, detail + QStringLiteral(": ") + transportError);
            return;
        }

        if (phase == Phase::Discover) {
            if (!targetSelected()) {
                if (phaseTimer.elapsed() >= 8000) {
                    finish(2, QStringLiteral(
                                  "requested real player was not discovered"));
                }
                return;
            }
            if (!bridge.canPlayPause() ||
                !isRestorableState(bridge.status())) {
                finish(
                    2,
                    QStringLiteral(
                        "player cannot PlayPause or is not Playing/Paused"));
                return;
            }

            selectedService = bridge.serviceName();
            beforeState = bridge.status();
            logEvent({
                {QStringLiteral("event"), QStringLiteral("selected")},
                {QStringLiteral("player_bus_name"), selectedService},
                {QStringLiteral("player_name"), bridge.playerName()},
                {QStringLiteral("action"), QStringLiteral("PlayPause")},
                {QStringLiteral("state"), beforeState},
            });
            logEvent({
                {QStringLiteral("event"), QStringLiteral("action_sent")},
                {QStringLiteral("player_bus_name"), selectedService},
                {QStringLiteral("action"), QStringLiteral("PlayPause")},
                {QStringLiteral("state"), beforeState},
            });
            phase = Phase::ObserveIntermediate;
            phaseTimer.restart();
            bridge.playPause();
            return;
        }

        if (bridge.serviceName() != selectedService || !bridge.available()) {
            finish(
                3,
                QStringLiteral(
                    "selected player disappeared or changed during the action"));
            return;
        }

        if (phase == Phase::ObserveIntermediate) {
            if (isRestorableState(bridge.status()) &&
                bridge.status() != beforeState) {
                intermediateState = bridge.status();
                logEvent({
                    {QStringLiteral("event"),
                     QStringLiteral("intermediate_observed")},
                    {QStringLiteral("player_bus_name"), selectedService},
                    {QStringLiteral("action"), QStringLiteral("PlayPause")},
                    {QStringLiteral("state"), intermediateState},
                });
                logEvent({
                    {QStringLiteral("event"), QStringLiteral("restore_sent")},
                    {QStringLiteral("player_bus_name"), selectedService},
                    {QStringLiteral("action"), QStringLiteral("PlayPause")},
                    {QStringLiteral("state"), intermediateState},
                });
                phase = Phase::ObserveRestoration;
                phaseTimer.restart();
                bridge.playPause();
                return;
            }
            if (phaseTimer.elapsed() >= 5000) {
                finish(
                    3,
                    QStringLiteral(
                        "no intermediate state change was observed; no blind restore was sent"));
            }
            return;
        }

        if (phase == Phase::ObserveRestoration) {
            if (bridge.status() == beforeState) {
                logEvent({
                    {QStringLiteral("event"),
                     QStringLiteral("restored_observed")},
                    {QStringLiteral("player_bus_name"), selectedService},
                    {QStringLiteral("action"), QStringLiteral("PlayPause")},
                    {QStringLiteral("state"), bridge.status()},
                });
                finish(0, QStringLiteral("state changed and was restored"));
                return;
            }
            if (phaseTimer.elapsed() >= 5000) {
                finish(
                    4,
                    QStringLiteral(
                        "restoration was sent but not observed; manually restore the player"));
            }
        }
    });
    waitForPlayer.start();

    QTimer::singleShot(20000, &app, [&] {
        if (phase == Phase::Finished)
            return;
        finish(
            5,
            phase == Phase::ObserveRestoration
                ? QStringLiteral(
                      "hard timeout after restoration was sent; verify player state manually")
                : QStringLiteral(
                      "hard timeout before a state change was proven; no blind restore was sent"));
    });

    return app.exec();
}

#pragma once

#include <QMap>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// ─────────────────────────────────────────────────────────────────────────────
// mpris_state - the PURE half of the MPRIS bridge.
//
// Everything here is a decision, not a conversation: which player to show, and
// what the now-playing card should say. None of it needs a session bus, so per
// the repo convention (AGENTS.md: "logic classes are extracted into headers so
// they're unit-testable") it lives out here where tests can drive it directly,
// while mpris_bridge.cpp keeps the async D-Bus plumbing that genuinely does
// need a bus.
//
// The one impurity is deliberate and called out at resolveTrack(): it stats the
// filesystem to validate a file:// art path. That is testable with a real temp
// file and needs no bus either.
// ─────────────────────────────────────────────────────────────────────────────
namespace mpris {

// Is this bus name an MPRIS player service? (The ListNames filter.) A player
// registers itself as org.mpris.MediaPlayer2.<name>; that prefix is private to
// mpris_state.cpp, so the two rules that depend on it - this filter and
// playerNameFromService below - cannot drift apart.
bool isMprisService(const QString& busName);

// "org.mpris.MediaPlayer2.spotify" -> "spotify".
QString playerNameFromService(const QString& service);

// Pick the active player from the discovered services:
//   1. prefer the first candidate (in `order`) whose status is "Playing";
//   2. else keep `current`, if it is still present - otherwise two idle players
//      would make the card flap on every 3s rescan;
//   3. else take the first.
// `statuses` maps service -> PlaybackStatus, with "" for a player that did not
// answer (a hung/erroring player must not win). Returns "" iff `order` is empty.
QString choosePlayer(const QStringList& order, const QMap<QString, QString>& statuses,
                     const QString& current, const QString& preferred = QString());

// The user-visible now-playing state, as resolved from one GetAll reply.
struct TrackState {
    QString status;      // Playing / Paused / Stopped / "" (unknown)
    QString title;
    QString artist;      // joined with ", "
    QString album;
    QString artUrl;      // "" when absent, or when a file:// path is unreadable
    QString playerName;
    qlonglong lengthUs = 0;
    bool available = false;
    bool canPlayPause = true;
    bool canGoNext = true;
    bool canGoPrevious = true;
    bool canSeek = false;
};

// Resolve a Player GetAll property map into the state QML should show.
//
// Handles, in order:
//   * xesam:artist arriving as a list OR a plain string (both real; see the
//     fallback in the implementation);
//   * mpris:artUrl with a file:// scheme - VALIDATED against the filesystem and
//     CLEARED when unreadable, because Chromium advertises stale art paths and
//     QML's Image would emit "Cannot open". http(s) is passed through untouched.
//     This is the filesystem touch noted above.
//   * the availability rule - a service can be on the bus with no track loaded
//     (a browser tab that merely *can* play audio, or a just-stopped player).
//     `available` therefore requires a real title OR a Playing/Paused status;
//     otherwise every metadata field is blanked, so the UI shows "nothing
//     playing" rather than a blank card.
TrackState resolveTrack(const QVariantMap& props, const QString& service);

// Do two states differ in any field the user can see? Track length is included
// because the widget renders total time; position has its own notification.
//
// This is the dirty-check: applyProps runs on every 3s rescan, and emitting
// changed() unconditionally re-fires every property NOTIFY, restarting the QML
// animations bound to them. Only a visible move may notify.
bool visiblyDiffers(const TrackState& a, const TrackState& b);

}  // namespace mpris

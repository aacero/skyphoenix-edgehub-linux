#pragma once

// Session-only startup policy for --safe-mode. The command-line flag must not
// rewrite or remove any persisted tile. It only closes the central widget-host
// gate for this process, which also keeps user-widget discovery out of the
// recovery path.
constexpr bool widgetsEnabledForSession(bool safeMode) noexcept {
    return !safeMode;
}

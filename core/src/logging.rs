use tracing_subscriber::filter::LevelFilter;

/// Map a textual log-level name to a `LevelFilter`.
///
/// Accepts one of "error" | "warn" | "info" | "debug" | "trace"; any other
/// value (including an empty string or unknown text) falls back to INFO. Pure
/// and side-effect free so the mapping can be unit-tested directly.
pub fn level_filter(level: &str) -> LevelFilter {
    match level {
        "error" => LevelFilter::ERROR,
        "warn" => LevelFilter::WARN,
        "info" => LevelFilter::INFO,
        "debug" => LevelFilter::DEBUG,
        "trace" => LevelFilter::TRACE,
        _ => LevelFilter::INFO,
    }
}

/// Initialize structured logging for the application.
///
/// The maximum level is set from the explicit `level` argument (see
/// [`level_filter`]); anything unrecognized falls back to INFO. Safe to call
/// multiple times - later calls are no-ops.
pub fn init_logging(level: &str) {
    let filter = level_filter(level);

    // try_init is safe to call multiple times (subsequent calls are no-ops)
    let _ = tracing_subscriber::fmt()
        .with_max_level(filter)
        .with_target(false)
        .with_ansi(true)
        .try_init();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_filter_maps_known_levels() {
        assert_eq!(level_filter("error"), LevelFilter::ERROR);
        assert_eq!(level_filter("warn"), LevelFilter::WARN);
        assert_eq!(level_filter("info"), LevelFilter::INFO);
        assert_eq!(level_filter("debug"), LevelFilter::DEBUG);
        assert_eq!(level_filter("trace"), LevelFilter::TRACE);
    }

    #[test]
    fn level_filter_unknown_and_empty_fall_back_to_info() {
        assert_eq!(level_filter("verbose"), LevelFilter::INFO);
        assert_eq!(level_filter(""), LevelFilter::INFO);
        assert_eq!(level_filter("ERROR"), LevelFilter::INFO); // case-sensitive
        assert_eq!(level_filter("   "), LevelFilter::INFO);
    }

    #[test]
    fn init_logging_is_idempotent_across_all_levels() {
        // Drive init_logging for each level plus an unknown one. The first call
        // installs the global subscriber; the rest must be harmless no-ops.
        // Install the most permissive subscriber first. try_init deliberately
        // makes later calls no-ops, so starting at ERROR would globally suppress
        // INFO/WARN events that other parallel tests must observe and assert.
        for level in ["trace", "debug", "info", "warn", "error", "nonsense", ""] {
            init_logging(level);
        }
        // Calling again must not panic (idempotency).
        init_logging("info");
    }
}

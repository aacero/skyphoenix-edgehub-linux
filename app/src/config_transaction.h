#pragma once

#include "xeneon_core.h"

// Small RAII wrapper for the Rust configuration transaction boundary.
//
// Mutations are applied to an isolated clone. commit() publishes the clone with
// a generation check and swaps the live handle only after persistence succeeds.
// Destroying an uncommitted or failed transaction leaves the live handle alone.
class ConfigTransaction final {
public:
    explicit ConfigTransaction(ConfigHandle* live)
        : m_live(live),
          m_candidate(live ? xeneon_config_clone(live) : nullptr) {}

    ~ConfigTransaction() {
        if (m_candidate)
            xeneon_config_free(m_candidate);
    }

    ConfigTransaction(const ConfigTransaction&) = delete;
    ConfigTransaction& operator=(const ConfigTransaction&) = delete;

    explicit operator bool() const { return m_candidate != nullptr; }
    ConfigHandle* candidate() const { return m_candidate; }

    bool commit() {
        if (!m_live || !m_candidate) {
            m_commitCode = -1;
            return false;
        }
        m_commitCode = xeneon_config_commit(m_live, m_candidate);
        return m_commitCode >= 0;
    }
    bool durabilityUncertain() const { return m_commitCode == 1; }

private:
    ConfigHandle* m_live = nullptr;
    ConfigHandle* m_candidate = nullptr;
    int m_commitCode = -1;
};

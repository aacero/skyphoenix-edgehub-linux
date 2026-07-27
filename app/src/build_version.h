#pragma once

// Product targets receive an always-refreshed generated header from CMake.
// Logic-only tests intentionally omit the opt-in and retain each class's
// existing development fallback without depending on a configured build tree.
#ifdef XENEON_USE_GENERATED_BUILD_VERSION
#include "xeneon_build_version.generated.h"
#endif

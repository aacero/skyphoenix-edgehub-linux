#pragma once

namespace xeneon {

// Maximum newline-delimited JSON control frame in either direction. A valid
// 1 MiB raw UI-state document remains below this even when JSON escaping expands
// every input byte to a six-byte escape sequence.
inline constexpr int kMaxControlFrameBytes = 8 * 1024 * 1024;

} // namespace xeneon

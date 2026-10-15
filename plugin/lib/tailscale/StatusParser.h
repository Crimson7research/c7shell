#pragma once

#include "tailscale/Types.h"

#include <QtCore/QByteArray>

#include <optional>

namespace c7::tailscale {

class StatusParser {
public:
    // nullopt when `json` is not a JSON object. Any object parses, and a key it
    // lacks leaves its field empty: callers must treat an empty backendState as
    // "no usable status", which is what `{}` yields.
    static std::optional<Status> parse(const QByteArray &json);
};

} // namespace c7::tailscale

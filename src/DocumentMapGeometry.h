#pragma once

#include <algorithm>
#include <cmath>

namespace DocumentMap {

// All coordinates are measured downwards from the top of the map.
struct Viewport {
    long firstMapLine;
    double top;
    double height;
};

inline Viewport viewport(long totalLines, long firstDocumentLine, long endDocumentLine,
                         double progress, double lineHeight, double panelHeight) {
    if (panelHeight <= 0 || lineHeight <= 0) return {0, 0, 0};
    totalLines = std::max(1L, totalLines);
    firstDocumentLine = std::clamp(firstDocumentLine, 0L, totalLines - 1);
    endDocumentLine = std::clamp(endDocumentLine, firstDocumentLine + 1, totalLines);
    const double height = std::min(panelHeight,
        std::max(6.0, (endDocumentLine - firstDocumentLine) * lineHeight));
    const long maxMapFirst = std::max(0L, totalLines -
        std::max(1L, static_cast<long>(panelHeight / lineHeight)));
    const long first = std::clamp(static_cast<long>(std::lround(firstDocumentLine -
        std::clamp(progress, 0.0, 1.0) * (panelHeight - height) / lineHeight)), 0L, maxMapFirst);
    return {first, std::clamp((firstDocumentLine - first) * lineHeight,
                             0.0, panelHeight - height), height};
}

inline long draggedFirstLine(long initialFirst, double deltaY, double trackHeight, long maxFirst) {
    if (trackHeight <= 0 || maxFirst <= 0) return 0;
    return std::clamp(static_cast<long>(std::lround(initialFirst + deltaY * maxFirst / trackHeight)),
                      0L, maxFirst);
}

} // namespace DocumentMap

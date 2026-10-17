#include <CoreImage/CoreImage.h>
using namespace metal;

// Core Image puts the origin at the bottom left; raw rows count from the top. `height` converts, so CFA
// positions (row-major within the 2×2 tile) refer to raw rows.
static int cfaPosition(float2 coord, float height) {
    int x = int(coord.x), row = int(height) - 1 - int(coord.y);
    return (row & 1) * 2 + (x & 1);
}

extern "C" {
namespace coreimage {

/// Raw values (16-bit, normalized by Core Image) to black-subtracted, white-balanced values: 1 is
/// saturation of green. Nothing is clamped, so noise below black stays negative.
[[stitchable]] float4 rawLinearize(sampler raw, float4 black, float4 scale, float height, destination dest) {
    float2 c = dest.coord();
    int p = cfaPosition(c, height);
    float v = raw.sample(raw.transform(c)).r * 65535.0;
    return float4((v - black[p]) * scale[p], 0, 0, 1);
}

/// Malvar-He-Cutler demosaic (linear 5×5), highlights clipped to white at `clip`, the lens's radial
/// vignetting gain raised to `strength` (0 none, 1 the DNG's full correction), a neutral lift, then the
/// color matrix to linear sRGB. `cfa` holds the color (0 R, 1 G, 2 B) of each 2×2 position; `optical` is
/// in raw pixels from the top left and `invRadius` is one over the distance to the farthest corner.
[[stitchable]] float4 rawDemosaic(sampler m, float4 cfa, float height, float3 row0, float3 row1, float3 row2,
                                  float lift, float clip, float4 k, float k4, float2 optical, float invRadius,
                                  float strength, destination dest) {
    float2 c = dest.coord();
    int p = cfaPosition(c, height);
    int color = int(cfa[p]);
    // Raw "up" is Core Image +y; the filters are symmetric vertically, so only the naming cares.
    #define S(dx, dy) m.sample(m.transform(c + float2(dx, dy))).r
    float center = S(0, 0);
    float n1 = S(0, 1), s1 = S(0, -1), e1 = S(1, 0), w1 = S(-1, 0);
    float n2 = S(0, 2), s2 = S(0, -2), e2 = S(2, 0), w2 = S(-2, 0);
    float diagonal = S(1, 1) + S(-1, 1) + S(1, -1) + S(-1, -1);
    #undef S

    float3 rgb;
    if (color == 1) {
        float horizontal = (5 * center + 4 * (e1 + w1) - diagonal - (e2 + w2) + 0.5 * (n2 + s2)) / 8;
        float vertical = (5 * center + 4 * (n1 + s1) - diagonal - (n2 + s2) + 0.5 * (e2 + w2)) / 8;
        bool redInRow = int(cfa[p ^ 1]) == 0;
        rgb = redInRow ? float3(horizontal, center, vertical) : float3(vertical, center, horizontal);
    } else {
        float green = (4 * center + 2 * (n1 + s1 + e1 + w1) - (n2 + s2 + e2 + w2)) / 8;
        float opposite = (6 * center + 2 * diagonal - 1.5 * (n2 + s2 + e2 + w2)) / 8;
        rgb = color == 0 ? float3(center, green, opposite) : float3(opposite, green, center);
    }
    // Any channel at saturation means the color is unknown: clipping all at the first channel's
    // saturation keeps such highlights white instead of tinted.
    rgb = min(rgb, clip);
    if (strength > 0) {
        float2 d = (float2(c.x, height - c.y) - optical) * invRadius;
        float r2 = dot(d, d);
        float gain = 1 + r2 * (k.x + r2 * (k.y + r2 * (k.z + r2 * (k.w + r2 * k4))));
        rgb *= pow(gain, strength);
    }
    rgb += lift;
    return float4(dot(row0, rgb), dot(row1, rgb), dot(row2, rgb), 1);
}

}
}

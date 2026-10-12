// stb_image implementation (when the parent project does not provide one: IMGUI_RICHMD_STB_IMAGE_IMPLEMENTATION)
//
// GCC reports a false-positive -Wstringop-overflow in stb_image v2.29's PNG tRNS
// parsing: the fill loop at stb_image.h:5164 is bounded by s->img_n, which the
// guard at stb_image.h:5156 restricts to 1 or 3 before any write, but GCC cannot
// narrow the struct field across the adjacent ++s->img_n (header-scan) branch.
// See plan/appendix_b.md for the full analysis and sanitizer proof.
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstringop-overflow"
#endif
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif

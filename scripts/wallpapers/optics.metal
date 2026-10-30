// Spectral glass shared with the app: the same wavelength weights, dispersion and Fresnel that Prism's shaders use
// (Sources/Atoll/Prism/Shaders/PrismOptics.h), so a wallpaper's glass and the glass on screen agree.
#include "../../Sources/Atoll/Prism/Shaders/PrismOptics.h"

using prism::spectrum;
using prism::iorAt;
using prism::fresnel;

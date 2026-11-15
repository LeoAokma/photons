43XL + iiic / Hasselblad CFV 100C / f/11 / infinity
Measured 2026-11-15. 36 landscape and 9 counterclockwise portrait LCC captures.
The built-in .photonslcc contains oriented Float32 CFA block means, their standard
errors, cell coordinates, shifts, sensor size and capture conditions. It keeps the
full illuminated sensor footprint, including dark corners. No original RAW image,
absolute source path or private EXIF serial number is included.

The application copies this calibration into Application Support/Photons/LensProfiles
on first use. User-created profiles live there too. A profile is a losslessly compressed
binary property list with a versioned JSON catalog header and SHA-256 integrity digest.

CFA data and Apple-developed linear-sRGB data have distinct measurement-space IDs.
They must not be mixed or applied in the wrong processing space. Automatic orientation
selection is separate from determining the absolute optical position and applying LCC.

The built-in file additionally keeps fixed-6500K Apple-linear-sRGB measurements for
native rendering. PHLCC002 losslessly shuffles Float32 bit deltas before LZFSE; CFA,
RGB and standard-error grids round-trip bit-for-bit. Runtime correction blends
calibration samples continuously in log space with edge taper and spatial smoothing;
it never removes illuminated dim corners from measured coverage.

Falloff strength is independent of R/G and B/G correction. Rendering applies one
shared transform back to the mean temperature/tint of the input RAWs. Highlight
protection uses a single panorama exposure and a continuous SDR shoulder; linear DNG
retains floating-point headroom. Calibration position is frozen for preview/export.

A measured frame is the sole absolute position anchor. Additional measured positions
seed bounded (+/-1.5 mm) translation searches; image correlation must still succeed.
The Alpa diagram includes sensor footprint plus X +/-18, Y -18...+25 mm travel. With
no established optical origin its coverage bounding box is centered on the panorama.
An automatic optical-origin search uses confirmed paired white plates when available;
otherwise scene colors/shading give only a low-confidence proposal for visual review.
Paired plates do not replace or stack with the selected lens-profile pixel correction.

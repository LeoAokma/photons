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

The built-in file also retains the original fixed-6500K linear-sRGB measurements for
archival compatibility; they are no longer applied to RAW pixels. Runtime uses the
four black-subtracted CFA channels. The v1 CFV 100C grid's 4094 DN subtraction is
adjusted by 2 DN to agree with the file's 4096 DN black tag. New profiles use v2,
normalized black-subtracted CFA means and standard errors, without storing RAW files.
PHLCC002 losslessly shuffles Float32 bit deltas before LZFSE; grids round-trip exactly.

Spatial falloff and colour shading are corrected completely. A single global EV
changes panorama brightness after this correction; there is no partial falloff slider.
A temporary Bayer DNG carries four maps through OpcodeList2 before Apple demosaic,
WB and colour conversion. Apple requires equal green maps, so the small G1/G2 ratio
is applied to the mosaic first, then a shared geometric-mean green map is used.
The original camera matrices and calibration metadata remain in the intermediate DNG.
Explicit shadowBias=0 is essential: Apple's default shadow subtraction otherwise
breaks linearity and creates dark seams at different normalizations. Normalization
before RAW processing is reversed in floating point after development.

WB is measured after spatial correction, preferentially from confirmed paired white
plates; without them, bright scene pixels give an estimate that the user can override.
It is never a fitted RGB tint to compensate for a colour cast. Profile illumination
cancels independently per channel against its central reference. A partial profile
without the optical axis uses its brightest measured reference, so an absolute global
colour offset cannot be identified from that profile alone.

Original sensor clipping is tracked separately from LCC overexposure. Saturated
channels are estimated from surviving channels and neighbouring unsaturated colours
(with measured illumination as fallback); this cannot
restore lost information or guarantee original saturated colours. One panorama exposure
and an SDR shoulder protect displayed highlights; the linear DNG export retains headroom.
No spatial RGB overlap fitting is applied on top of LCC. Only scalar overlap exposure
matching remains. Gain coordinates, WB and geometry are frozen for full export.

The native mosaic path currently supports uncompressed CFV 100C 3FR and compatible
16-bit little-endian Bayer DNG (uncompressed or supported SOF3 tiles). Unknown RAW
layouts, linearization and extra pixel-calibration opcodes are rejected explicitly.
No LibRaw or other additional dependency is linked. Export remains a developed linear
RGB DNG, not a camera-CFA DNG with its original editable capture WB metadata.

A measured frame is the sole absolute position anchor. Additional measured positions
seed bounded (+/-1.5 mm) translation searches; image correlation must still succeed.
The Alpa diagram includes sensor footprint plus X +/-18, Y -18...+25 mm travel. With
no established optical origin its coverage bounding box is centered on the panorama.
An automatic optical-origin search uses confirmed paired white plates when available;
otherwise scene colors/shading give only a low-confidence proposal for visual review.
Paired plates determine corrected WB and aid location; they do not stack another
spatial correction on top of the selected lens profile.

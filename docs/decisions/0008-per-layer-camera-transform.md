# ADR-0008: The canvas camera is applied per layer, not as one sublayerTransform

- **Status:** Accepted
- **Date:** 2026-11-19

## Context
SPEC §11.4 says to apply the camera as `rootLayer.sublayerTransform`, so pan and zoom never redraw node layers. While building the virtualized layer tree (M1 slice 7b), a shared sublayer transform mis-composed raster contents on the current toolchain: node rasters landed cropped and displaced under any inherited scale. It reproduced across several layer configurations.

## Decision
`CanvasLayerTree` applies the camera to each realized layer instead:

- Node layers get a pure scale about their anchor (the screen point of their model origin), so their raster contents compose pixel-perfectly at every zoom.
- Path-carrying layers (branches, selection rings) get the full model→screen matrix, because their geometry lives in model space.

## Consequences
- The §11.4 invariant holds: pan and zoom rewrite placements and transforms only, never a raster. The 120 ms post-settle pass still re-rasterizes for sharpness.
- A camera change touches every visible layer (bounded by culling: visible rect + 50% margin) instead of one layer. This is cheap at the culled counts, but it is per-frame work to watch in the pan/zoom budget.
- Revisit if a future toolchain composes inherited sublayer transforms correctly: one transform is simpler.

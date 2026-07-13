# Publish Airspace GGER Tiles as Fixed Levels First

We will publish W/G candidate airspace and suitable airspace as separate fixed-level GGER 3D Tiles tilesets in the first version, rather than building one hierarchical LOD tileset immediately. This keeps candidate-vs-suitable semantics and picked GGER codes easy to verify while preserving hierarchical 3D Tiles LOD as a later optimization once voxelization and classification are proven.

## Considered Options

- Generate separate `candidate/level-N/tileset.json` and `suitable/level-N/tileset.json` tilesets and switch levels in the frontend.
- Generate one hierarchical tileset whose parent tiles aggregate lower-resolution GGER cells and whose children refine to finer levels.

## Consequences

The first version needs frontend level switching and may have level-change flicker. A later optimization should replace or supplement fixed-level tilesets with hierarchical LOD tilesets when parent-child aggregation semantics are stable.

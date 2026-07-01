# Graph Report - /Users/madizm/geovis/huaguoshan  (2026-07-01)

## Corpus Check
- 10 files · ~50,090 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 385 nodes · 981 edges · 15 communities (13 shown, 2 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 12 edges (avg confidence: 0.86)
- Token cost: 32,347 input · 4,200 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Obstacle Refresh SQL|Obstacle Refresh SQL]]
- [[_COMMUNITY_OSM CityDB Import|OSM CityDB Import]]
- [[_COMMUNITY_Flight Obstacle Refresh|Flight Obstacle Refresh]]
- [[_COMMUNITY_Terrain CityDB Docs|Terrain CityDB Docs]]
- [[_COMMUNITY_GGER Airspace UI|GGER Airspace UI]]
- [[_COMMUNITY_Flight Obstacle Architecture|Flight Obstacle Architecture]]
- [[_COMMUNITY_Beidou Airspace Rendering|Beidou Airspace Rendering]]
- [[_COMMUNITY_DEM Terrain Import|DEM Terrain Import]]
- [[_COMMUNITY_GGER Obstacle RPCs|GGER Obstacle RPCs]]
- [[_COMMUNITY_GGER Bounds Encoding|GGER Bounds Encoding]]
- [[_COMMUNITY_iBEST Grid Concepts|iBEST Grid Concepts]]
- [[_COMMUNITY_Beidou Bounds Utilities|Beidou Bounds Utilities]]
- [[_COMMUNITY_3D Tiles Export|3D Tiles Export]]
- [[_COMMUNITY_Future Obstacle Staging|Future Obstacle Staging]]
- [[_COMMUNITY_GGER Validation|GGER Validation]]

## God Nodes (most connected - your core abstractions)
1. `qname()` - 22 edges
2. `rebuild_views()` - 19 edges
3. `parse_buildings()` - 15 edges
4. `main()` - 15 edges
5. `rebuild_materialized_view()` - 12 edges
6. `main()` - 12 edges
7. `qname()` - 11 edges
8. `createRenderer()` - 11 edges
9. `prepare_dem()` - 10 edges
10. `polygon_from_relation()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `GeoSOT 3D Height Layer` --conceptually_related_to--> `getHeightBounds()`  [INFERRED]
  docs/gger-grid-code-algorithm.md → js/GGERGridBounds.js
- `citydb_grid.flight_obstacles Materialized View` --implements--> `build_materialized_view_sql()`  [INFERRED]
  docs/citydb_gger_geomgrids_plan.md → scripts/refresh_citydb_flight_obstacles.py
- `GGER Height Layer Stacking` --conceptually_related_to--> `addVerticalEdges()`  [INFERRED]
  docs/beidou-airspace-grid-visualization-plan.md → js/GGERAirspaceGrid.js
- `Cesium Rendering and Performance Controls` --implements--> `createRenderer()`  [INFERRED]
  docs/beidou-airspace-grid-visualization-plan.md → js/GGERAirspaceGrid.js
- `BGC 3D Encoding` --implements--> `encode3D()`  [EXTRACTED]
  docs/beidou-grid-code-algorithm.md → js/BeidouGridCode.js

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Multi-source Obstacle Pipeline** — docs_multi_source_flight_obstacles_plan_source_specific_materialized_views, docs_multi_source_flight_obstacles_plan_citydb_grid_flight_obstacles, docs_multi_source_flight_obstacles_plan_public_flight_obstacles_wrapper [EXTRACTED 1.00]
- **Terrain Precision and LOD Strategy** — docs_refined_flight_obstacles_plan_block_prism, docs_terrain_obstacle_lod_plan_obstacles_terrain_lod, frontend_tianditu_3d_requestterrainobstacleslod [EXTRACTED 1.00]
- **GGER-only Display Contract** — docs_multi_source_flight_obstacles_plan_gger_only_output, docs_terrain_obstacle_lod_plan_lod_rpc, frontend_tianditu_3d_flight_obstacle_rendering [EXTRACTED 1.00]

## Communities (15 total, 2 thin omitted)

### Community 0 - "Obstacle Refresh SQL"
Cohesion: 0.13
Nodes (60): Any, Composable, Composed, Connection, Cursor, Namespace, view_depends_on_relation(), bool_literal() (+52 more)

### Community 1 - "OSM CityDB Import"
Cohesion: 0.12
Nodes (39): Exception, MultiPolygon, Polygon, apply_terrain_elevations(), assemble_rings(), build_overpass_query(), Building, clean_multipolygon() (+31 more)

### Community 2 - "Flight Obstacle Refresh"
Cohesion: 0.14
Nodes (33): RuntimeError, bool_literal(), build_codes_view_sql(), build_dry_run_sql(), build_grids_expression(), build_materialized_view_sql(), build_public_wrapper_sql(), build_ranked_geometry_cte() (+25 more)

### Community 3 - "Terrain CityDB Docs"
Cohesion: 0.12
Nodes (31): ArgumentParser, 3DCityDB 5.x, 3DCityDB Relief Schema, DEM Raster Terrain, DEM Terrain to 3DCityDB Plan, Development Environment, Terrain Vertical Datum Record, GEOVIS iBEST-DB Trajectory Quick Reference (+23 more)

### Community 4 - "GGER Airspace UI"
Cohesion: 0.14
Nodes (29): Camera-driven GGER Level Selection, Cesium Rendering and Performance Controls, GGER Airspace Visualization, Visible GGER Cell Enumeration, addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel() (+21 more)

### Community 5 - "Flight Obstacle Architecture"
Cohesion: 0.07
Nodes (30): Airspace Business Tables, citydb_grid.flight_obstacles, GGER-only Obstacle Output, Multi-source Flight Obstacles Plan, PostgREST Flight Obstacle RPC, public.flight_obstacles compatibility wrapper, refresh_citydb_obstacle_grids.py workflow, Source-specific Obstacle Materialized Views (+22 more)

### Community 6 - "Beidou Airspace Rendering"
Cohesion: 0.18
Nodes (25): addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel(), clamp(), create(), createCollections(), createColor() (+17 more)

### Community 7 - "DEM Terrain Import"
Cohesion: 0.21
Nodes (25): buffered_projected_bounds(), cleanup_citydb_feature(), create_terrain_schema(), DemPaths, DemStats, download(), ensure_gdal_tools(), import_raster() (+17 more)

### Community 8 - "GGER Obstacle RPCs"
Cohesion: 0.15
Nodes (22): get_citydb_feature_gger_grids RPC, ST_WithBox GGER bbox output, citydb_grid.flight_obstacles Materialized View, GeomGrids Obstacle Index, GGER Codes View, GIN geomgrids Index, PostgREST GGER + Box RPC, ST_FindGridsPath Wrapper View (+14 more)

### Community 9 - "GGER Bounds Encoding"
Cohesion: 0.23
Nodes (21): GGER Height Layer Stacking, arcSecondFractionsToHeight(), assertFiniteNumber(), assertLatitude(), assertLevel(), assertLongitude(), clamp(), coordinateToIndex() (+13 more)

### Community 10 - "iBEST Grid Concepts"
Cohesion: 0.20
Nodes (19): Beidou Grid Code Algorithm, Beidou Grid Code, BGC 3D Encoding, GeoSOT Grid, GEOVIS iBEST-DB Manual, iBEST-DB GeomGrids, iBEST-DB GridCell, iBEST-DB Grid Path Planning (+11 more)

### Community 11 - "Beidou Bounds Utilities"
Cohesion: 0.27
Nodes (17): assertFiniteNumber(), assertLevel(), clampIndex(), distanceMeters(), firstLevelBounds(), getCellBounds(), getHeightBounds(), getHeightBoundsByLayer() (+9 more)

### Community 12 - "3D Tiles Export"
Cohesion: 0.35
Nodes (12): 3DCityDB to 3D Tiles Workflow, 3D Tiles Materialized View Contract, citydb-3dtiles-export skill, pg2b3dm Export, create_materialized_view(), log(), resolve_pg2b3dm(), run_advice() (+4 more)

## Knowledge Gaps
- **21 isolated node(s):** `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation`, `GeomGrids Obstacle Index`, `GIN geomgrids Index`, `ST_FindGridsPath Wrapper View` (+16 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `citydb_grid.flight_obstacles Materialized View` connect `GGER Obstacle RPCs` to `Flight Obstacle Refresh`?**
  _High betweenness centrality (0.103) - this node is a cross-community bridge._
- **Why does `build_materialized_view_sql()` connect `Flight Obstacle Refresh` to `GGER Obstacle RPCs`, `Obstacle Refresh SQL`?**
  _High betweenness centrality (0.098) - this node is a cross-community bridge._
- **What connects `Read a small clipped DEM through GDAL XYZ output as a row-major 2D array.`, `Raised for user-actionable script failures.`, `Check required iBEST-DB/PostGIS functions, type, GIN opclass and CityDB tables e` to the rest of the system?**
  _27 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Obstacle Refresh SQL` be split into smaller, more focused modules?**
  _Cohesion score 0.13060109289617486 - nodes in this community are weakly interconnected._
- **Should `OSM CityDB Import` be split into smaller, more focused modules?**
  _Cohesion score 0.1202020202020202 - nodes in this community are weakly interconnected._
- **Should `Flight Obstacle Refresh` be split into smaller, more focused modules?**
  _Cohesion score 0.1443850267379679 - nodes in this community are weakly interconnected._
- **Should `Terrain CityDB Docs` be split into smaller, more focused modules?**
  _Cohesion score 0.11693548387096774 - nodes in this community are weakly interconnected._
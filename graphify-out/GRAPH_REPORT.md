# Graph Report - .  (2026-07-01)

## Corpus Check
- 10 files · ~38,851 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 307 nodes · 715 edges · 14 communities (12 shown, 2 thin omitted)
- Extraction: 99% EXTRACTED · 1% INFERRED · 0% AMBIGUOUS · INFERRED: 10 edges (avg confidence: 0.86)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_OSM Building Import|OSM Building Import]]
- [[_COMMUNITY_CityDB Refresh Script|CityDB Refresh Script]]
- [[_COMMUNITY_3D Tiles Terrain Docs|3D Tiles Terrain Docs]]
- [[_COMMUNITY_GGER Airspace UI|GGER Airspace UI]]
- [[_COMMUNITY_Legacy Beidou Airspace Grid|Legacy Beidou Airspace Grid]]
- [[_COMMUNITY_DEM Terrain Import|DEM Terrain Import]]
- [[_COMMUNITY_GGER Bounds Height Layers|GGER Bounds Height Layers]]
- [[_COMMUNITY_Legacy Beidou Encoding|Legacy Beidou Encoding]]
- [[_COMMUNITY_Legacy Beidou Bounds|Legacy Beidou Bounds]]
- [[_COMMUNITY_CityDB GGER Obstacles|CityDB GGER Obstacles]]
- [[_COMMUNITY_DEM 3D Tiles Export|DEM 3D Tiles Export]]
- [[_COMMUNITY_GGER Encoding Algorithm|GGER Encoding Algorithm]]
- [[_COMMUNITY_iBEST-DB GGER Validation|iBEST-DB GGER Validation]]
- [[_COMMUNITY_Tianditu Cesium Scene|Tianditu Cesium Scene]]

## God Nodes (most connected - your core abstractions)
1. `parse_buildings()` - 15 edges
2. `rebuild_materialized_view()` - 12 edges
3. `main()` - 12 edges
4. `qname()` - 11 edges
5. `prepare_dem()` - 10 edges
6. `polygon_from_relation()` - 10 edges
7. `createRenderer()` - 10 edges
8. `createRenderer()` - 9 edges
9. `polyhedral_surface_wkt()` - 9 edges
10. `main()` - 9 edges

## Surprising Connections (you probably didn't know these)
- `GeoSOT 3D Height Layer` --conceptually_related_to--> `getHeightBounds()`  [INFERRED]
  docs/gger-grid-code-algorithm.md → js/GGERGridBounds.js
- `DEM Raster Terrain` --implements--> `build_mesh()`  [INFERRED]
  docs/dem_terrain_to_3dcitydb_plan.md → scripts/export_dem_3dtiles.py
- `GGER Height Layer Stacking` --conceptually_related_to--> `addVerticalEdges()`  [INFERRED]
  docs/beidou-airspace-grid-visualization-plan.md → js/GGERAirspaceGrid.js
- `Cesium Rendering and Performance Controls` --implements--> `createRenderer()`  [INFERRED]
  docs/beidou-airspace-grid-visualization-plan.md → js/GGERAirspaceGrid.js
- `citydb_grid.flight_obstacles Materialized View` --implements--> `build_materialized_view_sql()`  [INFERRED]
  docs/citydb_gger_geomgrids_plan.md → scripts/refresh_citydb_flight_obstacles.py

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Terrain-aware LoD1 export flow** — dem_raster_terrain, terrain_elevation_sampling, osm_building_import, lod1_building_solid, citydb_3dtiles_workflow [INFERRED 0.85]
- **iBEST-DB grid and path capabilities** — ibestdb_gridcell, ibestdb_geomgrids, beidou_grid_code, ibestdb_path_planning, ibestdb_trajectory [INFERRED 0.75]
- **GGER Airspace Visualization Stack** — docs_gger_grid_code_algorithm_gger_geosot_encoding, js_ggergridcode, js_ggergridbounds, js_ggerairspacegrid, frontend_tianditu_3d_airspace_grid_ui [EXTRACTED 1.00]
- **CityDB GGER Obstacle Query Pipeline** — scripts_refresh_citydb_flight_obstacles, docs_citydb_gger_geomgrids_plan_flight_obstacles_materialized_view, backend_create_citydb_feature_gger_grids_rpc_get_citydb_feature_gger_grids, frontend_tianditu_3d_gger_grid_rpc_client, frontend_tianditu_3d_selected_grid_highlight [EXTRACTED 1.00]
- **Multi-source Obstacle Union Model** — docs_multi_source_flight_obstacles_plan_building_obstacles, docs_multi_source_flight_obstacles_plan_terrain_obstacles, docs_multi_source_flight_obstacles_plan_no_fly_and_temp_control_zones, docs_citydb_gger_geomgrids_plan_flight_obstacles_materialized_view [EXTRACTED 1.00]

## Communities (14 total, 2 thin omitted)

### Community 0 - "OSM Building Import"
Cohesion: 0.12
Nodes (39): Exception, MultiPolygon, Polygon, apply_terrain_elevations(), assemble_rings(), build_overpass_query(), Building, clean_multipolygon() (+31 more)

### Community 1 - "CityDB Refresh Script"
Cohesion: 0.15
Nodes (40): Any, Composed, Connection, Cursor, Obstacle Grid Refresh Order, Namespace, RuntimeError, bool_literal() (+32 more)

### Community 2 - "3D Tiles Terrain Docs"
Cohesion: 0.12
Nodes (30): 3DCityDB 5.x, 3DCityDB to 3D Tiles Workflow, 3D Tiles Materialized View Contract, 3DCityDB Relief Schema, citydb-3dtiles-export skill, DEM Raster Terrain, DEM Terrain to 3DCityDB Plan, Development Environment (+22 more)

### Community 3 - "GGER Airspace UI"
Cohesion: 0.14
Nodes (29): Camera-driven GGER Level Selection, Cesium Rendering and Performance Controls, GGER Airspace Visualization, Visible GGER Cell Enumeration, GGER Airspace Grid UI, addEdge(), addRectangleEdges(), addVerticalEdges() (+21 more)

### Community 4 - "Legacy Beidou Airspace Grid"
Cohesion: 0.18
Nodes (24): addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel(), clamp(), create(), createCollections(), createColor() (+16 more)

### Community 5 - "DEM Terrain Import"
Cohesion: 0.21
Nodes (25): buffered_projected_bounds(), cleanup_citydb_feature(), create_terrain_schema(), DemPaths, DemStats, download(), ensure_gdal_tools(), import_raster() (+17 more)

### Community 6 - "GGER Bounds Height Layers"
Cohesion: 0.23
Nodes (21): GGER Height Layer Stacking, arcSecondFractionsToHeight(), assertFiniteNumber(), assertLatitude(), assertLevel(), assertLongitude(), clamp(), coordinateToIndex() (+13 more)

### Community 7 - "Legacy Beidou Encoding"
Cohesion: 0.22
Nodes (18): Beidou Grid Code Algorithm, Beidou Grid Code, BGC 3D Encoding, GeoSOT Grid, GEOVIS iBEST-DB Manual, iBEST-DB GeomGrids, iBEST-DB GridCell, assertFiniteNumber() (+10 more)

### Community 8 - "Legacy Beidou Bounds"
Cohesion: 0.27
Nodes (17): assertFiniteNumber(), assertLevel(), clampIndex(), distanceMeters(), firstLevelBounds(), getCellBounds(), getHeightBounds(), getHeightBoundsByLayer() (+9 more)

### Community 9 - "CityDB GGER Obstacles"
Cohesion: 0.13
Nodes (17): get_citydb_feature_gger_grids RPC, ST_WithBox GGER bbox output, citydb_grid.flight_obstacles Materialized View, GeomGrids Obstacle Index, GGER Codes View, GIN geomgrids Index, PostgREST GGER + Box RPC, ST_FindGridsPath Wrapper View (+9 more)

### Community 10 - "DEM 3D Tiles Export"
Cohesion: 0.28
Nodes (14): ArgumentParser, ndarray, build_mesh(), build_parser(), enu_axes(), main(), make_tile_transform(), MeshData (+6 more)

### Community 11 - "GGER Encoding Algorithm"
Cohesion: 0.32
Nodes (13): Extended DMS 32-bit Index, GeoSOT 3D Height Layer, 2D/3D Morton Digit Interleaving, arcSecondFractionsToExtendedDmsIndex(), assertFiniteNumber(), assertLatitude(), assertLevel(), assertLongitude() (+5 more)

## Knowledge Gaps
- **14 isolated node(s):** `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation`, `GeomGrids Obstacle Index`, `GIN geomgrids Index`, `ST_FindGridsPath Wrapper View` (+9 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `GGER Airspace Grid UI` connect `GGER Airspace UI` to `GGER Encoding Algorithm`, `GGER Bounds Height Layers`?**
  _High betweenness centrality (0.090) - this node is a cross-community bridge._
- **Why does `citydb_grid.flight_obstacles Materialized View` connect `CityDB GGER Obstacles` to `CityDB Refresh Script`?**
  _High betweenness centrality (0.088) - this node is a cross-community bridge._
- **Why does `GGER / GeoSOT Encoding` connect `CityDB GGER Obstacles` to `GGER Encoding Algorithm`?**
  _High betweenness centrality (0.082) - this node is a cross-community bridge._
- **What connects `Read a small clipped DEM through GDAL XYZ output as a row-major 2D array.`, `Raised for user-actionable script failures.`, `Check required iBEST-DB/PostGIS functions, type, GIN opclass and CityDB tables e` to the rest of the system?**
  _17 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `OSM Building Import` be split into smaller, more focused modules?**
  _Cohesion score 0.1202020202020202 - nodes in this community are weakly interconnected._
- **Should `3D Tiles Terrain Docs` be split into smaller, more focused modules?**
  _Cohesion score 0.12473118279569892 - nodes in this community are weakly interconnected._
- **Should `GGER Airspace UI` be split into smaller, more focused modules?**
  _Cohesion score 0.13763440860215054 - nodes in this community are weakly interconnected._
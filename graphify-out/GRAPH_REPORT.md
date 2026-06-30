# Graph Report - .  (2026-06-30)

## Corpus Check
- Corpus is ~28,196 words - fits in a single context window. You may not need a graph.

## Summary
- 186 nodes · 437 edges · 9 communities
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 8 edges (avg confidence: 0.81)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_OSM CityDB Import|OSM CityDB Import]]
- [[_COMMUNITY_Cesium Airspace Renderer|Cesium Airspace Renderer]]
- [[_COMMUNITY_DEM Terrain Import|DEM Terrain Import]]
- [[_COMMUNITY_Terrain Buildings Planning|Terrain Buildings Planning]]
- [[_COMMUNITY_Beidou Grid Bounds|Beidou Grid Bounds]]
- [[_COMMUNITY_DEM 3D Tiles Export|DEM 3D Tiles Export]]
- [[_COMMUNITY_Beidou Code Encoding|Beidou Code Encoding]]
- [[_COMMUNITY_CityDB Tiles Export|CityDB Tiles Export]]
- [[_COMMUNITY_GeoSOT Grid Docs|GeoSOT Grid Docs]]

## God Nodes (most connected - your core abstractions)
1. `parse_buildings()` - 15 edges
2. `prepare_dem()` - 10 edges
3. `polygon_from_relation()` - 10 edges
4. `createRenderer()` - 9 edges
5. `polyhedral_surface_wkt()` - 9 edges
6. `main()` - 9 edges
7. `upsert_citydb_relief()` - 8 edges
8. `main()` - 8 edges
9. `Building` - 8 edges
10. `Terrain Elevation Sampling` - 8 edges

## Surprising Connections (you probably didn't know these)
- `Cesium Tianditu Viewer` --references--> `createCollections()`  [INFERRED]
  frontend/tianditu-3d.html → js/BeidouAirspaceGrid.js
- `DEM Raster Terrain` --implements--> `build_mesh()`  [INFERRED]
  docs/dem_terrain_to_3dcitydb_plan.md → scripts/export_dem_3dtiles.py
- `Grid Level Auto Selection` --rationale_for--> `chooseAutoLevel()`  [EXTRACTED]
  docs/beidou-airspace-grid-visualization-plan.md → js/BeidouAirspaceGrid.js
- `Airspace Grid Visualization` --implements--> `create()`  [EXTRACTED]
  docs/beidou-airspace-grid-visualization-plan.md → js/BeidouAirspaceGrid.js
- `Height Layer Stack` --implements--> `getStackedHeightBounds()`  [EXTRACTED]
  docs/beidou-airspace-grid-visualization-plan.md → js/BeidouGridBounds.js

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Terrain-aware LoD1 export flow** — dem_raster_terrain, terrain_elevation_sampling, osm_building_import, lod1_building_solid, citydb_3dtiles_workflow [INFERRED 0.85]
- **Beidou airspace visualization flow** — geosot_grid, beidou_grid_code, bgc_3d_encoding, height_layer_stack, airspace_grid_visualization, cesium_tianditu_viewer [EXTRACTED 1.00]
- **iBEST-DB grid and path capabilities** — ibestdb_gridcell, ibestdb_geomgrids, beidou_grid_code, ibestdb_path_planning, ibestdb_trajectory [INFERRED 0.75]

## Communities (9 total, 0 thin omitted)

### Community 0 - "OSM CityDB Import"
Cohesion: 0.12
Nodes (39): Exception, MultiPolygon, Polygon, apply_terrain_elevations(), assemble_rings(), build_overpass_query(), Building, clean_multipolygon() (+31 more)

### Community 1 - "Cesium Airspace Renderer"
Cohesion: 0.18
Nodes (24): addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel(), clamp(), create(), createCollections(), createColor() (+16 more)

### Community 2 - "DEM Terrain Import"
Cohesion: 0.21
Nodes (25): buffered_projected_bounds(), cleanup_citydb_feature(), create_terrain_schema(), DemPaths, DemStats, download(), ensure_gdal_tools(), import_raster() (+17 more)

### Community 3 - "Terrain Buildings Planning"
Cohesion: 0.19
Nodes (18): 3DCityDB 5.x, 3DCityDB Relief Schema, DEM Raster Terrain, DEM Terrain to 3DCityDB Plan, Development Environment, Terrain Vertical Datum Record, GEOVIS iBEST-DB Trajectory Quick Reference, Huaguoshan Target Area (+10 more)

### Community 4 - "Beidou Grid Bounds"
Cohesion: 0.27
Nodes (17): assertFiniteNumber(), assertLevel(), clampIndex(), distanceMeters(), firstLevelBounds(), getCellBounds(), getHeightBounds(), getHeightBoundsByLayer() (+9 more)

### Community 5 - "DEM 3D Tiles Export"
Cohesion: 0.28
Nodes (14): ArgumentParser, ndarray, build_mesh(), build_parser(), enu_axes(), main(), make_tile_transform(), MeshData (+6 more)

### Community 6 - "Beidou Code Encoding"
Cohesion: 0.32
Nodes (12): BGC 3D Encoding, assertFiniteNumber(), assertLevel(), clampIndex(), encode2D(), encode2DSegments(), encode3D(), encodeFirstLevel() (+4 more)

### Community 7 - "CityDB Tiles Export"
Cohesion: 0.35
Nodes (12): 3DCityDB to 3D Tiles Workflow, 3D Tiles Materialized View Contract, citydb-3dtiles-export skill, pg2b3dm Export, create_materialized_view(), log(), resolve_pg2b3dm(), run_advice() (+4 more)

### Community 8 - "GeoSOT Grid Docs"
Cohesion: 0.33
Nodes (12): Airspace Grid Visualization, Beidou Airspace Grid Visualization Plan, Beidou Grid Code Algorithm, Beidou Grid Code, Cesium Tianditu Viewer, Tianditu 3D Huaguoshan Frontend, GeoSOT Grid, GEOVIS iBEST-DB Manual (+4 more)

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `3DCityDB 5.x` connect `Terrain Buildings Planning` to `CityDB Tiles Export`?**
  _High betweenness centrality (0.288) - this node is a cross-community bridge._
- **Why does `3DCityDB to 3D Tiles Workflow` connect `CityDB Tiles Export` to `GeoSOT Grid Docs`, `Terrain Buildings Planning`?**
  _High betweenness centrality (0.284) - this node is a cross-community bridge._
- **Why does `Cesium Tianditu Viewer` connect `GeoSOT Grid Docs` to `Cesium Airspace Renderer`, `CityDB Tiles Export`?**
  _High betweenness centrality (0.232) - this node is a cross-community bridge._
- **What connects `Read a small clipped DEM through GDAL XYZ output as a row-major 2D array.` to the rest of the system?**
  _1 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `OSM CityDB Import` be split into smaller, more focused modules?**
  _Cohesion score 0.1202020202020202 - nodes in this community are weakly interconnected._
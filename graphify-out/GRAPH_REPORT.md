# Graph Report - .  (2026-07-02)

## Corpus Check
- 14 files · ~60,612 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 701 nodes · 1404 edges · 35 communities (27 shown, 8 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 84 edges (avg confidence: 0.94)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Obstacle Refresh Scripts|Obstacle Refresh Scripts]]
- [[_COMMUNITY_No-Fly Feature Plan|No-Fly Feature Plan]]
- [[_COMMUNITY_Refined Obstacle Planning|Refined Obstacle Planning]]
- [[_COMMUNITY_CityDB GGER RPCs|CityDB GGER RPCs]]
- [[_COMMUNITY_Height Datum Semantics|Height Datum Semantics]]
- [[_COMMUNITY_OSM Building Import|OSM Building Import]]
- [[_COMMUNITY_DEM Terrain Import|DEM Terrain Import]]
- [[_COMMUNITY_Airspace Seed Data|Airspace Seed Data]]
- [[_COMMUNITY_GGER Airspace Rendering|GGER Airspace Rendering]]
- [[_COMMUNITY_Beidou Airspace Rendering|Beidou Airspace Rendering]]
- [[_COMMUNITY_Airspace Height Concepts|Airspace Height Concepts]]
- [[_COMMUNITY_Multi-Source Obstacles|Multi-Source Obstacles]]
- [[_COMMUNITY_Project Documentation|Project Documentation]]
- [[_COMMUNITY_GGER Bounds Math|GGER Bounds Math]]
- [[_COMMUNITY_Beidou Grid Encoding|Beidou Grid Encoding]]
- [[_COMMUNITY_Beidou Bounds Math|Beidou Bounds Math]]
- [[_COMMUNITY_GGER Grid Encoding|GGER Grid Encoding]]
- [[_COMMUNITY_DEM 3D Tiles Export|DEM 3D Tiles Export]]
- [[_COMMUNITY_Obstacle Todo Items|Obstacle Todo Items]]
- [[_COMMUNITY_API Schema RPC|API Schema RPC]]
- [[_COMMUNITY_Terrain LOD Queries|Terrain LOD Queries]]
- [[_COMMUNITY_No-Fly Zone Table|No-Fly Zone Table]]
- [[_COMMUNITY_Temp Control Table|Temp Control Table]]
- [[_COMMUNITY_Shared GGER Concept|Shared GGER Concept]]
- [[_COMMUNITY_Materialized Views|Materialized Views]]
- [[_COMMUNITY_PostgREST CRUD|PostgREST CRUD]]
- [[_COMMUNITY_Refresh Workflow|Refresh Workflow]]
- [[_COMMUNITY_Terrain LOD Plan|Terrain LOD Plan]]
- [[_COMMUNITY_Flight Trajectories|Flight Trajectories]]
- [[_COMMUNITY_Python Typing Any|Python Typing Any]]
- [[_COMMUNITY_SQL Composed Objects|SQL Composed Objects]]
- [[_COMMUNITY_Database Connection|Database Connection]]
- [[_COMMUNITY_Database Cursor|Database Cursor]]
- [[_COMMUNITY_iBEST GGER Validation|iBEST GGER Validation]]
- [[_COMMUNITY_Python Namespace|Python Namespace]]

## God Nodes (most connected - your core abstractions)
1. `空域禁限飞功能实施计划` - 72 edges
2. `空域禁限飞高度基准完整语义支持计划` - 64 edges
3. `精细飞行障碍 geomgrids 避障实施方案` - 55 edges
4. `多源飞行障碍 geomgrids 视图实施计划` - 32 edges
5. `天地图三维底图服务测试 · 花果山` - 27 edges
6. `qname()` - 22 edges
7. `rebuild_views()` - 21 edges
8. `main()` - 19 edges
9. `parse_buildings()` - 15 edges
10. `rebuild_materialized_view()` - 13 edges

## Surprising Connections (you probably didn't know these)
- `GeoSOT 3D Height Layer` --conceptually_related_to--> `getHeightBounds()`  [INFERRED]
  docs/gger-grid-code-algorithm.md → js/GGERGridBounds.js
- `Terrain Obstacles` --semantically_similar_to--> `Terrain Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/airspace_no_fly_feature_plan.md
- `Terrain Obstacles` --semantically_similar_to--> `Terrain Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/refined_flight_obstacles_plan.md
- `Flight Obstacles` --semantically_similar_to--> `Flight Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/airspace_no_fly_feature_plan.md
- `Flight Obstacles` --semantically_similar_to--> `Flight Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/refined_flight_obstacles_plan.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Flight Obstacles changed-doc theme** — pi_todos_a37713d9_flight_obstacles, pi_todos_c3e03f1c_flight_obstacles, docs_airspace_height_datum_semantics_plan_flight_obstacles, docs_airspace_no_fly_feature_plan_flight_obstacles, docs_multi_source_flight_obstacles_plan_flight_obstacles, docs_refined_flight_obstacles_plan_flight_obstacles, frontend_tianditu_3d_flight_obstacles [INFERRED 0.85]
- **No-Fly Zones changed-doc theme** — pi_todos_c3e03f1c_no_fly_zones, docs_airspace_height_datum_semantics_plan_no_fly_zones, docs_airspace_no_fly_feature_plan_no_fly_zones, docs_multi_source_flight_obstacles_plan_no_fly_zones, docs_refined_flight_obstacles_plan_no_fly_zones, frontend_tianditu_3d_no_fly_zones [INFERRED 0.85]
- **GGER Grid changed-doc theme** — docs_airspace_height_datum_semantics_plan_gger_grid, docs_airspace_no_fly_feature_plan_gger_grid, docs_multi_source_flight_obstacles_plan_gger_grid, docs_refined_flight_obstacles_plan_gger_grid, frontend_tianditu_3d_gger_grid [INFERRED 0.85]

## Communities (35 total, 8 thin omitted)

### Community 0 - "Obstacle Refresh Scripts"
Cohesion: 0.08
Nodes (85): Composable, RuntimeError, bool_literal(), build_airspace_tables_sql(), build_airspace_terrain_blocks_cte(), build_bbox_prism_function_sql(), build_building_where_clause(), build_codes_view_sql() (+77 more)

### Community 1 - "No-Fly Feature Plan"
Cohesion: 0.03
Nodes (73): 1. 目标, 10.1 P1 临时风险记录, 10.2 P1 自动刷新 grids：LISTEN/NOTIFY + worker, 10. P1 管理能力：PostgREST 直接 CRUD, 11. 前端实施计划, 11.1 图层与文案调整, 11.2 样式增强, 11.3 详情面板增强 (+65 more)

### Community 2 - "Refined Obstacle Planning"
Cohesion: 0.04
Nodes (56): 1. 背景、文档分工与目标, 10. 验收标准, 10.1 Airspace 精度验收, 10.2 Terrain 精度验收, 10.3 路径规划验收, 11. 测试方案, 11.1 单元 SQL 测试, 11.2 DEM block 测试 (+48 more)

### Community 3 - "CityDB GGER RPCs"
Cohesion: 0.09
Nodes (54): get_citydb_feature_gger_grids RPC, ST_WithBox GGER bbox output, citydb_grid.flight_obstacles Materialized View, GeomGrids Obstacle Index, GIN geomgrids Index, PostgREST GGER + Box RPC, ST_FindGridsPath Wrapper View, bool_literal() (+46 more)

### Community 4 - "Height Datum Semantics"
Cohesion: 0.04
Nodes (47): 1. 背景与问题, 10.1 PostgREST direct CRUD, 10.2 flight obstacles RPC, 10. RPC / 前端展示影响, 11.1 数据模型验收, 11.2 前端保存验收, 11.3 AMSL 校验验收, 11.4 AGL grids 验收 (+39 more)

### Community 5 - "OSM Building Import"
Cohesion: 0.12
Nodes (39): Exception, MultiPolygon, Polygon, apply_terrain_elevations(), assemble_rings(), build_overpass_query(), Building, clean_multipolygon() (+31 more)

### Community 6 - "DEM Terrain Import"
Cohesion: 0.15
Nodes (32): 3DCityDB Relief Schema, DEM Raster Terrain, DEM Terrain to 3DCityDB Plan, Terrain Vertical Datum Record, buffered_projected_bounds(), cleanup_citydb_feature(), create_terrain_schema(), DemPaths (+24 more)

### Community 7 - "Airspace Seed Data"
Cohesion: 0.15
Nodes (30): Path, feature_value(), geometry_expression(), insert_no_fly_zone(), insert_temp_control(), load_geojson(), main(), parse_args() (+22 more)

### Community 8 - "GGER Airspace Rendering"
Cohesion: 0.14
Nodes (29): Camera-driven GGER Level Selection, Cesium Rendering and Performance Controls, GGER Airspace Visualization, Visible GGER Cell Enumeration, addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel() (+21 more)

### Community 9 - "Beidou Airspace Rendering"
Cohesion: 0.18
Nodes (25): addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel(), clamp(), create(), createCollections(), createColor() (+17 more)

### Community 10 - "Airspace Height Concepts"
Cohesion: 0.08
Nodes (25): AGL Height Datum, AMSL Height Datum, BBox Fallback Mode, Height Datum Semantics, Height Semantics, BBox Fallback Mode, AGL Height Datum, Airspace Admin (+17 more)

### Community 11 - "Multi-Source Obstacles"
Cohesion: 0.08
Nodes (25): Block Prism Mode, Geomgrids, Polygon Prism Mode, 1. 目标, 10. 实施状态, 2. 总体架构, 3. 统一字段契约, 4. 分来源实现 (+17 more)

### Community 12 - "Project Documentation"
Cohesion: 0.17
Nodes (22): 3DCityDB 5.x, 3DCityDB to 3D Tiles Workflow, 3D Tiles Materialized View Contract, citydb-3dtiles-export skill, Development Environment, GEOVIS iBEST-DB Trajectory Quick Reference, Huaguoshan Target Area, iBEST-DB Trajectory (+14 more)

### Community 13 - "GGER Bounds Math"
Cohesion: 0.23
Nodes (21): GGER Height Layer Stacking, arcSecondFractionsToHeight(), assertFiniteNumber(), assertLatitude(), assertLevel(), assertLongitude(), clamp(), coordinateToIndex() (+13 more)

### Community 14 - "Beidou Grid Encoding"
Cohesion: 0.20
Nodes (19): Beidou Grid Code Algorithm, Beidou Grid Code, BGC 3D Encoding, GeoSOT Grid, GEOVIS iBEST-DB Manual, iBEST-DB GeomGrids, iBEST-DB GridCell, iBEST-DB Grid Path Planning (+11 more)

### Community 15 - "Beidou Bounds Math"
Cohesion: 0.27
Nodes (17): assertFiniteNumber(), assertLevel(), clampIndex(), distanceMeters(), firstLevelBounds(), getCellBounds(), getHeightBounds(), getHeightBoundsByLayer() (+9 more)

### Community 16 - "GGER Grid Encoding"
Cohesion: 0.26
Nodes (15): GGER Codes View, Extended DMS 32-bit Index, GeoSOT 3D Height Layer, GGER / GeoSOT Encoding, 2D/3D Morton Digit Interleaving, arcSecondFractionsToExtendedDmsIndex(), assertFiniteNumber(), assertLatitude() (+7 more)

### Community 17 - "DEM 3D Tiles Export"
Cohesion: 0.28
Nodes (14): ArgumentParser, ndarray, build_mesh(), build_parser(), enu_axes(), main(), make_tile_transform(), MeshData (+6 more)

### Community 18 - "Obstacle Todo Items"
Cohesion: 0.14
Nodes (14): Flight Obstacles, No-Fly Zones, Terrain Obstacles, Flight Obstacles, No-Fly Zones, Terrain Obstacles, Flight Obstacles, Terrain Obstacles (+6 more)

### Community 19 - "API Schema RPC"
Cohesion: 0.40
Nodes (5): API Schema RPC, API Schema RPC, API Schema RPC, API Schema RPC, 使用 API schema 管理 RPC

### Community 20 - "Terrain LOD Queries"
Cohesion: 0.40
Nodes (5): BBox and Center-priority Terrain Loading, Implemented Terrain LOD Results, Terrain LOD Levels, list_flight_obstacles_gger_lod RPC, citydb_grid.obstacles_terrain_lod

### Community 21 - "No-Fly Zone Table"
Cohesion: 0.67
Nodes (3): airspace.no_fly_zone, airspace.no_fly_zone, airspace.no_fly_zone

### Community 22 - "Temp Control Table"
Cohesion: 0.67
Nodes (3): airspace.temp_control_zone, airspace.temp_control_zone, airspace.temp_control_zone

### Community 23 - "Shared GGER Concept"
Cohesion: 0.67
Nodes (3): GGER Grid, GGER Grid, GGER Grid

### Community 24 - "Materialized Views"
Cohesion: 0.67
Nodes (3): Materialized Views, Materialized Views, Materialized Views

### Community 25 - "PostgREST CRUD"
Cohesion: 0.67
Nodes (3): PostgREST CRUD API, PostgREST CRUD API, PostgREST CRUD API

### Community 26 - "Refresh Workflow"
Cohesion: 0.67
Nodes (3): Refresh Workflow, Refresh Workflow, Refresh Workflow

## Knowledge Gaps
- **176 isolated node(s):** `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation`, `GeomGrids Obstacle Index`, `GIN geomgrids Index`, `ST_FindGridsPath Wrapper View` (+171 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ScriptError` connect `CityDB GGER RPCs` to `Obstacle Refresh Scripts`?**
  _High betweenness centrality (0.060) - this node is a cross-community bridge._
- **What connects `Read a small clipped DEM through GDAL XYZ output as a row-major 2D array.`, `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation` to the rest of the system?**
  _214 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Obstacle Refresh Scripts` be split into smaller, more focused modules?**
  _Cohesion score 0.07578659370725034 - nodes in this community are weakly interconnected._
- **Should `No-Fly Feature Plan` be split into smaller, more focused modules?**
  _Cohesion score 0.0273972602739726 - nodes in this community are weakly interconnected._
- **Should `Refined Obstacle Planning` be split into smaller, more focused modules?**
  _Cohesion score 0.03571428571428571 - nodes in this community are weakly interconnected._
- **Should `CityDB GGER RPCs` be split into smaller, more focused modules?**
  _Cohesion score 0.09494949494949495 - nodes in this community are weakly interconnected._
- **Should `Height Datum Semantics` be split into smaller, more focused modules?**
  _Cohesion score 0.0425531914893617 - nodes in this community are weakly interconnected._
# Graph Report - /Users/madizm/geovis/huaguoshan  (2026-07-02)

## Corpus Check
- 4 files · ~69,986 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 720 nodes · 1418 edges · 39 communities (31 shown, 8 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 83 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Obstacle Grid Refresh|Obstacle Grid Refresh]]
- [[_COMMUNITY_Airspace Feature Planning|Airspace Feature Planning]]
- [[_COMMUNITY_Height Datum Semantics|Height Datum Semantics]]
- [[_COMMUNITY_Flight Obstacle Refresh|Flight Obstacle Refresh]]
- [[_COMMUNITY_OSM Building Import|OSM Building Import]]
- [[_COMMUNITY_Terrain Obstacle Roadmap|Terrain Obstacle Roadmap]]
- [[_COMMUNITY_DEM Terrain Import|DEM Terrain Import]]
- [[_COMMUNITY_Obstacle Source Model|Obstacle Source Model]]
- [[_COMMUNITY_GGER Visualization|GGER Visualization]]
- [[_COMMUNITY_Frontend Airspace UI|Frontend Airspace UI]]
- [[_COMMUNITY_Beidou Grid Visualization|Beidou Grid Visualization]]
- [[_COMMUNITY_GGER Obstacle RPCs|GGER Obstacle RPCs]]
- [[_COMMUNITY_3DCityDB Tiles Workflow|3DCityDB Tiles Workflow]]
- [[_COMMUNITY_GGER Bounds Encoding|GGER Bounds Encoding]]
- [[_COMMUNITY_Airspace Zone Seeding|Airspace Zone Seeding]]
- [[_COMMUNITY_Beidou Grid Encoding|Beidou Grid Encoding]]
- [[_COMMUNITY_Flight Path Planning Playback|Flight Path Planning Playback]]
- [[_COMMUNITY_Beidou Bounds Encoding|Beidou Bounds Encoding]]
- [[_COMMUNITY_DEM Tiles Export|DEM Tiles Export]]
- [[_COMMUNITY_Airspace Refresh Watcher|Airspace Refresh Watcher]]
- [[_COMMUNITY_Obstacle UI Concepts|Obstacle UI Concepts]]
- [[_COMMUNITY_Flight Path Safety Heights|Flight Path Safety Heights]]
- [[_COMMUNITY_Terrain LOD Query|Terrain LOD Query]]
- [[_COMMUNITY_API Schema RPC|API Schema RPC]]
- [[_COMMUNITY_Materialized Views|Materialized Views]]
- [[_COMMUNITY_PostgREST CRUD API|PostgREST CRUD API]]
- [[_COMMUNITY_Refresh Workflow|Refresh Workflow]]
- [[_COMMUNITY_Temporary Control Zones|Temporary Control Zones]]
- [[_COMMUNITY_BBox Fallback Mode|BBox Fallback Mode]]
- [[_COMMUNITY_GGER Grid Concept|GGER Grid Concept]]
- [[_COMMUNITY_Polygon Prism Mode|Polygon Prism Mode]]
- [[_COMMUNITY_Terrain Display Separation|Terrain Display Separation]]
- [[_COMMUNITY_Python Any Type|Python Any Type]]
- [[_COMMUNITY_SQL Composed Type|SQL Composed Type]]
- [[_COMMUNITY_Database Connection|Database Connection]]
- [[_COMMUNITY_Database Cursor|Database Cursor]]
- [[_COMMUNITY_GGER Validation|GGER Validation]]
- [[_COMMUNITY_Flight Path State|Flight Path State]]
- [[_COMMUNITY_Parser Namespace|Parser Namespace]]

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
  .pi/todos/a37713d9.md → docs/multi_source_flight_obstacles_plan.md
- `Terrain Obstacles` --semantically_similar_to--> `Terrain Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → frontend/tianditu-3d.html
- `Flight Obstacles` --semantically_similar_to--> `Flight Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/airspace_no_fly_feature_plan.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Flight Path Result To Frontend Playback Flow** — docs_flight_path_planning_management_plan_flight_path_plan_result_schema, docs_flight_path_camera_follow_effects_plan_flight_path_playback_data, frontend_tianditu_3d_renderflightpathresult [INFERRED 0.85]
- **Flight Path Planner API UI Contract** — docs_flight_path_planning_management_plan_postgrest_flight_path_rpcs, frontend_tianditu_3d_flight_path_planner_ui, frontend_tianditu_3d_flightpathpayload, frontend_tianditu_3d_computeflightpathplan [EXTRACTED 1.00]
- **Height Obstacle Grid Safety Pattern** — docs_flight_path_planning_management_plan_height_datum_handling, docs_flight_path_planning_management_plan_obstacle_avoidance_inputs, docs_flight_path_camera_follow_effects_plan_agl_clearance_band, docs_flight_path_camera_follow_effects_plan_route_grid_scanning [INFERRED 0.85]

## Communities (39 total, 8 thin omitted)

### Community 0 - "Obstacle Grid Refresh"
Cohesion: 0.08
Nodes (84): Composable, bool_literal(), build_airspace_tables_sql(), build_airspace_terrain_blocks_cte(), build_bbox_prism_function_sql(), build_building_where_clause(), build_codes_view_sql(), build_empty_obstacle_view_sql() (+76 more)

### Community 1 - "Airspace Feature Planning"
Cohesion: 0.03
Nodes (73): 1. 目标, 10.1 P1 临时风险记录, 10.2 P1 自动刷新 grids：LISTEN/NOTIFY + worker, 10. P1 管理能力：PostgREST 直接 CRUD, 11. 前端实施计划, 11.1 图层与文案调整, 11.2 样式增强, 11.3 详情面板增强 (+65 more)

### Community 2 - "Height Datum Semantics"
Cohesion: 0.04
Nodes (48): 1. 背景与问题, 10.1 PostgREST direct CRUD, 10.2 flight obstacles RPC, 10. RPC / 前端展示影响, 11.1 数据模型验收, 11.2 前端保存验收, 11.3 AMSL 校验验收, 11.4 AGL grids 验收 (+40 more)

### Community 3 - "Flight Obstacle Refresh"
Cohesion: 0.12
Nodes (47): bool_literal(), build_codes_view_sql(), build_dry_run_sql(), build_grids_expression(), build_materialized_view_sql(), build_public_wrapper_sql(), build_ranked_geometry_cte(), build_where_clause() (+39 more)

### Community 4 - "OSM Building Import"
Cohesion: 0.12
Nodes (39): Exception, MultiPolygon, Polygon, apply_terrain_elevations(), assemble_rings(), build_overpass_query(), Building, clean_multipolygon() (+31 more)

### Community 5 - "Terrain Obstacle Roadmap"
Cohesion: 0.05
Nodes (41): 1. 背景、文档分工与目标, 10. 验收标准, 10.1 Airspace 精度验收, 10.2 Terrain 精度验收, 10.3 路径规划验收, 11. 测试方案, 11.1 单元 SQL 测试, 11.2 DEM block 测试 (+33 more)

### Community 6 - "DEM Terrain Import"
Cohesion: 0.15
Nodes (33): 3DCityDB Relief Schema, DEM Raster Terrain, DEM Terrain to 3DCityDB Plan, Terrain Vertical Datum Record, iBEST-DB Grid Path Planning, buffered_projected_bounds(), cleanup_citydb_feature(), create_terrain_schema() (+25 more)

### Community 7 - "Obstacle Source Model"
Cohesion: 0.06
Nodes (33): airspace.no_fly_zone, Block Prism Mode, Geomgrids, 1. 目标, 10. 实施状态, 2. 总体架构, 3. 统一字段契约, 4. 分来源实现 (+25 more)

### Community 8 - "GGER Visualization"
Cohesion: 0.14
Nodes (29): Camera-driven GGER Level Selection, Cesium Rendering and Performance Controls, GGER Airspace Visualization, Visible GGER Cell Enumeration, addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel() (+21 more)

### Community 9 - "Frontend Airspace UI"
Cohesion: 0.07
Nodes (30): AGL Height Datum, AMSL Height Datum, Height Datum Semantics, Height Semantics, Height Semantics, AGL Height Datum, Airspace Admin, Airspace Admin UI (+22 more)

### Community 10 - "Beidou Grid Visualization"
Cohesion: 0.18
Nodes (25): addEdge(), addRectangleEdges(), addVerticalEdges(), chooseAutoLevel(), clamp(), create(), createCollections(), createColor() (+17 more)

### Community 11 - "GGER Obstacle RPCs"
Cohesion: 0.15
Nodes (22): get_citydb_feature_gger_grids RPC, ST_WithBox GGER bbox output, citydb_grid.flight_obstacles Materialized View, GeomGrids Obstacle Index, GGER Codes View, GIN geomgrids Index, PostgREST GGER + Box RPC, ST_FindGridsPath Wrapper View (+14 more)

### Community 12 - "3DCityDB Tiles Workflow"
Cohesion: 0.17
Nodes (22): 3DCityDB 5.x, 3DCityDB to 3D Tiles Workflow, 3D Tiles Materialized View Contract, citydb-3dtiles-export skill, Development Environment, GEOVIS iBEST-DB Trajectory Quick Reference, Huaguoshan Target Area, iBEST-DB Trajectory (+14 more)

### Community 13 - "GGER Bounds Encoding"
Cohesion: 0.23
Nodes (21): GGER Height Layer Stacking, arcSecondFractionsToHeight(), assertFiniteNumber(), assertLatitude(), assertLevel(), assertLongitude(), clamp(), coordinateToIndex() (+13 more)

### Community 14 - "Airspace Zone Seeding"
Cohesion: 0.25
Nodes (19): RuntimeError, feature_value(), geometry_expression(), insert_no_fly_zone(), insert_temp_control(), load_geojson(), main(), parse_args() (+11 more)

### Community 15 - "Beidou Grid Encoding"
Cohesion: 0.22
Nodes (18): Beidou Grid Code Algorithm, Beidou Grid Code, BGC 3D Encoding, GeoSOT Grid, GEOVIS iBEST-DB Manual, iBEST-DB GeomGrids, iBEST-DB GridCell, assertFiniteNumber() (+10 more)

### Community 16 - "Flight Path Planning Playback"
Cohesion: 0.12
Nodes (18): Cesium animation objects, Chase camera, Flight Path Camera Follow Effects Plan, Flight path playback data, FPV camera, Playback HUD controls, Route grid scanning, flight_path.plan_point schema (+10 more)

### Community 17 - "Beidou Bounds Encoding"
Cohesion: 0.27
Nodes (17): assertFiniteNumber(), assertLevel(), clampIndex(), distanceMeters(), firstLevelBounds(), getCellBounds(), getHeightBounds(), getHeightBoundsByLayer() (+9 more)

### Community 18 - "DEM Tiles Export"
Cohesion: 0.28
Nodes (14): ArgumentParser, ndarray, build_mesh(), build_parser(), enu_axes(), main(), make_tile_transform(), MeshData (+6 more)

### Community 19 - "Airspace Refresh Watcher"
Cohesion: 0.32
Nodes (12): Path, listen_loop(), log(), main(), parse_args(), payload_summary(), Any, Connection (+4 more)

### Community 20 - "Obstacle UI Concepts"
Cohesion: 0.29
Nodes (7): Flight Obstacles, Terrain Obstacles, Flight Obstacles, Terrain Obstacles, 地形grids只显示fine级别，统一飞行障碍查询接口, Flight Obstacles, Terrain Obstacles

### Community 21 - "Flight Path Safety Heights"
Cohesion: 0.40
Nodes (5): AGL clearance band, Height datum handling, Obstacle avoidance inputs, ST_FindGridsPath workflow, flightPathPayload

### Community 22 - "Terrain LOD Query"
Cohesion: 0.40
Nodes (5): BBox and Center-priority Terrain Loading, Implemented Terrain LOD Results, Terrain LOD Levels, list_flight_obstacles_gger_lod RPC, citydb_grid.obstacles_terrain_lod

### Community 23 - "API Schema RPC"
Cohesion: 0.50
Nodes (4): API Schema RPC, API Schema RPC, API Schema RPC, 使用 API schema 管理 RPC

### Community 24 - "Materialized Views"
Cohesion: 0.50
Nodes (4): Materialized Views, Materialized Views, Materialized Views, Materialized Views

### Community 25 - "PostgREST CRUD API"
Cohesion: 0.50
Nodes (4): PostgREST CRUD API, PostgREST CRUD API, PostgREST CRUD API, PostgREST CRUD API

### Community 26 - "Refresh Workflow"
Cohesion: 0.50
Nodes (4): Refresh Workflow, Refresh Workflow, Refresh Workflow, Refresh Workflow

### Community 27 - "Temporary Control Zones"
Cohesion: 0.67
Nodes (3): airspace.temp_control_zone, airspace.temp_control_zone, airspace.temp_control_zone

### Community 28 - "BBox Fallback Mode"
Cohesion: 0.67
Nodes (3): BBox Fallback Mode, BBox Fallback Mode, BBox Fallback Mode

### Community 29 - "GGER Grid Concept"
Cohesion: 0.67
Nodes (3): GGER Grid, GGER Grid, GGER Grid

### Community 30 - "Polygon Prism Mode"
Cohesion: 0.67
Nodes (3): Polygon Prism Mode, Polygon Prism Mode, Polygon Prism Mode

## Knowledge Gaps
- **190 isolated node(s):** `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation`, `GeomGrids Obstacle Index`, `GIN geomgrids Index`, `ST_FindGridsPath Wrapper View` (+185 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ScriptError` connect `Flight Obstacle Refresh` to `Airspace Zone Seeding`?**
  _High betweenness centrality (0.057) - this node is a cross-community bridge._
- **Why does `ScriptError` connect `Obstacle Grid Refresh` to `Airspace Zone Seeding`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._
- **What connects `Read a small clipped DEM through GDAL XYZ output as a row-major 2D array.`, `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation` to the rest of the system?**
  _228 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Obstacle Grid Refresh` be split into smaller, more focused modules?**
  _Cohesion score 0.0773109243697479 - nodes in this community are weakly interconnected._
- **Should `Airspace Feature Planning` be split into smaller, more focused modules?**
  _Cohesion score 0.0273972602739726 - nodes in this community are weakly interconnected._
- **Should `Height Datum Semantics` be split into smaller, more focused modules?**
  _Cohesion score 0.041666666666666664 - nodes in this community are weakly interconnected._
- **Should `Flight Obstacle Refresh` be split into smaller, more focused modules?**
  _Cohesion score 0.11879432624113476 - nodes in this community are weakly interconnected._
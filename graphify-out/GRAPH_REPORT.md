# Graph Report - .  (2026-07-04)

## Corpus Check
- 23 files · ~74,808 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 733 nodes · 1359 edges · 51 communities (37 shown, 14 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 64 edges (avg confidence: 0.93)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Python Database Utilities|Python Database Utilities]]
- [[_COMMUNITY_MVP Frontend Plan|MVP Frontend Plan]]
- [[_COMMUNITY_Obstacle Grid ADRs|Obstacle Grid ADRs]]
- [[_COMMUNITY_CityDB Obstacle Refresh|CityDB Obstacle Refresh]]
- [[_COMMUNITY_OSM Building Import|OSM Building Import]]
- [[_COMMUNITY_Height Semantics Plan|Height Semantics Plan]]
- [[_COMMUNITY_3DCityDB Terrain Data|3DCityDB Terrain Data]]
- [[_COMMUNITY_Airspace Event Domain|Airspace Event Domain]]
- [[_COMMUNITY_GGER Obstacle Architecture|GGER Obstacle Architecture]]
- [[_COMMUNITY_PostgREST Grid RPCs|PostgREST Grid RPCs]]
- [[_COMMUNITY_GGER Height Bounds|GGER Height Bounds]]
- [[_COMMUNITY_BeiDou Grid Reference|BeiDou Grid Reference]]
- [[_COMMUNITY_Constraint Editor UI|Constraint Editor UI]]
- [[_COMMUNITY_Seed Airspace Zones|Seed Airspace Zones]]
- [[_COMMUNITY_BeiDou Bounds Module|BeiDou Bounds Module]]
- [[_COMMUNITY_DEM Tiles Export|DEM Tiles Export]]
- [[_COMMUNITY_3D Tiles Export|3D Tiles Export]]
- [[_COMMUNITY_Airspace Grid Visualization|Airspace Grid Visualization]]
- [[_COMMUNITY_Airspace Watch Worker|Airspace Watch Worker]]
- [[_COMMUNITY_Flight Path Camera|Flight Path Camera]]
- [[_COMMUNITY_Flight Path Workbench|Flight Path Workbench]]
- [[_COMMUNITY_Obstacle Domain Concepts|Obstacle Domain Concepts]]
- [[_COMMUNITY_Obstacle Situation Layer|Obstacle Situation Layer]]
- [[_COMMUNITY_Grid Refresh Tests|Grid Refresh Tests]]
- [[_COMMUNITY_API Schema RPC|API Schema RPC]]
- [[_COMMUNITY_Terrain LOD Loading|Terrain LOD Loading]]
- [[_COMMUNITY_Route Planning Heights|Route Planning Heights]]
- [[_COMMUNITY_No Fly Zone Table|No Fly Zone Table]]
- [[_COMMUNITY_Temp Control Zone Table|Temp Control Zone Table]]
- [[_COMMUNITY_BBox Fallback Mode|BBox Fallback Mode]]
- [[_COMMUNITY_Block Prism Mode|Block Prism Mode]]
- [[_COMMUNITY_Geomgrids|Geomgrids]]
- [[_COMMUNITY_Materialized Views|Materialized Views]]
- [[_COMMUNITY_Polygon Prism Mode|Polygon Prism Mode]]
- [[_COMMUNITY_PostgREST CRUD API|PostgREST CRUD API]]
- [[_COMMUNITY_Refresh Workflow|Refresh Workflow]]
- [[_COMMUNITY_Trajectory Reference|Trajectory Reference]]
- [[_COMMUNITY_Domain Documentation|Domain Documentation]]
- [[_COMMUNITY_GitHub Issue Tracking|GitHub Issue Tracking]]
- [[_COMMUNITY_Triage Vocabulary|Triage Vocabulary]]
- [[_COMMUNITY_Terrain LOD Separation|Terrain LOD Separation]]
- [[_COMMUNITY_Camera Grid Level|Camera Grid Level]]
- [[_COMMUNITY_Cesium Performance|Cesium Performance]]
- [[_COMMUNITY_Visible Cell Enumeration|Visible Cell Enumeration]]
- [[_COMMUNITY_Playback HUD Controls|Playback HUD Controls]]
- [[_COMMUNITY_GGER Validation|GGER Validation]]
- [[_COMMUNITY_Python Any Type|Python Any Type]]
- [[_COMMUNITY_SQL Composition|SQL Composition]]
- [[_COMMUNITY_Database Connection|Database Connection]]
- [[_COMMUNITY_Database Cursor|Database Cursor]]
- [[_COMMUNITY_Python Namespace|Python Namespace]]

## God Nodes (most connected - your core abstractions)
1. `空域禁限飞功能实施计划` - 72 edges
2. `空域禁限飞高度基准完整语义支持计划` - 64 edges
3. `精细飞行障碍 geomgrids 避障实施方案` - 55 edges
4. `多源飞行障碍 geomgrids 视图实施计划` - 32 edges
5. `rebuild_views()` - 22 edges
6. `qname()` - 21 edges
7. `main()` - 19 edges
8. `parse_buildings()` - 15 edges
9. `refresh_views()` - 14 edges
10. `rebuild_materialized_view()` - 13 edges

## Surprising Connections (you probably didn't know these)
- `GeoSOT 3D Height Layer` --conceptually_related_to--> `getHeightBounds()`  [INFERRED]
  docs/gger-grid-code-algorithm.md → js/GGERGridBounds.js
- `Terrain Obstacles` --semantically_similar_to--> `Terrain Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/airspace_no_fly_feature_plan.md
- `Terrain Obstacles` --semantically_similar_to--> `Terrain Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/multi_source_flight_obstacles_plan.md
- `Flight Obstacles` --semantically_similar_to--> `Flight Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/airspace_no_fly_feature_plan.md
- `Flight Obstacles` --semantically_similar_to--> `Flight Obstacles`  [INFERRED] [semantically similar]
  .pi/todos/a37713d9.md → docs/multi_source_flight_obstacles_plan.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **MVP Shared Event Semantics** — context_mvp_event_queue, context_shared_event_workbench, docs_mvp_airspace_event_loop_design_unified_event_model, docs_adr_0003_use_shared_airspace_event_workbench_for_mvp_scenarios_shared_workbench_for_mvp_scenarios [EXTRACTED 1.00]
- **Airspace Spatial Reasoning Stack** — context_airspace_grid, context_intrusion_decision, docs_adr_0001_use_airspace_grid_as_core_spatial_index_postgis_precise_geometry, frontend_tianditu_3d_airspace_grid_ui_modules [INFERRED 0.85]

## Communities (51 total, 14 thin omitted)

### Community 0 - "Python Database Utilities"
Cohesion: 0.06
Nodes (99): Any, Composable, Composed, Connection, Cursor, Namespace, RuntimeError, _airspace_constraint_adapters() (+91 more)

### Community 1 - "MVP Frontend Plan"
Cohesion: 0.03
Nodes (73): 1. 目标, 10.1 P1 临时风险记录, 10.2 P1 自动刷新 grids：LISTEN/NOTIFY + worker, 10. P1 管理能力：PostgREST 直接 CRUD, 11. 前端实施计划, 11.1 图层与文案调整, 11.2 样式增强, 11.3 详情面板增强 (+65 more)

### Community 2 - "Obstacle Grid ADRs"
Cohesion: 0.04
Nodes (51): 1. 背景与问题, 10.1 PostgREST direct CRUD, 10.2 flight obstacles RPC, 10. RPC / 前端展示影响, 11.1 数据模型验收, 11.2 前端保存验收, 11.3 AMSL 校验验收, 11.4 AGL grids 验收 (+43 more)

### Community 3 - "CityDB Obstacle Refresh"
Cohesion: 0.12
Nodes (47): bool_literal(), build_codes_view_sql(), build_dry_run_sql(), build_grids_expression(), build_materialized_view_sql(), build_public_wrapper_sql(), build_ranked_geometry_cte(), build_where_clause() (+39 more)

### Community 4 - "OSM Building Import"
Cohesion: 0.12
Nodes (39): Exception, MultiPolygon, Polygon, apply_terrain_elevations(), assemble_rings(), build_overpass_query(), Building, clean_multipolygon() (+31 more)

### Community 5 - "Height Semantics Plan"
Cohesion: 0.05
Nodes (43): Height Semantics, 1. 背景、文档分工与目标, 10. 验收标准, 10.1 Airspace 精度验收, 10.2 Terrain 精度验收, 10.3 路径规划验收, 11. 测试方案, 11.1 单元 SQL 测试 (+35 more)

### Community 6 - "3DCityDB Terrain Data"
Cohesion: 0.13
Nodes (36): 3DCityDB 5.x, 3DCityDB Relief Schema, DEM Raster Terrain, DEM Terrain to 3DCityDB Plan, Terrain Vertical Datum Record, LoD1 Building Solid, OSM Building Import, OSM Buildings to 3DCityDB Plan (+28 more)

### Community 7 - "Airspace Event Domain"
Cohesion: 0.08
Nodes (26): 空域事件, 空域网格, 事件历史, 无人机林火巡查预警闭环, 入侵判定, 低空空域事件处置闭环, MVP 事件队列, 空域事件处置工作台 (+18 more)

### Community 8 - "GGER Obstacle Architecture"
Cohesion: 0.08
Nodes (26): GGER Grid, 1. 目标, 10. 实施状态, 2. 总体架构, 3. 统一字段契约, 4. 分来源实现, 4.1 建筑障碍, 4.2 地形障碍 (+18 more)

### Community 9 - "PostgREST Grid RPCs"
Cohesion: 0.15
Nodes (22): get_citydb_feature_gger_grids RPC, ST_WithBox GGER bbox output, citydb_grid.flight_obstacles Materialized View, GeomGrids Obstacle Index, GGER Codes View, GIN geomgrids Index, PostgREST GGER + Box RPC, ST_FindGridsPath Wrapper View (+14 more)

### Community 10 - "GGER Height Bounds"
Cohesion: 0.23
Nodes (21): GGER Height Layer Stacking, arcSecondFractionsToHeight(), assertFiniteNumber(), assertLatitude(), assertLevel(), assertLongitude(), clamp(), coordinateToIndex() (+13 more)

### Community 11 - "BeiDou Grid Reference"
Cohesion: 0.20
Nodes (19): Beidou Grid Code Algorithm, Beidou Grid Code, BGC 3D Encoding, GeoSOT Grid, GEOVIS iBEST-DB Manual, iBEST-DB GeomGrids, iBEST-DB GridCell, iBEST-DB Grid Path Planning (+11 more)

### Community 12 - "Constraint Editor UI"
Cohesion: 0.12
Nodes (9): drawPointsToMultiPolygon(), geometryToDrawPoints(), parseGeometry(), sameLonLat(), AirspaceConstraintEditor, assert, geometry, points (+1 more)

### Community 13 - "Seed Airspace Zones"
Cohesion: 0.27
Nodes (18): feature_value(), geometry_expression(), insert_no_fly_zone(), insert_temp_control(), load_geojson(), main(), parse_args(), Any (+10 more)

### Community 14 - "BeiDou Bounds Module"
Cohesion: 0.27
Nodes (17): assertFiniteNumber(), assertLevel(), clampIndex(), distanceMeters(), firstLevelBounds(), getCellBounds(), getHeightBounds(), getHeightBoundsByLayer() (+9 more)

### Community 15 - "DEM Tiles Export"
Cohesion: 0.28
Nodes (14): ArgumentParser, ndarray, build_mesh(), build_parser(), enu_axes(), main(), make_tile_transform(), MeshData (+6 more)

### Community 16 - "3D Tiles Export"
Cohesion: 0.35
Nodes (12): 3DCityDB to 3D Tiles Workflow, 3D Tiles Materialized View Contract, citydb-3dtiles-export skill, pg2b3dm Export, create_materialized_view(), log(), resolve_pg2b3dm(), run_advice() (+4 more)

### Community 17 - "Airspace Grid Visualization"
Cohesion: 0.15
Nodes (7): GGER Airspace Visualization, AirspaceGridRenderer, assert, BeidouAirspaceGrid, beidouCells, GGERAirspaceGrid, ggerCells

### Community 18 - "Airspace Watch Worker"
Cohesion: 0.32
Nodes (12): Path, listen_loop(), log(), main(), parse_args(), payload_summary(), Any, Connection (+4 more)

### Community 19 - "Flight Path Camera"
Cohesion: 0.18
Nodes (12): Cesium animation objects, Chase camera, Flight Path Camera Follow Effects Plan, Flight path playback data, FPV camera, Route grid scanning, flight_path.plan_point schema, flight_path.plan_result schema (+4 more)

### Community 20 - "Flight Path Workbench"
Cohesion: 0.17
Nodes (5): assert, cells, FlightPathWorkbench, normalized, workbench

### Community 21 - "Obstacle Domain Concepts"
Cohesion: 0.29
Nodes (7): Flight Obstacles, Terrain Obstacles, Flight Obstacles, Terrain Obstacles, 地形grids只显示fine级别，统一飞行障碍查询接口, Flight Obstacles, Terrain Obstacles

### Community 22 - "Obstacle Situation Layer"
Cohesion: 0.29
Nodes (3): assert, FlightObstacleSituationLayer, layer

### Community 23 - "Grid Refresh Tests"
Cohesion: 0.57
Nodes (3): default_args(), FlightObstacleGridRefreshAdapterTests, sql_text()

### Community 24 - "API Schema RPC"
Cohesion: 0.40
Nodes (5): API Schema RPC, API Schema RPC, API Schema RPC, API Schema RPC, 使用 API schema 管理 RPC

### Community 25 - "Terrain LOD Loading"
Cohesion: 0.40
Nodes (5): BBox and Center-priority Terrain Loading, Implemented Terrain LOD Results, Terrain LOD Levels, list_flight_obstacles_gger_lod RPC, citydb_grid.obstacles_terrain_lod

### Community 26 - "Route Planning Heights"
Cohesion: 0.50
Nodes (4): AGL clearance band, Height datum handling, Obstacle avoidance inputs, ST_FindGridsPath workflow

### Community 27 - "No Fly Zone Table"
Cohesion: 0.67
Nodes (3): airspace.no_fly_zone, airspace.no_fly_zone, airspace.no_fly_zone

### Community 28 - "Temp Control Zone Table"
Cohesion: 0.67
Nodes (3): airspace.temp_control_zone, airspace.temp_control_zone, airspace.temp_control_zone

### Community 29 - "BBox Fallback Mode"
Cohesion: 0.67
Nodes (3): BBox Fallback Mode, BBox Fallback Mode, BBox Fallback Mode

### Community 30 - "Block Prism Mode"
Cohesion: 0.67
Nodes (3): Block Prism Mode, Block Prism Mode, Block Prism Mode

### Community 31 - "Geomgrids"
Cohesion: 0.67
Nodes (3): Geomgrids, Geomgrids, Geomgrids

### Community 32 - "Materialized Views"
Cohesion: 0.67
Nodes (3): Materialized Views, Materialized Views, Materialized Views

### Community 33 - "Polygon Prism Mode"
Cohesion: 0.67
Nodes (3): Polygon Prism Mode, Polygon Prism Mode, Polygon Prism Mode

### Community 34 - "PostgREST CRUD API"
Cohesion: 0.67
Nodes (3): PostgREST CRUD API, PostgREST CRUD API, PostgREST CRUD API

### Community 35 - "Refresh Workflow"
Cohesion: 0.67
Nodes (3): Refresh Workflow, Refresh Workflow, Refresh Workflow

### Community 36 - "Trajectory Reference"
Cohesion: 1.00
Nodes (3): GEOVIS iBEST-DB Trajectory Quick Reference, iBEST-DB Trajectory, Trajectory Spatiotemporal Predicates

## Knowledge Gaps
- **215 isolated node(s):** `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation`, `GeomGrids Obstacle Index`, `GIN geomgrids Index`, `ST_FindGridsPath Wrapper View` (+210 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **14 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `ScriptError` connect `CityDB Obstacle Refresh` to `Python Database Utilities`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **What connects `Read a small clipped DEM through GDAL XYZ output as a row-major 2D array.`, `Extended DMS 32-bit Index`, `iBEST-DB GGER Validation` to the rest of the system?**
  _259 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Python Database Utilities` be split into smaller, more focused modules?**
  _Cohesion score 0.06134731120170841 - nodes in this community are weakly interconnected._
- **Should `MVP Frontend Plan` be split into smaller, more focused modules?**
  _Cohesion score 0.0273972602739726 - nodes in this community are weakly interconnected._
- **Should `Obstacle Grid ADRs` be split into smaller, more focused modules?**
  _Cohesion score 0.0392156862745098 - nodes in this community are weakly interconnected._
- **Should `CityDB Obstacle Refresh` be split into smaller, more focused modules?**
  _Cohesion score 0.11879432624113476 - nodes in this community are weakly interconnected._
- **Should `OSM Building Import` be split into smaller, more focused modules?**
  _Cohesion score 0.1202020202020202 - nodes in this community are weakly interconnected._
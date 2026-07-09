# 前端模块化方案

本文规划 `frontend/` 从当前单页 HTML + 全局脚本形态，演进为可维护、可测试、可逐步迁移的模块化前端。当前核心入口是 `frontend/tianditu-3d.html`，它同时承担页面结构、样式、Cesium 初始化、天地图图层、PostgREST 请求、认证、CityDB 拾取、GGER 空域网格、飞行障碍、航迹工作台等职责。模块化目标不是简单拆文件，而是在稳定的 seam 上形成深模块。

## 目标

- 降低 `tianditu-3d.html` 的职责：最终只保留静态 HTML 容器和脚本入口。
- 把 Cesium/天地图、PostgREST、DOM、业务能力分别放到明确 seam 后面。
- 每个业务能力以 feature module 形式挂载，外部只知道 `mount/destroy` 和少量命令。
- 允许旧 `js/*.js` 通过 adapter 渐进迁移，避免一次性大重写。
- 为后续 TypeScript、单元测试、E2E 测试、构建部署铺路。

## 推荐目录结构

```text
frontend/
  package.json
  index.html
  tianditu-3d.html              # 迁移期保留，最终可退役或跳转到 index.html

  src/
    main.ts

    app/
      createHuaguoshanApp.ts
      app-context.ts
      app-events.ts
      app-state.ts

    config/
      runtime-config.ts

    cesium/
      cesium-globals.ts
      create-viewer.ts
      camera-controller.ts
      layer-controller.ts
      tileset-loader.ts
      feature-picking.ts

    api/
      postgrest-client.ts
      auth-client.ts
      citydb-client.ts
      airspace-client.ts
      flight-obstacle-client.ts

    features/
      hud/
        hud-module.ts
        camera-readout.ts
        auth-panel.ts
        status-log.ts

      citydb-inspector/
        citydb-inspector-module.ts
        feature-panel.ts
        feature-metadata.ts
        grid-highlight.ts

      airspace-grid/
        airspace-grid-module.ts
        gger-domain.ts
        gger-bounds.ts
        gger-renderer.ts

      airspace-constraints/
        airspace-constraint-module.ts
        airspace-constraint-editor-adapter.ts

      flight-obstacles/
        flight-obstacle-module.ts
        flight-obstacle-layer-adapter.ts

      flight-path/
        flight-path-module.ts
        flight-path-workbench-adapter.ts

    ui/
      dom.ts
      buttons.ts
      forms.ts

    styles/
      theme.css
      layout.css
      panels.css
      controls.css
      cesium-overrides.css

    legacy/
      README.md
      # 暂存迁移期 adapter 或尚未 TypeScript 化的代码
```

## 模块 seam

### App seam

App 是唯一装配层，负责创建依赖、挂载模块、注销监听。

```ts
export interface HuaguoshanApp {
  start(): Promise<void>
  destroy(): void
}
```

外部只调用：

```ts
createHuaguoshanApp({
  container: '#cesiumContainer',
  config,
}).start()
```

### Feature module seam

所有业务能力采用统一接口。

```ts
export interface FeatureModule {
  mount(ctx: AppContext): void | Promise<void>
  destroy(): void
}
```

示例模块：

- `HudModule`
- `CityDbInspectorModule`
- `AirspaceGridModule`
- `FlightObstacleModule`
- `FlightPathModule`
- `AirspaceConstraintModule`

调用者不关心模块内部绑定了哪些 DOM 事件、创建了哪些 Cesium primitive、调用了哪些 RPC。

### Cesium seam

Cesium/天地图是强外部依赖，必须包在 adapter 后面。

```ts
export interface MapContext {
  viewer: Cesium.Viewer
  cesium: typeof Cesium
}

export interface CameraController {
  flyToHuaguoshan(): void
  flyToChina(): void
  flyToTileset(): void
  flyToDem(): void
  flyToBounds(bounds: GeoBounds, message?: string): void
}

export interface LayerController {
  setVisible(layer: LayerId, visible: boolean): void
  isVisible(layer: LayerId): boolean
}
```

业务模块可以使用 `CameraController` 和 `LayerController`，不要散落直接操作 `viewer.camera.flyTo`、`tileset.show`、`imageryLayer.show`。

### API seam

PostgREST 和认证请求集中处理。

```ts
export interface PostgrestClient {
  rpc<T>(name: string, payload?: unknown): Promise<T>
  get<T>(path: string, params?: Record<string, string>): Promise<T>
  post<T>(path: string, body?: unknown): Promise<T>
}
```

业务 client 建在 `PostgrestClient` 上：

- `AuthClient`
- `CityDbClient`
- `AirspaceClient`
- `FlightObstacleClient`

这里统一处理：

- JWT header
- PostgREST profile header
- JSON parse
- 错误文本
- 401/403 行为
- RPC 返回值类型

### App events seam

先不用 Redux/Pinia，使用轻量 typed event bus。

```ts
export type AppEvent =
  | { type: 'auth:changed'; user: AuthUser | null }
  | { type: 'layer:visibility-changed'; layer: LayerId; visible: boolean }
  | { type: 'camera:changed'; lon: number; lat: number; alt: number }
  | { type: 'citydb:selected'; feature: CityDbFeature }
  | { type: 'citydb:cleared' }
  | { type: 'airspace:grid-selected'; selection: GgerGridSelection }
  | { type: 'status:log'; message: string }
```

模块之间尽量通过事件通信，避免互相持有具体实现。

## 当前代码迁移映射

| 当前位置 | 目标位置 |
| --- | --- |
| `tianditu-3d.html` 内联 CSS | `src/styles/*.css` |
| `configureScene` | `src/cesium/create-viewer.ts` |
| `addImagery` / `addTerrain` / `addPlaceNames` | `src/cesium/layer-controller.ts` |
| `addLocalTileset` / `addDemTileset` / `addLianyungangDemTileset` | `src/cesium/tileset-loader.ts` |
| `flyToHuaguoshan` / `flyToTileset` / `flyToDem` | `src/cesium/camera-controller.ts` |
| `authenticate` / `logout` / `checkAuthStatus` | `src/api/auth-client.ts` + `features/hud/auth-panel.ts` |
| `postgrestRpc` / `airspaceRequest` | `src/api/postgrest-client.ts` + feature-specific clients |
| CityDB 拾取、属性面板、grid 高亮 | `features/citydb-inspector/` |
| GGER grid 解析、bounds、渲染 | `features/airspace-grid/` |
| `js/GGERGridCode.js` | `features/airspace-grid/gger-domain.ts` |
| `js/GGERGridBounds.js` | `features/airspace-grid/gger-bounds.ts` |
| `js/AirspaceGridRenderer.js` | `features/airspace-grid/gger-renderer.ts` |
| `js/AirspaceConstraintEditor.js` | `features/airspace-constraints/airspace-constraint-editor-adapter.ts` |
| `js/FlightObstacleSituationLayer.js` | `features/flight-obstacles/flight-obstacle-layer-adapter.ts` |
| `js/FlightPathWorkbench.js` | `features/flight-path/flight-path-workbench-adapter.ts` |

## 分阶段迁移计划

### Phase 1：建立 Vite 壳，保持行为不变

目标：引入现代入口，但不重写业务。

任务：

1. 新增 `frontend/package.json`、`frontend/index.html`、`frontend/src/main.ts`。
2. CDN 方式继续加载 Cesium 和天地图插件。
3. 把内联 CSS 抽到 `src/styles/`。
4. 把现有页面主体 HTML 保持一致，先只改变资源组织方式。
5. 确认 `index.html` 与 `tianditu-3d.html` 行为一致。

验收：

- 页面能加载 Cesium。
- 天地图影像、国界、地形、三维地名仍可用。
- 现有按钮和面板行为不回退。

### Phase 2：抽配置和 API

目标：所有 fetch、token、URL、JWT 行为集中。

任务：

1. 建 `runtime-config.ts`，集中：
   - 天地图 token
   - PostgREST base URL
   - tileset URL
   - DEM URL
   - localStorage key
2. 建 `postgrest-client.ts`。
3. 建 `auth-client.ts`。
4. 替换 HTML 脚本中的认证和 RPC fetch。

验收：

- 无散落的 PostgREST `fetch(...)`。
- 登录、登出、token 校验行为不变。
- RPC 错误提示仍包含可读 message。

### Phase 3：抽 Cesium map module

目标：业务不直接负责 viewer 初始化和基础图层管理。

任务：

1. 建 `create-viewer.ts`。
2. 建 `camera-controller.ts`。
3. 建 `layer-controller.ts`。
4. 建 `tileset-loader.ts`。
5. 把 `state.viewer` 的直接读写压缩到 app/cesium 层。

验收：

- `createHuaguoshanApp` 可一键创建 viewer 和基础图层。
- 图层按钮只调用 `LayerController.setVisible(...)`。
- 相机按钮只调用 `CameraController`。

### Phase 4：按 feature 迁移

优先顺序：

1. `hud`：相机读数、状态日志、认证面板。
2. `citydb-inspector`：拾取、属性面板、GGER 包围网格高亮。
3. `airspace-grid`：GGER 地面网格、柱网、切片、标签。
4. `flight-obstacles`：障碍源过滤、LOD 刷新、障碍缩放。
5. `airspace-constraints`：临时管制/禁飞区编辑。
6. `flight-path`：航迹绘制、评估、回放。

每次只迁一个 feature。迁移期允许 adapter 包旧实现，避免一次改动过大。

### Phase 5：TypeScript 化和测试

目标：让核心算法和 seam 可测试。

建议测试：

- Vitest
  - GGER 编码/解析。
  - bbox 解析和 bounds 合并。
  - CityDB metadata 识别。
  - PostgREST 错误处理。
  - Flight path 样本生成。
- Playwright
  - 页面可打开。
  - Cesium 初始化无 fatal error。
  - 图层按钮可切换。
  - 认证失败 UI 正确。
  - CityDB 面板可关闭。

## 迁移约束

- 不要在 feature module 内创建 Cesium viewer。
- 不要在 feature module 内硬编码 PostgREST URL。
- 不要让 UI 控件直接操作其他 feature 的内部对象。
- 不要把所有状态塞进一个巨大 `state` 对象后继续跨模块读写。
- 不要为了“拆文件”制造浅模块；优先形成小 interface、大 implementation 的深模块。

## 建议优先落地的最小 PR

第一个 PR 只做低风险结构化：

1. 新增本文件。
2. 新增 `frontend/src/styles/` 并抽离 CSS。
3. 新增 `frontend/src/config/runtime-config.ts`。
4. 新增 `frontend/src/api/postgrest-client.ts`。
5. 只替换认证和 RPC 请求，不迁移 Cesium 逻辑。

这样能先拿到明确收益：配置集中、请求集中、样式脱离 HTML，同时避免一次碰到全部 Cesium 业务逻辑。

## 已开始落地

- 已将 `frontend/tianditu-3d.html` 的内联样式抽到 `frontend/src/styles/tianditu-3d.css`。
- 已新增 `frontend/src/config/runtime-config.js`，集中管理天地图、tileset、PostgREST、认证和花果山坐标配置。
- 已新增 `frontend/src/api/postgrest-client.js`，集中处理 PostgREST RPC、普通请求、JWT header 与认证登录/校验。
- 已让现有页面通过上述配置/API adapter 调用认证、CityDB RPC、GGER RPC、飞行障碍 RPC 和空域约束请求。
- 已新增 `frontend/src/cesium/tianditu-map.js`，集中封装 viewer 创建、场景配置、天地图影像/地形/地名和花果山 marker。
- 已新增 `frontend/src/cesium/tileset-loader.js`，集中封装 Cesium 3D Tileset 创建、挂载和 readyPromise 处理。
- 已新增 `frontend/src/cesium/camera-controller.js`，集中封装常用相机飞行和 tileset 定位动作。
- 已新增 `frontend/src/features/airspace-grid/grid-geometry.js`，集中封装 GGER bbox 解析、grid cell 提取、bounds 合并、box edge 生成和高亮 primitive 创建。
- 已新增 `frontend/src/features/citydb-inspector/citydb-inspector.js`，集中封装 CityDB 属性面板渲染、3D Tiles metadata 识别、CityDB 要素拾取流程和选中 GGER 网格定位。
- 已新增 `frontend/src/features/hud/hud.js`，集中封装状态日志、相机读数、认证 UI 状态、登录/登出和 token 校验初始化。
- 已新增 `frontend/src/features/airspace-grid/airspace-grid-ui.js`，集中封装 GGER 控件绑定、当前高度读数、网格状态读数和 `GGERAirspaceGrid.create` 初始化。
- 已新增 `frontend/src/features/flight-obstacles/flight-obstacle-module.js`，集中封装飞行障碍图层创建、飞行障碍 RPC 适配和障碍控制项绑定。
- 已新增 `frontend/src/features/airspace-constraints/airspace-constraint-module.js`，集中封装禁限飞区编辑器挂载、地图点选、绘制预览和地形采样 adapter。
- 已新增 `frontend/src/features/flight-path/flight-path-module.js`，集中封装航迹工作台挂载和地图点选 adapter。
- 已新增 `frontend/src/app/layer-actions.js`，集中封装全局按钮分发、图层开关、障碍源开关和 CityDB 面板关闭行为。
- 已新增 `frontend/src/cesium/huaguoshan-tilesets.js`，集中封装花果山 CityDB 3D Tiles、DEM、连云港 DEM 的挂载和定位动作。
- 已新增 `frontend/src/app/create-huaguoshan-app.js`，将页面 bootstrap、状态装配和模块初始化从 HTML 内联脚本移出；`tianditu-3d.html` 现在主要保留静态 DOM、资源引用和最终 app 入口。

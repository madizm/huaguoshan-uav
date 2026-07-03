# 飞行轨迹镜头跟随与动态展示效果实施计划

## 1. 目标

基于当前“飞行路径规划”功能，为已计算出的飞行路径增加动态回放、镜头跟随和三维特效展示能力。

当前可直接复用的数据来源：

```text
flight_path.plan_result
  ├─ route_geojson
  ├─ smooth_route_geojson
  ├─ route_grid_with_box
  ├─ distance_m
  ├─ duration_s
  ├─ grid_cell_count
  └─ traj_point_count
```

第一版优先在前端 `frontend/tianditu-3d.html` 中实现，不强依赖后端新增接口。

---

## 2. 可实现效果清单

## 2.1 无人机跟随视角

第三人称追尾镜头：

```text
相机位于飞行器后上方
镜头始终看向飞行器前进方向
```

展示效果：

- 飞行器沿规划路径移动。
- 镜头平滑跟随。
- 路径线和路径网格从下方穿过。
- 适合常规演示“这条路径怎么飞”。

## 2.2 第一人称 FPV 视角

```text
相机位置 = 当前飞行点
相机方向 = 下一个路径点方向
```

展示效果：

- 低空穿越山谷。
- 沿三维路径网格通道飞行。
- 沉浸感强。

注意：

- 需要做方向平滑，否则转弯处容易晃动。
- 需要保留最小离地 / 离障碍视觉安全距离，避免相机穿模。

## 2.3 电影运镜模式

相机不固定在飞行器上，而是根据飞行阶段切换运镜：

| 阶段 | 运镜 |
|---|---|
| 起飞 | 从俯视拉近到飞行器 |
| 巡航 | 侧后方跟拍 |
| 转弯 | 环绕 / 侧向滑轨 |
| 接近终点 | 拉远俯视整条路径 |
| 完成 | 定格展示路径、网格和障碍 |

这是最适合汇报演示的“炫酷模式”。

## 2.4 路径网格扫描效果

结合 `route_grid_with_box`：

- 当前飞行器所在 gridcell 高亮。
- 已飞过的 gridcell 变暗或变成青色残影。
- 未飞过的 gridcell 保持半透明。
- 当前 gridcell 做发光 / 脉冲效果。

视觉效果：

```text
飞行器沿三维 GGER 网格通道前进，网格逐格点亮。
```

## 2.5 地形净空带

结合 AGL 规划语义：

```text
飞行高度 AMSL - 地形高度 AMSL = 净空高度 AGL
```

展示方式：

- 路径下方拉出半透明“安全高度帘”。
- 净空充足：青色。
- 净空临界：黄色。
- 净空不足：红色。

用途：

- 解释路径为什么需要抬升。
- 展示 AGL 规划的安全性。

## 2.6 风险热力路径

结合飞行障碍：

- 靠近建筑 / 地形障碍：路径变黄。
- 靠近禁飞区 / 临时管制区：路径变红。
- 安全段：路径为青色。

后续可基于距离阈值或网格邻接关系生成风险分段。

## 2.7 航迹尾迹 / 粒子拖尾

飞行器后方保留渐隐轨迹：

- 青色发光尾迹。
- 网格状残影。
- 已飞过路径逐渐点亮。
- 类似雷达航迹回放。

## 2.8 时间轴播放

基础控制：

- 播放
- 暂停
- 停止
- 倍速
- 进度条拖动

实时信息：

- 当前进度百分比
- 当前高度
- 当前速度
- 已飞距离
- 剩余距离
- 当前段编号
- 当前 gridcell 编码

---

## 3. 技术方案

## 3.1 前端路径回放数据

第一版直接使用：

```json
route_geojson.coordinates
```

示例：

```json
[
  [119.2218, 34.6475, 123.38],
  [119.2294, 34.6472, 183.93],
  [119.2438, 34.6605, 183.93]
]
```

基于 `duration_s` 为每个路径点生成时间戳：

```text
start_time + duration_s * distance_ratio
```

距离比例建议按累计三维/二维距离计算，而不是按点序号平均分配。

## 3.2 Cesium 动画对象

使用：

```js
Cesium.SampledPositionProperty
Cesium.VelocityOrientationProperty
viewer.clock
viewer.trackedEntity
```

核心实体：

```text
flightPathPlayback.entity
  ├─ position: SampledPositionProperty
  ├─ orientation: VelocityOrientationProperty
  ├─ model / billboard / point
  └─ path: Cesium.PathGraphics
```

## 3.3 镜头跟随模式

### 简单跟随

```js
viewer.trackedEntity = droneEntity;
```

优点：实现快。

缺点：镜头风格普通，可控性弱。

### 自定义跟随

在 `scene.preRender` 中计算：

```text
current = 当前飞行器位置
next = 前方若干秒位置
direction = normalize(next - current)
camera_position = current - direction * followDistance + up * followHeight
camera.lookAt(current, offset)
```

优点：可做电影运镜、侧后方跟拍、FPV。

缺点：需要处理方向平滑和边界情况。

## 3.4 路径网格扫描

当前后端已返回：

```text
route_grid_with_box.cells[].bbox
```

第一版策略：

1. 回放开始时绘制全部路径网格。
2. 每一帧根据当前飞行进度计算当前路径点索引。
3. 高亮当前附近 gridcell。
4. 已飞过 gridcell 降低透明度或切换颜色。

后续优化：

- 后端返回 `grid_path` 顺序化 bbox，而不是 `ST_AsGrids(grid_path)` 聚合后的无序 cells。
- 前端即可按真实路径顺序逐格点亮。

---

## 4. 第一版实施范围

建议第一版实现以下能力：

1. 新增播放控制按钮：
   - 播放航迹
   - 暂停
   - 停止
   - 跟随镜头
2. 使用 `route_geojson` 驱动无人机实体沿路径移动。
3. 默认第三人称追尾镜头。
4. 显示已规划路径线。
5. 显示路径网格。
6. 当前飞行位置附近添加发光 marker。
7. HUD 显示：
   - 进度
   - 高度
   - 已飞 / 总距离
   - 当前速度

暂不做：

- 完整 FPV 模式。
- 复杂电影分镜。
- 风险热力路径。
- 真实飞控姿态模拟。

---

## 5. 前端状态设计

在 `state.flightPath` 下新增：

```js
playback: {
  entity: null,
  clockStart: null,
  clockStop: null,
  sampledPosition: null,
  playing: false,
  followEnabled: false,
  mode: 'chase', // chase / fpv / cinematic
  speedMultiplier: 1,
  progress: 0,
  currentIndex: 0,
  trailEntity: null,
  currentGridPrimitive: null
}
```

---

## 6. UI 设计

在 `Flight Path Planner` 面板中增加：

```text
[播放航迹] [暂停] [停止] [跟随镜头]
[1x / 2x / 4x]
进度条 0% ━━━━━━━━━ 100%
```

HUD 可显示在右下角 readout 或路径面板内：

```text
Flight Replay
Progress: 42%
Altitude: 368m AMSL
Speed: 10m/s
Distance: 3.4 / 8.5km
Mode: Chase Camera
```

---

## 7. 后端扩展建议

第一版不需要新增后端接口。

后续可增加：

## 7.1 顺序化路径网格接口

当前：

```sql
ST_WithBox(ST_AsGrids(grid_path), 'GGER')
```

可能丢失 `grid_path` 原始顺序。

建议新增：

```sql
flight_path.get_latest_result(...)
```

返回：

```json
"route_grid_path": [
  {"seq": 0, "code": "GZ...", "bbox": "(...)"},
  {"seq": 1, "code": "GZ...", "bbox": "(...)"}
]
```

可用：

```sql
unnest(grid_path) with ordinality
ST_AsText(cell, 'GGER')
ST_AsBox3D(cell)
```

## 7.2 CZML 导出

新增：

```sql
flight_path.export_result_czml(p_result_id bigint)
```

直接返回 Cesium 可播放的 CZML。

## 7.3 轨迹采样接口

基于 `route_traj trajectory`：

```sql
GT_pointAtTime(route_traj, t)
GT_velocityAtTime(route_traj, t)
GT_accelerationAtTime(route_traj, t)
```

用于更精确的时间驱动回放。

---

## 8. 验收标准

| 编号 | 验收项 | 预期 |
|---|---|---|
| C1 | 播放航迹 | 飞行器沿 `route_geojson` 平滑移动 |
| C2 | 暂停 / 停止 | 可暂停和重置回放 |
| C3 | 镜头跟随 | 开启后镜头自动跟随飞行器 |
| C4 | 路径网格 | 回放时仍可显示三维路径 gridcell |
| C5 | AGL 路径 | AGL 路径按实际 AMSL 高度播放，不贴地或穿山 |
| C6 | HUD | 显示进度、高度、速度、距离 |
| C7 | 稳定性 | 多次加载不同方案不会残留旧 entity / primitive |

---

## 9. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| 路径点太少 | 动画不平滑 | 前端插值 densify 或后端输出更多采样点 |
| 镜头方向突变 | 画面晃动 | 对 heading / pitch 做缓动 |
| grid_path 聚合后无序 | 网格扫描顺序不准确 | 后端增加 `route_grid_path` 顺序化输出 |
| 路径高度跨层跳跃 | 飞行器突然升降 | 对高度做插值平滑或用 smooth route |
| Cesium trackedEntity 风格普通 | 演示效果一般 | 使用自定义 preRender chase camera |
| 网格太多 | 前端卡顿 | 限制显示数量、按当前进度局部显示、合并边线 |

---

## 10. 推荐路线

1. **P0：播放航迹 + 简单 trackedEntity 跟随**。
2. **P1：自定义 chase camera + HUD + 倍速控制**。
3. **P2：路径网格逐格扫描 + 航迹尾迹**。
4. **P3：FPV / cinematic 模式 + 风险热力路径**。

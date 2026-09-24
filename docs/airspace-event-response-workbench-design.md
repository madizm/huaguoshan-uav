# 空域事件处置工作台设计

> 状态：提案  
> 设计范围：预警处置前端、事件领域模型、PostgREST 接口与 MVP 验收  
> 依据：`CONTEXT.md`、`docs/mvp-airspace-event-loop-design.md`、ADR 0002/0003/0004

> 当前阶段只验证概念模型和业务闭环。本文中的前端交互、前端模块和刷新方案暂缓，不作为当前实施范围；业务流程以 `docs/airspace-event-response-business-flow.md` 为准。

> 防御圈场景的数据结构与默认规则以 [`defense-ring-risk-model-v1.md`](./defense-ring-risk-model-v1.md) 为准；先完成配置设计，再实现事件自动形成。既有禁飞/临时管控区表不作为该场景输入。

## 1. 命名与定位

用户所说的“预警处置模块”，在本项目统一命名为 **空域事件处置工作台（Airspace Event Workbench）**。

原因：

- **预警（Warning）** 是空域事件经过研判后形成的风险状态，不是独立事件，也不是空域目标的固有属性。
- 防御圈进入风险和林火疑似预警必须进入同一个 **MVP 事件队列**，不能形成两套列表、生命周期和处置流程。
- 平台定位是大屏展示与辅助决策，不是完整指挥系统或设备直控平台。

工作台负责：

1. 汇总并排序当前空域事件。
2. 展示风险、证据、影响范围与处置能力。
3. 支持事件认领、研判、选择处置方案、记录执行结果。
4. 支持基于关闭依据关闭事件并进行复盘。
5. 保留完整事件历史和决策证据链。

工作台不负责：

- 自动确认火灾。
- 自动实控反无设备。
- 自动派遣消防力量。
- 建设通用审批流、规则引擎或跨部门指挥系统。

## 2. MVP 场景

首版共用一个事件底座，支持两类事件：

| 事件类型 | 触发来源 | 主要证据 | 允许的处置方向 |
| --- | --- | --- | --- |
| `defense_ring_entry` | 目标航迹按中心与半径命中防御圈并满足确认窗口 | 目标、航迹、选中防御圈的中心/半径及配置版本、规则版本、命中网格、评分因子 | 持续跟踪、人工核查、通知责任单位、模拟联动 |
| `forest_fire_suspected` | 火点线索满足火点确认窗口 | 热点、烟点、人工标注、巡查任务、环境因子 | 二次复核、通知护林员、调整巡查、升级人工应急处置 |

场景差异只存在于证据结构、确认窗口、风险规则和方案模板中；生命周期、认领、责任主体、关闭和复盘保持统一。

## 3. 用户与权限

沿用现有两类业务角色，并映射到现有 PostgREST 角色体系：

### 3.1 系统使用人员

- 查看事件队列与详情。
- 查看风险解释、证据和推荐方案。
- 认领事件。
- 提交研判、选择处置方案、记录执行结果。
- 关闭和复盘事件。

当前阶段由已认证 `admin` JWT 承载以上能力。

### 3.2 系统运维人员

- 维护模拟数据、规则模板和来源映射。
- 排查数据质量与接口问题。
- 不通过工作台修改已经生成的历史证据。

未认证 `anonymous` 不拥有事件业务数据访问权限。

## 4. 核心业务流程

### 4.1 统一生命周期

```text
发现 discovered
  → 待研判 pending_assessment
  → 已预警 warned
  → 处置编排中 orchestrating
  → 处置执行中 executing
  → 已控制 controlled
  → 已关闭 closed
  → 已复盘 reviewed
```

允许的 MVP 分支：

- `pending_assessment → closed`：人工排除、重复事件或误报，但必须填写关闭依据。
- `warned → closed`：研判后确认无需继续处置，但必须填写关闭依据。
- `warned → warned`：记录“持续观察”，不改变生命周期。
- `orchestrating → warned`：候选方案均不可行，退回持续研判，并记录原因。
- `executing → warned`：动作失败或风险重新出现，回到预警状态。

约束：

- 候选事件记录不进入正式生命周期。
- 已关闭事件不可再认领、改风险或追加处置动作，只能进入复盘。
- 生命周期状态与“误报、已排除、目标离开、处置成功”等业务结果分开存储。
- 关闭不能仅以“目标消失”为依据；必须提交可解释证据和原因。

### 4.2 认领与并发

- 一个事件同一时刻只有一个主责任主体。
- 协同单位不获得主责任。
- 认领、转交、释放都写入事件历史。
- 所有命令携带 `expected_version`，数据库使用乐观并发控制。
- 版本冲突返回 `409` 语义错误，前端刷新事件后提示用户重新操作，禁止静默覆盖。

### 4.3 风险与优先级

二者独立：

- 风险等级 `low | medium | high | critical`：表达事件威胁程度。
- 处置优先级 `P1 | P2 | P3 | P4`：表达工作台处理顺序，`P1` 最高。

排序建议：

```text
priority asc
→ 未认领优先
→ critical/high 风险优先
→ 最近升级时间 desc
→ discovered_at asc
```

每次风险计算保存规则版本、因子快照、结论和解释，不只保存颜色或最终等级。无可用处置能力通常提高处置优先级，而不直接提高风险等级。

## 5. 前端交互设计

### 5.1 页面布局

工作台作为现有 Cesium 页面的一种业务模式，而不是继续向当前 HUD 堆叠表单。

```text
┌──────────────────────────────────────────────────────────────────┐
│ 顶栏：工作台标题｜事件统计｜数据刷新时间｜工作台/配置模式｜用户 │
├──────────────┬───────────────────────────────┬───────────────────┤
│ 事件队列     │ Cesium 事件态势地图            │ 事件详情          │
│ 320–360 px   │ 目标/防御圈/证据/影响区/能力覆盖 │ 400–460 px        │
│              │                               │ 概览/证据/方案/历史│
├──────────────┴───────────────────────────────┴───────────────────┤
│ 选中事件操作栏：认领｜研判｜选择方案｜记录结果｜关闭｜复盘      │
└──────────────────────────────────────────────────────────────────┘
```

宽度不足时，详情区变为右侧抽屉；事件队列保持可访问，不把核心处置能力藏到地图拾取操作之后。

### 5.2 顶栏统计

只展示可行动指标：

- 待处置事件数。
- P1/P2 事件数。
- 未认领事件数。
- 处置执行中事件数。
- 最近一次成功刷新时间与数据异常状态。

不使用与处置无关的装饰性大屏指标。

### 5.3 事件队列

每张事件卡片展示：

- 事件类型和短标题。
- 风险等级、处置优先级。
- 当前生命周期状态。
- 发生位置或责任区。
- 首次发现时间、持续时长。
- 责任主体；未认领时明确标红。
- 一行排序原因，例如“P1 · 未认领 · 核心圈进入 · 身份未核实”。

过滤条件：

- 当前待办 / 全部 / 已关闭。
- 事件类型。
- 生命周期。
- 风险等级与优先级。
- 是否已认领。
- 时间范围。

默认只显示未关闭事件，不允许默认过滤条件隐藏 P1 事件。

### 5.4 地图表达

选中事件时，地图一次性完成：

1. 飞至事件影响范围。
2. 高亮相关目标或火点线索。
3. 展示目标航迹或巡查航迹。
4. 展示相关防御圈或巡查责任区。
5. 展示命中 GGER 网格。
6. 展示处置能力覆盖和附近应急能力。

地图图形语义：

- 风险颜色只用于事件和影响范围，不污染资产、目标和防御圈自身颜色。
- 候选事件使用虚线/低透明度；正式事件使用实线。
- 观测或其他业务数据如有高度值，同时显示数值、单位和 Height Datum；防御圈不显示高度上下限。
- 证据冲突用独立标记表达，不能用“降低透明度”代替说明。

### 5.5 详情面板

#### 概览

- 事件编号、类型、状态和持续时间。
- 风险等级、处置优先级及排序原因。
- 当前责任主体与协同单位。
- 影响对象、影响范围；若有高度观测则显示高度语义，防御圈范围只用中心与半径表达。
- 当前建议动作摘要。

#### 证据

按时间排序展示：

- 原始观测来源与时间。
- 融合判断及置信度。
- 目标/航迹/防御圈或火点线索。
- 环境研判因子。
- 冲突证据和数据缺失。
- 风险分级解释。

证据项可定位到地图；原始载荷默认折叠，避免 JSON 淹没业务信息。

#### 处置方案

候选方案按推荐顺序展示：

- 推荐动作。
- 排序原因与适用条件。
- 所需处置能力或应急能力。
- 预计效果、风险和副作用。
- 设备接入级别。
- 是否仅为模拟联动。

用户必须主动选择方案；系统不得自动把第一名当作已执行命令。

#### 事件历史

统一时间线展示：

- 状态变化。
- 风险和优先级变化。
- 认领、转交和协同单位变化。
- 人工研判与方案选择。
- 动作状态和结果。
- 关闭依据与复盘结论。

历史记录必须展示操作者、时间、原因和关联证据。

### 5.6 操作保护

- 未认领事件只能查看；“认领并处理”可合并为一步操作。
- 选择方案前展示前置条件和副作用。
- 模拟联动按钮必须显示“模拟”，且与真实设备控制使用不同视觉和文案。
- 关闭操作使用结构化表单：结果类型、原因、证据、备注。
- P1/critical 事件关闭需要二次确认，但 MVP 不增加审批流。
- 提交期间禁用重复操作；失败后保留用户输入。

## 6. 数据模型

新增内部 schema：`event_response`。继续只通过 `api` schema 对 PostgREST 暴露读模型和命令 RPC。

### 6.1 正式事件 `event_response.airspace_event`

核心字段：

| 字段 | 说明 |
| --- | --- |
| `id uuid` | 事件稳定标识 |
| `event_code text unique` | 人可读事件编号 |
| `event_type text` | `defense_ring_entry` / `forest_fire_suspected` |
| `lifecycle_status text` | 统一生命周期 |
| `risk_level text` | 当前风险等级 |
| `response_priority text` | 当前处置优先级 |
| `title text` | 事件摘要，不承载证据 |
| `impact_geom geometry(Geometry,4326)` | 当前影响范围 |
| `min_height_m/max_height_m numeric` | 其他场景可空的垂直范围；防御圈进入事件不填 |
| `height_datum text` | 其他场景有高度范围时必填；防御圈进入事件不填 |
| `responsible_party_id bigint null` | 当前主责任主体 |
| `discovered_at/warned_at/closed_at` | 关键业务时间 |
| `version bigint` | 乐观并发版本 |
| `created_at/updated_at` | 持久化时间 |

约束：

- 正式事件不可物理删除。
- `impact_geom` 建 GiST 索引。
- 活跃队列建 `(lifecycle_status, response_priority, updated_at)` 索引。
- 高度字段和 `height_datum` 使用成组约束，禁止只存“米”。

### 6.2 场景扩展

避免把所有场景字段塞入一个巨大 JSON：

- `event_response.defense_ring_event_detail`
  - `event_id`
  - `target_id`
  - `target_track_id`
  - `defense_ring_id`、`defense_ring_code`、`defense_ring_version`、`center_geom` 与 `radius_m` 快照
  - `entry_started_at`
  - `confirmation_rule_version`
- `event_response.forest_fire_event_detail`
  - `event_id`
  - `inspection_task_id`
  - `fire_point_lead_id`
  - `confirmation_rule_version`

每个正式事件必须且只能拥有与 `event_type` 相符的场景扩展记录。

### 6.3 候选事件 `event_response.candidate_event`

保存尚未满足确认窗口的轻量记录：

- 类型、来源标识、首次/最近命中时间。
- 连续观测数、当前置信度。
- 候选空间范围；防御圈候选保存中心和半径快照，不设置高度范围。
- `pending | promoted | dismissed | expired` 状态。
- 升级后的正式 `event_id`。
- 规则版本与判定摘要。

候选记录可按保留策略归档，但不能伪装成正式事件进入工作台主队列。

### 6.4 风险研判 `event_response.risk_assessment`

采用追加式版本记录：

- `event_id`、`sequence_no`。
- 风险等级、处置优先级；防御圈场景另存 0–100 评分。
- 规则编码与版本、防御圈 ID/编码/版本（若适用）。
- 因子快照 `factors jsonb`。
- 可读解释 `explanation jsonb`。
- 研判来源 `system | human`。
- 研判人和时间。

事件表仅保存当前结果，用于快速排序；完整解释以研判记录为准。

### 6.5 证据 `event_response.event_evidence`

采用追加式证据快照：

- `event_id`、`evidence_type`、`observed_at`。
- 来源资源类型、来源记录标识。
- 证据摘要和不可变快照 `snapshot jsonb`。
- 空间位置、置信度、是否存在冲突。
- `is_decision_basis` 标识是否进入决策证据链。

来源标识用于追溯，快照用于保证来源记录后续变化时仍能解释历史决策。禁止更新或删除已引用证据。

### 6.6 GGER 网格 `event_response.event_grid`

- `event_id`。
- `grid_code`。
- `relation_type`：`impact | evidence | defense_ring | capability`。
- 网格层级、垂直层及 Height Datum。

网格用于检索与展示，不替代精确空间判定。

### 6.7 责任与协同

- `event_response.responsible_party`：人员、队伍、组织或外部协调单位。
- `event_response.event_assignment`：追加式认领、转交、释放记录。
- `event_response.event_collaborator`：当前协同单位及参与说明。

事件表上的 `responsible_party_id` 是当前快照，assignment 是审计历史。

### 6.8 处置方案与动作

`event_response.response_plan_candidate`：

- 方案排序、模板编码与版本。
- 推荐动作、所需能力、预计效果。
- 风险、副作用、前置条件、置信度和排序原因。
- `selected_at/selected_by`，同一轮候选集最多选择一个。

`event_response.response_action`：

- 选中方案下的动作。
- `recommended | authorized | executing | succeeded | failed | cancelled`。
- 设备接入级别。
- `is_simulated`。
- 授权来源、执行结果和失败原因。

当前范围禁止生成真实反无设备控制命令；反无设备只能作为可观测、可建议能力参与方案匹配。

### 6.9 关闭与历史

`event_response.closure_basis`：

- 关闭结果：`controlled | excluded | false_positive | duplicate | handed_off | other`。
- 结构化原因、说明、关联证据。
- 提交人和时间。

`event_response.event_history`：

- 追加式业务时间线。
- `event_created | state_changed | risk_assessed | claimed | transferred | plan_selected | action_recorded | closed | reviewed` 等类型。
- 变更前后摘要、原因、操作者和证据引用。

事件状态改变、认领、方案选择和关闭必须在同一数据库事务内写业务记录与事件历史。

## 7. PostgREST 接口

### 7.1 查询接口

只暴露面向界面的读模型，避免前端拼接十余张业务表：

- `api.airspace_event_queue`：活跃/历史事件列表视图。
- `api.list_airspace_events(...)`：带过滤、排序和游标分页的 RPC。
- `api.get_airspace_event_detail(p_event_id)`：返回完整详情 JSON。
- `api.get_airspace_event_map_context(p_event_id)`：返回地图所需 GeoJSON/网格/高度信息。

`get_airspace_event_detail` 返回结构：

```json
{
  "event": {},
  "scenario": {},
  "current_assessment": {},
  "evidence": [],
  "assignments": [],
  "collaborators": [],
  "plan_candidates": [],
  "actions": [],
  "closure_basis": null,
  "history": []
}
```

所有 RPC 必须按仓库规范添加中文注释，并明确注释返回值格式。

### 7.2 命令接口

业务写入只通过命令 RPC，不开放核心表通用 CRUD：

- `api.claim_airspace_event(p_event_id, p_party_id, p_expected_version)`。
- `api.transfer_airspace_event(...)`。
- `api.assess_airspace_event(...)`。
- `api.select_response_plan(...)`。
- `api.record_response_action(...)`。
- `api.transition_airspace_event(...)`。
- `api.close_airspace_event(...)`。
- `api.review_airspace_event(...)`。

每个命令负责：

1. 校验 JWT 数据库角色。
2. 锁定事件并校验 `expected_version`。
3. 校验生命周期和责任主体。
4. 执行业务变更。
5. 同事务追加事件历史与证据引用。
6. 返回更新后的事件摘要与新版本号。

不设计一组让前端任意更新 `status/risk/owner` 字段的浅 CRUD 接口。

### 7.3 错误契约

统一业务错误编码：

- `EVENT_NOT_FOUND`
- `EVENT_VERSION_CONFLICT`
- `INVALID_LIFECYCLE_TRANSITION`
- `EVENT_ALREADY_CLAIMED`
- `EVENT_NOT_CLAIMED_BY_CALLER`
- `CLOSURE_BASIS_REQUIRED`
- `EVIDENCE_REQUIRED`
- `REAL_DEVICE_CONTROL_FORBIDDEN`

前端按错误编码处理，错误文本用于展示和诊断，不依赖解析数据库异常字符串。

## 8. 前端模块 seam

新增深模块：

```text
frontend/src/features/event-workbench/
  event-workbench-module.js       # mount/destroy，唯一外部 interface
  event-workbench-client.js       # 查询与命令 adapter
  event-queue.js                  # 队列交互
  event-detail.js                 # 详情、证据、方案、历史
  event-map-layer.js              # Cesium 事件上下文渲染
  event-actions.js                # 认领、研判、执行、关闭表单
  event-workbench-state.js        # 选中事件、过滤和刷新状态
```

外部 interface：

```js
var workbench = HuaguoshanEventWorkbench.mount({
  container: '#eventWorkbench',
  getViewer: function () { return state.viewer; },
  client: eventWorkbenchClient,
  log: log
});

workbench.open();
workbench.selectEvent(eventId);
workbench.refresh();
workbench.destroy();
```

模块内部隐藏：

- 队列分页与过滤参数。
- 并发版本处理。
- 详情数据拼装。
- Cesium entity/primitive 生命周期。
- 表单校验与命令提交。
- 自动刷新和选中事件合并策略。

与现有模块通过 app 装配层协作，不让事件工作台直接读取 `state.flightObstacleLayer`、`state.airspaceConstraintEditor` 等内部实现。

## 9. 刷新与实时性

MVP 延续“态势快照 + 事件历史”，不引入 WebSocket/流平台：

- 活跃队列前台可见时每 10 秒轮询。
- 页面隐藏时暂停轮询，恢复时立即刷新。
- 命令成功后立即刷新当前事件和队列摘要。
- 详情刷新时保留当前 tab 和滚动位置。
- 新 P1 事件出现时给出明显提示，但不强制抢走用户当前选中的事件。
- 轮询失败使用退避策略，并显示“数据可能已过期”。

后续若增加 SSE/WebSocket，只替换刷新 adapter，不改变工作台 interface。

## 10. 与现有能力的复用关系

- 防御圈场景新建 `airspace.protected_object`、`airspace.defense_ring` 及版本化评分配置；既有 `airspace.no_fly_zone`、`airspace.temp_control_zone` 不参与新研判，其他使用方需先迁移再停用旧接口。
- 地图复用当前 Cesium/Tianditu、GGER 网格和飞行障碍渲染能力。
- 处置能力匹配复用 `equipment.capability_coverage` 及设备当前状态读模型。
- 应急能力推荐复用 `emergency_resource` 数据，但需要在事件详情读模型中完成统一投影。
- 认证与 PostgREST 请求复用 `postgrest-client.js` 和现有 JWT。
- 防御圈编辑、航线规划仍属于配置/规划模式，不放进事件处置操作流。

## 11. 实施顺序

### Phase 1：防御圈与评分配置设计、事件底座与演示闭环

1. 先确定防御圈、保护对象、评分因子和参数的表结构与默认试运行值（见 `docs/defense-ring-risk-model-v1.md`）。
2. 新建 `event_response` schema、事件/历史/证据/责任/方案/关闭表。
3. 实现列表、详情、认领、状态迁移、选择方案、记录结果和关闭 RPC。
4. 提供两类正式事件的可重复执行演示种子数据。
5. 实现事件队列、详情、地图定位和事件历史。
6. 先支持人工驱动完整闭环，验证领域模型和交互。

### Phase 2：防御圈进入自动形成事件

1. 接入目标航迹与候选事件记录。
2. 实现网格粗筛、PostGIS 精确判定、重叠单圈选择和确认窗口。
3. 实现版本化评分、风险分级和处置能力覆盖匹配。
4. 自动生成可解释处置方案候选集。

### Phase 3：林火疑似预警

1. 接入巡查任务、火点线索和融合判断。
2. 实现火点确认窗口和林火风险规则。
3. 接入附近应急能力。
4. 复用同一队列、详情和处置命令。

### Phase 4：复盘与质量提升

1. 完善复盘界面和指标。
2. 增加误报、响应时长、未认领时长分析。
3. 补充归档策略、性能索引和数据质量告警。

## 12. 测试与验收

### 12.1 数据库测试

- 非法生命周期迁移被拒绝。
- 没有关闭依据不能关闭。
- 已关闭事件不能认领或追加动作。
- 并发版本冲突不会覆盖他人变更。
- 认领/迁移/关闭与历史记录保持事务一致。
- 原始证据和事件历史不可更新、不可删除。
- 场景扩展与事件类型一致。
- 其他场景的高度范围存在时 Height Datum 必填；防御圈无高度字段，缺目标高度仍能判圈。
- 真实反无设备控制动作被拒绝。
- `anonymous` 无业务访问，`admin` 只能通过授权接口写入。

### 12.2 前端模块测试

- 队列按优先级、认领和风险稳定排序。
- 过滤不会默认隐藏 P1 活跃事件。
- 选择事件后地图图层正确替换且无 primitive 泄漏。
- 版本冲突会刷新并保留用户未提交内容。
- 关闭表单强制要求结果、原因和证据。
- 模拟联动有明确标识。
- 销毁模块后轮询、DOM 监听和 Cesium 对象全部释放。

### 12.3 E2E 验收路径

#### 防御圈进入事件

1. 模拟航迹进入防御圈并形成候选记录。
2. 满足确认窗口后进入统一事件队列。
3. 查看选中防御圈中心/半径、航迹、命中网格及评分版本；有目标高度时显示其基准。
4. 查看风险解释和能力覆盖。
5. 认领事件并选择模拟处置方案。
6. 记录执行结果，关闭并查看完整历史。

#### 林火疑似预警

1. 巡查任务产生热点与烟点证据。
2. 满足确认窗口后进入同一事件队列。
3. 查看融合判断、环境因子和附近应急能力。
4. 认领后选择二次复核或通知核查。
5. 人工排除或升级，填写关闭依据并复盘。

## 13. 完成定义

首版只有在以下条件全部满足时才算完成：

- 两类事件使用同一队列、生命周期和详情界面。
- 风险等级与处置优先级在模型、接口和 UI 上明确分离。
- 任一关键状态变化都能追溯操作者、原因和证据。
- 事件可以完成认领、研判、方案选择、结果记录、关闭和历史查看。
- 地图能展示事件影响范围、证据和相关业务对象。
- 不存在真实第三方反制设备直控路径。
- 数据库、前端模块和两条 E2E 路径测试通过。

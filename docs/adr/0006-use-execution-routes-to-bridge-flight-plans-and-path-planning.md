# Use execution routes to bridge flight plans and path planning

飞行计划是业务执行计划，`flight_path.plan` 是底层路径规划方案/工作区，二者不直接绑定；业务闭环通过独立的 `flight_operation.execution_route` 连接飞行计划与具体航线依据。一个飞行计划固定对应一个飞行架次，可保留多条执行用航线记录但同时只能有一条 active route；若来源是平台规划，执行用航线只引用具体的 `flight_path.plan_result`，不引用 `flight_path.plan`，若来源是第三方或人工航线，则保存外部/人工几何与来源追溯，不写入 `flight_path.plan_result`，也不表示平台已复核可飞。

## Consequences

- `flight_path.plan` 对外统一称为“路径规划方案”或“路径规划工作区”，不是“飞行计划”；`flight_path.plan_result` 称为“路径规划结果”。短期不物理重命名现有表，但 SQL 注释、API 文档和前端文案必须去歧义。
- `flight_operation.flight_plan` 与 `flight_operation.flight_sortie` 改为一对一：飞行计划表达计划侧事实，飞行架次表达唯一对应的执行事实；`planned_sortie_count` 废弃，计划架次统计改为 `count(flight_plan)`。
- `flight_operation.execution_route.route_grid_codes` 是对外展示、审计和交换的主表达，固定为 GGER 网格码并在执行用航线创建/切换时持久化；几何仅用于地图预览或转换输入。
- 第三方导入航线可直接作为执行用航线展示和执行追溯，但平台不承担避障、合规或可飞复核责任；将外部几何转换为 GGER 网格码只是空间表达归一化。
- 飞行计划进入执行中或已完成状态前必须有 active execution route，且该 route 必须有固化的 GGER 网格码。
- 被 `execution_route` 引用的 `flight_path.plan_result` 不得物理删除或被级联删除；其所属 `flight_path.plan` 可以归档但必须保留审计链。

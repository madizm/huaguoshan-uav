# 防御圈配置后台接口

迁移：`backend/create_defense_ring_admin.sql`；开发环境可在验证数据库连接后执行 `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f backend/create_defense_ring_admin.sql`，随后 `NOTIFY pgrst, 'reload schema'`。迁移幂等，不自动创建虚构保护对象。默认评分规则 `defense-risk` v1 会初始化。测试：`psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/defense_ring_admin_integration.sql`（事务回滚，不留测试数据）。

部署顺序：先运行通用 PostgREST 角色迁移，再运行本迁移。本项目的通用角色脚本会给 `airspace` 表授予管理员直接 DML；本迁移专门撤销防御圈表上的该授权，确保发布版本只能经 RPC 变更。通用角色脚本也已加入存在性检查和末尾撤权，重复运行后仍应复验 `has_table_privilege('admin','airspace.defense_ring','insert') = false`。

后台页面：独立 Vue 管理应用 `frontend/admin` 的 `/defense-rings` 路由。页面提供保护对象选择、地图选取 WGS84 圆心、五层半径与优先级预览、启停配置及评分版本发布；不再挂载到 `frontend/tianditu-3d.html` 态势工作台。通过同源 `/postgrest/rpc/*` 使用管理应用现有管理员 JWT；底层 `airspace`、`event_response` 表不授予直接写权限，也不新增独立身份服务。

## 读取

`POST /postgrest/rpc/get_defense_ring_config`，请求体 `{}`。返回格式：

```json
{
  "objects": [{
    "id": 1, "name": "保护对象", "longitude": 119.2, "latitude": 34.6,
    "enabled": true, "version": 2,
    "rings": [{"id": 1, "code": "core", "name": "核心圈", "ring_level": 5,
      "radius_m": 1000, "priority": 500, "version": 2,
      "center": {"type": "Point", "coordinates": [119.2, 34.6]}}]
  }],
  "rules": {"version": 1,
    "factors": {"zone_core": {"score": 85, "condition_code": "ring_level", "threshold_value": 5,
      "unit": "level", "exclusive_group": null, "enabled": true}},
    "parameters": {"confirm_observations": {"value": 2, "unit": "point"}}
  }
}
```

只返回每个保护对象的当前发布圈组和当前评分规则。新安装时 `objects` 为空，但 `rules` 有默认规则。

## 发布五层防御圈

`POST /postgrest/rpc/save_defense_ring_config`：

```json
{
  "p_config": {
    "id": null, "expected_version": 0, "name": "保护对象",
    "longitude": 119.2, "latitude": 34.6, "enabled": true,
    "radii_m": [5000, 4000, 3000, 2000, 1000],
    "priorities": [100, 200, 300, 400, 500]
  }
}
```

返回 `{ "id": 1, "version": 1 }`。更新时传已存在的 `id` 和读取时拿到的 `expected_version`；版本冲突返回错误，应刷新再编辑，不自动覆盖他人改动。五层由外到内固定为 `sensing` 感知圈、`tracking` 跟踪圈、`countermeasure` 反制圈、`hard_strike` 硬打击圈、`core` 核心圈。半径单位米且严格递减；优先级严格递增。编辑名称、经纬度、启停、半径或优先级都会**追加五条新圈版本**，不改写旧圈。保护对象禁用后仍保留历史版本，不参与后续研判。圈无高度字段；目标高度缺失不妨碍判圈。当前阶段只支持立即发布，不提供定时启停编辑。

## 发布评分因子版本

`POST /postgrest/rpc/save_defense_risk_scores`：

```json
{
  "p_expected_version": 1,
  "p_scores": {
    "zone_sensing": 20, "zone_tracking": 35, "zone_countermeasure": 50,
    "zone_hard_strike": 70, "zone_core": 85,
    "continuous_approach": 10, "fast_approach": 5,
    "next_ring_eta_60": 10, "next_ring_eta_30": 20, "identity_unverified": 5
  }
}
```

返回 `{ "version": 2 }`。要求传齐全部十项整数分值；固定因子条件、互斥分组和参数从旧版复制，不接受动态 SQL/条件表达式。圈层基础分由外到内严格递增且感知圈不少于 20 分。旧版变为 `retired`，历史内容保留。当前后台只开放分数调整；阈值及迟滞参数使用默认配置，不在 UI 中编辑。

截至 2026-09-25，配置已接入 Python 实时目标风险 worker 和态势查询 `riskAssessment`；正式告警/空域事件确认及设备控制仍未接入。圈名不代表实际反制设备授权或自动打击。运行与查询契约见 `target-risk-assessment-engine.md`。

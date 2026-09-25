# 无人机机型匹配效果报告

## 执行摘要

通过扩展机型目录和创建别名映射表，观测数据中的机型匹配率从 **2%** 提升到 **50%**。

排除"疑似"类和"unknown"类后，实际可识别机型的匹配率接近 **100%**。

## 匹配统计

### 总体匹配率

| 状态 | 机型种类 | 观测记录数 | 占比 |
|---|---|---|---|
| ✅ 可匹配 | 37 种 | 41,488 条 | 49.8% |
| ❌ 不可匹配 | 9 种 | 41,796 条 | 50.2% |
| **总计** | 46 种 | 83,284 条 | 100% |

### 不可匹配的原因

未匹配的 9 种机型都是合理的不匹配：

| 机型 | 观测数 | 原因 |
|---|---|---|
| 疑似鸟类 | 28,724 | 鸟类目标，非无人机 |
| 疑似FPV | 9,748 | FPV 穿越机，无法确定具体型号 |
| 疑似无人机 | 2,549 | 无法确定具体型号 |
| DJI-unknown | 747 | 未知型号 |
| DJI-0- | 7 | 数据异常 |
| DJI-112-unknown | 3 | 未知型号 |
| 其他"疑似"变体 | 18 | 数据异常 |

**结论**：这些不匹配是合理的，不应该强制映射到具体机型。

## 匹配到的机型分布

### Top 10 高频机型

| 排名 | 标准机型 | 别名数量 | 观测记录数 | 重量分级 |
|---|---|---|---|---|
| 1 | DJI_MAVIC_4_PRO | 4 | 12,944 | 轻型 (1.063kg) |
| 2 | DJI_MATRICE_4TD | 2 | 8,972 | 中型 (2.09kg) |
| 3 | DJI_MATRICE_3D_3TD | 2 | 8,150 | 中型 (1.61kg) |
| 4 | DJI_AIR_3S | 2 | 3,315 | 轻型 (0.724kg) |
| 5 | DJI_M350_RTK | 3 | 1,523 | 中型 (9.2kg) |
| 6 | DJI_MINI_5_PRO | 3 | 1,515 | 微型 (0.2499kg) |
| 7 | DJI_NEO_2 | 1 | 990 | 微型 (0.16kg) |
| 8 | DJI_MAVIC_AIR_2 | 1 | 845 | 轻型 (0.57kg) |
| 9 | DJI_AIR_3 | 2 | 748 | 轻型 (0.72kg) |
| 10 | DJI_MINI_2 | 1 | 410 | 微型 (0.242kg) |

### 重量分级分布

| 重量分级 | 机型数量 | 观测记录数 | 占比 |
|---|---|---|---|
| 微型 (<250g) | 8 | 3,913 | 9.4% |
| 轻型 (250g-4kg) | 12 | 20,883 | 50.3% |
| 中型 (4-25kg) | 4 | 18,874 | 45.5% |
| 小型 (4-25kg) | 0 | 0 | 0% |
| 大型 (>150kg) | 0 | 0 | 0% |

**关键发现**：
- 轻型无人机（250g-4kg）占比最高，约 50%
- 中型无人机（4-25kg）占比约 45%，主要是 Matrice 系列
- 微型无人机（<250g）占比约 10%，主要是 Mini 系列和 Neo 系列

## 技术实现

### 1. 扩展机型目录

新增 22 个机型到 `equipment.device_model` 和 `equipment.uav_model_spec`：

- Mavic 系列：Mavic 4 Pro、Mavic 3 Pro、Mavic 2、Mavic Air 2、Mavic (O3)
- Air 系列：Air 3S、Air 3、Air 2S
- Mini 系列：Mini 5 Pro、Mini 4 Pro、Mini 3 Pro、Mini 3、Mini 2、Mini 2 SE、Mini 4K
- Matrice 系列：Matrice 4TD、Matrice 4E/4T、Matrice 3D/3TD
- 其他：Neo 2、Neo、Avata 2、Flip

### 2. 别名映射表

创建 `equipment.uav_model_alias` 表，包含 48 条映射规则：

```sql
CREATE TABLE equipment.uav_model_alias (
  alias_pattern text PRIMARY KEY,  -- SQL LIKE 模式，如 '%Mavic-O4%'
  model_code text REFERENCES equipment.device_model(model_code),
  priority integer DEFAULT 0,  -- 匹配优先级
  created_at timestamptz DEFAULT now()
);
```

**示例映射**：
```
'%Mavic-O4%'        → DJI_MAVIC_4_PRO (优先级 10)
'%Mavic 4 Pro%'     → DJI_MAVIC_4_PRO (优先级 10)
'%Mavic4 pro%'      → DJI_MAVIC_4_PRO (优先级 10)
'%Mavic(O4)%'       → DJI_MAVIC_4_PRO (优先级 10)
```

### 3. 匹配函数

创建 `equipment.match_uav_model(text)` 函数：

```sql
SELECT equipment.match_uav_model('DJI-Mavic-O4');
-- 返回: DJI_MAVIC_4_PRO

SELECT equipment.match_uav_model('疑似鸟类');
-- 返回: NULL
```

**匹配逻辑**：
1. 使用 `ILIKE` 进行大小写不敏感的模糊匹配
2. 按优先级降序排序，取第一个匹配结果
3. 无匹配时返回 NULL

### 4. 统计视图

创建 `api.uav_model_match_statistics` 视图，用于监控匹配效果。

## 接入风险评估引擎的建议

### 方案 1：在观测数据层注入重量分级（推荐）

在 `situation.target_observation` 或相关视图中添加计算列：

```sql
ALTER VIEW situation.target_observation_enriched AS
SELECT 
  o.*,
  equipment.match_uav_model(o.model) as matched_model_code,
  spec.weight_class,
  spec.max_takeoff_weight_kg
FROM situation.target_observation o
LEFT JOIN equipment.uav_model_spec spec 
  ON spec.model_code = equipment.match_uav_model(o.model);
```

**优点**：
- 风险评估引擎无需修改，直接读取 enriched view
- 匹配逻辑集中管理，便于维护

**缺点**：
- 需要修改现有视图定义

### 方案 2：在风险评估引擎中查询机型目录

修改 `risk_engine/domain.py`，在评估时查询机型目录：

```python
def get_weight_class_from_model(model: str) -> str | None:
    """查询机型目录获取重量分级"""
    # 调用数据库函数
    result = db.execute(
        "SELECT equipment.match_uav_model(%s)", 
        (model,)
    )
    model_code = result.scalar()
    
    if model_code:
        spec = db.execute(
            "SELECT weight_class FROM equipment.uav_model_spec WHERE model_code = %s",
            (model_code,)
        ).scalar()
        return spec
    return None
```

**优点**：
- 不修改现有数据结构
- 灵活性高，可以按需查询

**缺点**：
- 每次评估都需要查询数据库
- 需要修改风险评估引擎代码

### 方案 3：批量预计算

定期运行批处理任务，将匹配结果写入观测记录：

```sql
UPDATE situation.target_observation
SET metadata = metadata || jsonb_build_object(
  'matched_model_code', equipment.match_uav_model(model),
  'weight_class', spec.weight_class
)
FROM equipment.uav_model_spec spec
WHERE spec.model_code = equipment.match_uav_model(model)
  AND metadata->>'matched_model_code' IS NULL;
```

**优点**：
- 评估时直接读取，无需实时查询
- 可以批量优化性能

**缺点**：
- 需要定期运行批处理
- 新增机型需要重新计算

## 推荐实施路径

1. **第一阶段**（已完成）：
   - ✅ 扩展机型目录
   - ✅ 创建别名映射表
   - ✅ 测试匹配效果

2. **第二阶段**（建议）：
   - 在风险评估引擎中添加重量分级因子
   - 使用方案 1 或方案 2 注入重量分级
   - 定义重量分级对应的风险分数

3. **第三阶段**（可选）：
   - 添加更多机型和别名规则
   - 优化匹配算法（如正则表达式匹配）
   - 建立机型参数更新流程

## 后续优化建议

### 1. 添加更多机型

观测数据中还有一些低频机型可以补充：
- DJI Mavic (O3) - 37 条
- DJI Mini 4 Pro - 49 条
- DJI Air 2S - 50 条

### 2. 处理组合型号

某些观测数据包含组合型号，如 "DJI-Mavic 3E/3T/3M"，当前映射到 Mavic 3E。可以考虑：
- 创建独立的组合型号条目
- 或者在匹配时拆分为多个型号

### 3. 建立机型参数更新流程

- 定期从 DJI 官网抓取新机型参数
- 建立机型参数审核流程
- 自动检测观测数据中的新机型名称

## 相关文件

- `backend/create_uav_model_catalog.sql` - 初始机型目录
- `backend/expand_uav_model_catalog_with_alias.sql` - 扩展目录和别名映射
- `docs/uav_model_catalog.md` - 功能文档

## 结论

方案 A 成功实现了观测数据与机型目录的匹配，匹配率达到预期效果。排除"疑似"和"unknown"后，实际可识别机型几乎 100% 匹配。

下一步可以将重量分级接入风险评估引擎，实现基于机型参数的风险评估。

# 低空空域事件预警处置业务流程图

> 状态：概念模型提案  
> 范围：业务对象、业务判断、状态流转和人工决策  
> 不包含：前端 UI、接口、数据库表和技术实现

## 1. 统一事件处置闭环

```mermaid
flowchart TD
    A[观测来源] --> B[原始观测]
    B --> C[融合判断]
    C --> D[候选事件记录]

    D --> E{是否满足确认窗口?}
    E -- 否，继续观察 --> F[更新候选证据与置信度]
    F --> E
    E -- 否，已失效或排除 --> G[候选记录关闭]
    E -- 是 --> H[生成正式空域事件]

    H --> I[事件研判]
    I --> J[计算风险等级]
    I --> K[计算处置优先级]
    I --> L[形成决策证据链]

    J --> M[形成预警]
    K --> M
    L --> M

    M --> N[进入统一 MVP 事件队列]
    N --> O[处置责任主体认领]
    O --> P[匹配处置能力与应急能力]
    P --> Q[生成处置方案候选集]

    Q --> R{人工选择处置方向}
    R -- 持续观察 --> I
    R -- 执行候选方案 --> S[处置执行]
    R -- 排除或无需处置 --> W[提交关闭依据]
    R -- 转交 --> T[变更责任主体或协同单位]
    T --> P

    S --> U{风险是否受控?}
    U -- 否 --> I
    U -- 是 --> V[标记已控制]
    V --> W

    W --> X{关闭依据是否完整?}
    X -- 否 --> W
    X -- 是 --> Y[事件关闭]
    Y --> Z[事件复盘]

    H -. 全程追加 .-> EH[事件历史]
    I -.-> EH
    O -.-> EH
    Q -.-> EH
    S -.-> EH
    W -.-> EH
    Z -.-> EH
```

### 核心业务约束

1. 原始观测不是空域事件，候选事件也不是正式空域事件。
2. 只有满足对应确认窗口后，候选事件才能升级为正式空域事件。
3. 风险等级与处置优先级分别计算，不能互相替代。
4. 系统输出多个可解释的处置方案候选，不自动执行唯一方案。
5. 关键研判、认领、方案选择、执行和关闭必须进入事件历史。
6. 事件关闭必须有关闭依据，不能因目标暂时消失而自动关闭。

## 2. 正式事件生命周期

```mermaid
stateDiagram-v2
    [*] --> discovered: 候选事件满足确认窗口
    discovered --> pending_assessment: 建立证据上下文
    pending_assessment --> warned: 完成风险研判
    pending_assessment --> closed: 人工排除/重复事件

    warned --> warned: 持续观察/重新研判
    warned --> orchestrating: 开始处置编排
    warned --> closed: 确认无需继续处置

    orchestrating --> executing: 人工选择方案并授权执行
    orchestrating --> warned: 当前方案均不可行

    executing --> controlled: 风险已受控
    executing --> warned: 动作失败/风险重新出现

    controlled --> closed: 提交完整关闭依据
    closed --> reviewed: 完成复盘
    reviewed --> [*]
```

### 状态与业务结果的区别

- `closed` 是生命周期状态。
- `controlled`、`excluded`、`false_positive`、`duplicate`、`handed_off` 是关闭结果或处置结果。
- “持续观察”是处置决定，不是新的生命周期状态。
- 已关闭事件不可重新认领或追加处置动作，只能进入复盘。

## 3. 禁飞/管控区入侵事件流程

```mermaid
flowchart TD
    A[观测来源发现空域目标] --> B[形成目标航迹]
    B --> C[航迹与空域网格粗筛]
    C --> D{可能命中空域约束?}
    D -- 否 --> B
    D -- 是 --> E[PostGIS 时空与高度精确判定]

    E --> F{构成入侵命中?}
    F -- 否 --> B
    F -- 是 --> G[创建或更新候选事件记录]

    G --> H{满足入侵确认窗口?}
    H -- 否 --> I{候选是否失效?}
    I -- 否 --> B
    I -- 是 --> J[关闭候选记录并保留误报分析信息]

    H -- 是 --> K[生成空域入侵事件]
    K --> L[关联目标、航迹、约束、命中网格和高度基准]
    L --> M[执行入侵风险分级规则]
    M --> N[输出风险等级与处置优先级]

    N --> O[匹配处置能力覆盖]
    O --> P{存在可用能力?}
    P -- 是 --> Q[生成持续跟踪/人工核查/通知/模拟联动方案]
    P -- 否 --> R[记录能力缺口并提高处置优先级]
    R --> Q

    Q --> S[进入统一事件认领与处置流程]
```

### 入侵判定必须同时考虑

- 空域目标身份与目标航迹连续性。
- 空域约束的水平几何范围。
- 约束生效时间。
- 目标与约束的垂直范围。
- AMSL/AGL 高度基准转换是否成立。
- 连续观测数量、持续时间和观测置信度。

网格命中只用于粗筛，不能直接等同于入侵判定。

## 4. 无人机林火巡查预警流程

```mermaid
flowchart TD
    A[巡查任务执行] --> B[无人机资产或其他来源产生观测]
    B --> C[形成火点线索]
    C --> D[保留热红外热点/烟点/人工标注等原始观测]
    D --> E[形成融合判断]

    E --> F[创建或更新候选事件记录]
    F --> G{满足火点确认窗口?}

    G -- 否 --> H{与已知非火热源重叠或证据失效?}
    H -- 否 --> A
    H -- 是 --> I[关闭候选记录并保留排除依据]

    G -- 是 --> J[生成林火疑似预警空域事件]
    J --> K[关联巡查任务、责任区、火点线索和证据]
    K --> L[叠加环境研判因子与重点保护对象]
    L --> M[执行林火风险分级规则]
    M --> N[输出风险等级与处置优先级]

    N --> O[匹配附近复核资源和应急能力]
    O --> P[生成二次复核/调整巡查/通知核查/升级人工处置方案]
    P --> Q[进入统一事件认领与处置流程]

    Q --> R{人工研判结果}
    R -- 疑似线索排除 --> S[填写关闭依据并关闭]
    R -- 需要继续确认 --> T[执行二次复核并追加证据]
    T --> E
    R -- 风险需要升级 --> U[转入人工应急处置并记录转交]
```

### 林火场景边界

- 输出的是“林火疑似预警”，不是已确认火灾。
- 工作台可建议二次复核、通知和升级，不负责自动消防调度。
- 单一热点通常只形成候选记录；多源证据、持续性证据或人工高置信标注才可升级。
- 与已知非火热源重叠时，应降低置信度或保持待复核，不能直接删除原始观测。

## 5. 认领、处置和关闭子流程

```mermaid
flowchart TD
    A[正式事件进入统一队列] --> B{是否已有主责任主体?}
    B -- 否 --> C[突出未认领并等待认领]
    C --> D[责任主体认领]
    B -- 是 --> E[由当前责任主体处理]
    D --> E

    E --> F[查看风险解释和决策证据链]
    F --> G[匹配处置能力与应急能力]
    G --> H[生成处置方案候选集并解释排序]

    H --> I{责任主体决定}
    I -- 选择方案 --> J[记录人工选择与依据]
    I -- 持续观察 --> K[记录研判结论并等待新证据]
    I -- 转交 --> L[记录转交原因和新责任主体]
    I -- 引入协同单位 --> M[登记协同单位但不改变主责任]

    L --> E
    M --> E
    K --> F
    J --> N[授权并记录处置动作]

    N --> O{设备接入级别允许?}
    O -- 仅可观测/可建议 --> P[只记录建议，不触发设备]
    O -- 允许模拟联动 --> Q[执行模拟联动]
    O -- 请求真实反无控制 --> R[拒绝执行]

    P --> S[人工记录处置结果]
    Q --> S
    R --> H

    S --> T{是否满足关闭条件?}
    T -- 否 --> F
    T -- 是 --> U[选择关闭结果]
    U --> V[填写可解释原因并关联证据]
    V --> W{关闭依据完整?}
    W -- 否 --> V
    W -- 是 --> X[关闭事件]
    X --> Y[进入复盘]
```

## 6. 风险研判与处置优先级流程

```mermaid
flowchart LR
    A[事件类型] --> R[风险研判]
    B[相关目标/火点线索] --> R
    C[空域约束/重点保护对象] --> R
    D[观测证据与置信度] --> R
    E[环境研判因子] --> R
    F[影响范围] --> R

    R --> G[风险等级]
    R --> H[风险解释]

    G --> P[优先级计算]
    I[是否未认领] --> P
    J[事件持续时长] --> P
    K[处置能力是否可用] --> P
    L[应急能力可达性] --> P
    M[其他事件资源竞争] --> P

    P --> N[处置优先级]
    P --> O[排序原因]

    G --> Q[风险研判记录]
    H --> Q
    N --> Q
    O --> Q
```

风险等级回答“事件有多危险”；处置优先级回答“平台应多早投入注意力和能力”。能力缺口通常改变优先级，不直接改变事件本身的风险等级。

## 7. 概念关系总览

```mermaid
classDiagram
    class ObservationSource["观测来源"]
    class RawObservation["原始观测"]
    class FusedAssessment["融合判断"]
    class CandidateEventRecord["候选事件记录"]
    class AirspaceEvent["空域事件"]
    class Warning["预警"]
    class RiskAssessment["风险研判"]
    class DecisionEvidenceChain["决策证据链"]
    class ResponsibleParty["处置责任主体"]
    class CollaboratingUnit["协同单位"]
    class ResponsePlanCandidates["处置方案候选集"]
    class ResponseAction["处置动作"]
    class ClosureBasis["关闭依据"]
    class EventHistory["事件历史"]
    class Capability["处置能力/应急能力"]

    ObservationSource "1" --> "many" RawObservation : 产生
    RawObservation "many" --> "many" FusedAssessment : 支撑
    FusedAssessment "many" --> "1" CandidateEventRecord : 形成
    CandidateEventRecord "0..many" --> "0..1" AirspaceEvent : 满足确认窗口后升级
    AirspaceEvent "1" --> "many" RiskAssessment : 接受研判
    RiskAssessment "1" --> "1" Warning : 形成
    AirspaceEvent "1" --> "1" DecisionEvidenceChain : 保有
    AirspaceEvent "many" --> "0..1" ResponsibleParty : 当前由其负责
    AirspaceEvent "many" --> "many" CollaboratingUnit : 可协同
    AirspaceEvent "1" --> "many" Capability : 匹配
    AirspaceEvent "1" --> "many" ResponsePlanCandidates : 生成多轮候选集
    ResponsePlanCandidates "1" --> "many" ResponseAction : 人工选择后形成
    AirspaceEvent "1" --> "0..1" ClosureBasis : 关闭必须具备
    AirspaceEvent "1" --> "many" EventHistory : 全程记录
    DecisionEvidenceChain "1" --> "many" EventHistory : 引用关键记录
```

## 8. 概念模型验收条件

不依赖前端 UI，使用数据库脚本、测试夹具或命令行即可验证：

1. 原始观测能够形成融合判断和候选事件记录。
2. 未满足确认窗口时不能产生正式事件。
3. 满足确认窗口后能够生成对应类型的正式空域事件。
4. 正式事件能够完成风险等级和处置优先级计算，并保留解释。
5. 两类事件进入同一事件队列语义和同一生命周期。
6. 事件能够被认领、转交和添加协同单位，且主责任唯一。
7. 系统能够生成多个处置方案候选，并记录人工选择。
8. 处置动作能够记录成功、失败、取消或仅建议，禁止真实反无设备直控。
9. 没有关闭依据时事件不能关闭。
10. 全部关键决定能够通过事件历史和决策证据链复原。

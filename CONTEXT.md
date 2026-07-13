# Low-Altitude Airspace Large-Screen Decision-Support Platform（低空空域大屏展示与辅助决策平台）

This project is positioned as a large-screen display and decision-support platform for low-altitude airspace, not as a full operational command system or direct device-control platform. This context names the business concepts used to display situation, assess risks, prioritize events, recommend responses, and review decisions involving targets, constraints, observations, response capabilities, emergency resources, and UAV inspection activities.
本项目定位为低空空域大屏展示与辅助决策平台，而不是完整作战指挥系统或直接设备控制平台。本上下文用于统一态势展示、风险研判、事件优先级、处置建议、决策复盘，以及空域目标、空域约束、观测、处置能力、应急资源和无人机巡查活动相关的业务语言。

## Language

**Authentication Entry Service（认证入口服务）**:
A lightweight authentication boundary that verifies management-login credentials and issues platform JWTs carrying the PostgREST database role claim.
平台当前阶段的轻量认证边界，负责校验管理入口登录凭证，并签发带有 PostgREST 数据库角色声明的平台访问令牌。
_Avoid_: Login System, User Center, Permission System, API Gateway, 独立登录系统、用户中心、权限系统、API 网关

**Low-Altitude Airspace Event Response Loop（低空空域事件处置闭环）**:
The platform's main business loop for discovering, assessing, warning, recommending responses, dispatching resources, and reviewing risks or emergency situations in low-altitude airspace.
平台的主业务闭环，围绕低空空域中的风险目标或灾害场景，完成发现、研判、预警、处置建议、资源调度和复盘。
_Avoid_: UAV Management Platform, Prevention Warning Platform, Disaster Emergency Platform, Smart Decision Platform, 无人机管理平台、防控预警平台、灾害应急平台、智慧决策平台

**Airspace Event（空域事件）**:
A business object that requires platform assessment or response, triggered by a target, constraint, environment, disaster, device, or manual report only when warning, decision-making, dispatch, response, or review is needed.
需要平台研判或处置的业务对象，可由目标、规则、环境、灾害、设备或人工上报触发；只有需要预警、决策、调度、处置或复盘时才成立。
_Avoid_: Raw Event, Data Change, Alert, 原始事件、数据变化、告警

**Aircraft Asset（无人机资产）**:
A registered UAV or aircraft asset that can be displayed, managed, or assigned by the platform.
已登记、可被平台展示、管理或调度的己方或授权无人机资产。
_Avoid_: UAV, Target, 无人机、目标

**Airspace Target（空域目标）**:
An airborne object discovered by radar, radio detection, electro-optical observation, manual report, or another source and then tracked or assessed by the platform.
被雷达、无线电、光电、人工等来源发现并进入跟踪或研判流程的空中对象，可能是未知无人机、授权无人机、鸟群、航模或误报。
_Avoid_: UAV, Asset, 无人机、资产

**Warning（预警）**:
A risk state or prompt produced after an Airspace Event is assessed; it is not an inherent property of an Airspace Target.
空域事件经过研判后形成的风险状态或提示结果，不是空域目标的固有属性。
_Avoid_: Target Risk, Alert, 目标风险、告警

**Airspace Grid（空域网格）**:
A BeiDou/GGER grid cell or cell set used to normalize the spatial influence of low-altitude airspace objects for indexing and situation aggregation while source objects keep their precise coordinates or geometries.
用于归一化表达低空空域对象空间影响范围的北斗/GGER 网格单元或网格集合，是平台的空间索引与态势聚合单元；原始对象仍保留真实坐标或几何。
_Avoid_: Map Tile, Display Grid, 地图格子、展示网格
**Airspace Grid（空域网格）**:
A BeiDou/GGER grid cell or cell set used to normalize the spatial influence of low-altitude airspace objects for indexing and situation aggregation while source objects keep their precise coordinates or geometries.
用于归一化表达低空空域对象空间影响范围的北斗/GGER 网格单元或网格集合，是平台的空间索引与态势聚合单元；原始对象仍保留真实坐标或几何。
_Avoid_: Map Tile, Display Grid, 地图格子、展示网格

**Airspace Class（空域类别）**:
A regulatory or foundational classification of airspace, such as W or G, that describes the class's control character, service expectations, flight requirements, and vertical or spatial scope.
法规或基础分类意义上的空域类型，如 W 类或 G 类，用于表达该类空域的管制属性、服务要求、飞行要求以及垂直或空间范围。
_Avoid_: Suitability, Grid Level, Display Layer, 适飞性、网格层级、展示图层
**Airspace Class（空域类别）**:
A regulatory or foundational classification of airspace, such as W or G, that describes the class's control character, service expectations, flight requirements, and vertical or spatial scope.
法规或基础分类意义上的空域类型，如 W 类或 G 类，用于表达该类空域的管制属性、服务要求、飞行要求以及垂直或空间范围。
_Avoid_: Suitability, Grid Level, Display Layer, 适飞性、网格层级、展示图层

**Airspace Class Candidate Zone（空域类别候选区）**:
A derived business display zone that estimates where an Airspace Class, such as W or G, could apply based on height semantics and applicable exclusion rules; it is not the same as an officially designated Airspace Class boundary and does not depend on an Airspace Suitability Footprint.
根据高度语义和适用排除规则推导出的业务展示区域，用于表达 W 类或 G 类等空域类别可能适用的候选范围；它不等同于正式划设的空域类别边界，也不依赖空域适飞基底范围。
_Avoid_: Official Airspace Class, Confirmed Boundary, Suitability Footprint, 正式空域类别、确权边界、适飞基底范围
**Airspace Class Candidate Zone（空域类别候选区）**:
A derived business display zone that estimates where an Airspace Class, such as W or G, could apply based on height semantics and applicable exclusion rules; it is not the same as an officially designated Airspace Class boundary and does not depend on an Airspace Suitability Footprint. W/G candidate zones are mutually exclusive in this project: W Candidate covers [0,120)m AGL and G Candidate covers [120,300]m AGL.
根据高度语义和适用排除规则推导出的业务展示区域，用于表达 W 类或 G 类等空域类别可能适用的候选范围；它不等同于正式划设的空域类别边界，也不依赖空域适飞基底范围。本项目中 W/G 候选区互斥：W 候选覆盖真高 [0,120) 米，G 候选覆盖真高 [120,300] 米。
_Avoid_: Official Airspace Class, Confirmed Boundary, Suitability Footprint, 正式空域类别、确权边界、适飞基底范围

**Airspace Suitability Footprint（空域适飞基底范围）**:
A two-dimensional business assessment footprint indicating the horizontal area that may participate in suitable-airspace voxelization; it may already reflect exclusions such as controlled airport airspace, while its vertical range is derived from an Airspace Class Candidate Zone or other explicit height semantics applied to it.
表达可参与适飞空域体素化的二维业务评价基底范围；它可已体现机场管制空域等排除结果，但自身只定义水平范围，垂直范围由叠加的空域类别候选区或其他明确高度语义派生。
_Avoid_: Airspace Class, 3D Airspace Volume, No-Fly Zone, 空域类别、三维空域体、禁飞区

**Airspace Suitability Zone（空域适飞区）**:
A business assessment zone indicating whether flight is suitable, restricted, unsuitable, or unknown within a spatial and height-datum context; it may be generated by combining an Airspace Suitability Footprint with an Airspace Class Candidate Zone.
在特定空间范围和高度基准语义下表达飞行适宜、受限、不适宜或未知的业务评价区域；它可由空域适飞基底范围叠加空域类别候选区生成。
_Avoid_: Airspace Class, W/G Class, No-Fly Zone, 空域类别、W/G 类、禁飞区

**Airspace Constraint（空域约束）**:
A time-and-space restriction on flight, transit, sensing, or emergency dispatch; no-fly zones, temporary control zones, disaster emergency areas, environmental risk areas, and advisory areas are all Airspace Constraints.
某个时空范围内对飞行、通行、侦察或应急调度的限制条件；禁飞区、临时管控区、灾害应急区、环境风险区和普通业务建议区都属于空域约束。
_Avoid_: No-Fly Zone, Rule, Control Zone, 禁飞区、规则、管控区

**Flight Obstacle（飞行障碍）**:
A spatial object or range that blocks, restricts, or changes the feasibility of a target track or planned flight path while preserving traceability to its source.
会阻挡、限制或改变目标航迹或规划航线可行性的空间对象或空间范围，并且需要保留来源可追溯性。
_Avoid_: Obstacle Layer, Building, No-Fly Zone, 障碍图层、建筑物、禁飞区

**Response Capability Coverage（处置能力覆盖）**:
The effective spatiotemporal coverage of a detection, identification, tracking, jamming, spoofing, forced-landing, or capture capability.
某种探测、识别、跟踪、干扰、诱骗、迫降或捕获能力在特定时空范围内的有效覆盖。
_Avoid_: Countermeasure Range, Device Coverage, 反制范围、设备覆盖区

**Response Orchestration（处置编排）**:
The process of selecting response strategies, matching Response Capability Coverage, generating recommended actions, or triggering authorized linkage actions for an Airspace Event.
平台围绕空域事件选择处置策略、匹配处置能力覆盖、生成操作建议或触发已授权联动动作的过程。
_Avoid_: Countermeasure Device Control, Remote Device Control, 反制设备控制、设备遥控

**Device Access Level（设备接入级别）**:
The highest business collaboration level authorized for a third-party device, not merely its technical connectivity; the levels are observable, recommendable, linkable, and controllable.
平台对某个第三方设备在业务上被授权使用的最高协作程度，而不是单纯技术连接能力；包括可观测、可建议、可联动和可控制四级。
_Avoid_: API Capability, Device Permission, API 能力、设备权限

**Assessment Factor（研判因子）**:
A data factor that can change Airspace Event risk assessment, response feasibility, or emergency dispatch results.
会改变空域事件风险判断、处置可行性或应急调度结果的数据因素。
_Avoid_: Background Layer, Display Data, 背景图层、展示数据

**Risk Level（风险等级）**:
An explainable risk result produced by assessing an Airspace Event, traceable to causes, evidence, impact area, related targets, related constraints, assessment factors, and recommended actions.
空域事件经过研判后形成的可解释风险结果，必须能追溯到触发原因、证据、影响范围、相关目标、相关约束、研判因子和建议动作。
_Avoid_: Display Color, Alert Color, 展示颜色、告警颜色

**Emergency Resource（应急资源）**:
A person, material, vehicle, Aircraft Asset, sensor, temporary communication device, or similar object that can be dispatched for response; it answers “what is available”.
可被调度参与处置的人员、物资、车辆、无人机资产、传感器或临时通信设备等对象；它回答“有什么”。
_Avoid_: Inventory, Ledger, 库存、台账

**Emergency Capability（应急能力）**:
An executable response capability formed by one or more Emergency Resources under specific time-and-space conditions; it answers “what can be done, where, when, and at what cost”.
由一个或多个应急资源在特定时空条件下形成的可执行处置能力；它回答“能做什么、在哪里、何时可用、代价是什么”。
_Avoid_: Resource, Material, 资源、物资

**Observation Source（观测来源）**:
A source that produces target observations, environmental observations, device status, or alerts, such as radar, electro-optical devices, radio detection, weather stations, electromagnetic monitoring, manual reports, or third-party platforms.
产生目标观测、环境观测、设备状态或告警的数据来源，如雷达、光电、无线电侦测、气象站、电磁监测、人工上报或第三方平台。
_Avoid_: Sensor, Device, 传感器、设备

**Situation Snapshot（态势快照）**:
A point-in-time integrated expression of Airspace Targets, Airspace Constraints, Assessment Factors, Response Capability Coverage, and Emergency Resource states for current assessment and large-screen display.
某一时刻平台对空域目标、空域约束、研判因子、处置能力覆盖和应急资源状态的综合表达，用于当前研判和大屏展示。
_Avoid_: Real-Time Stream, Current Data, 实时流、当前数据

**Event History（事件历史）**:
The state changes and key evidence recorded as an Airspace Event moves from discovery through assessment, warning, response recommendation, resource dispatch, closure, and review.
空域事件从发现、研判、预警、处置建议、资源调度到关闭和复盘的状态变化与关键证据记录。
_Avoid_: Log, Flow Record, State Log, 日志、流水

**Airspace Event Workbench（空域事件处置工作台）**:
The large-screen and duty-operator workspace organized around current Airspace Events, ordered by Response Priority and focused on events, risk, evidence, response capabilities, emergency capabilities, recommended actions, and execution state.
围绕当前待处理空域事件组织的大屏与值班操作界面，以处置优先级排序，优先呈现事件、风险、证据、处置能力、应急能力、推荐动作和执行状态。
_Avoid_: Situation Dashboard, Data Big Screen, 综合态势驾驶舱、数据大屏

**Airspace Event Lifecycle（空域事件生命周期）**:
The business state flow of an Airspace Event from discovery to review: discovered, pending assessment, warned, response orchestration in progress, response execution in progress, controlled, closed, and reviewed.
空域事件从发现到复盘的业务状态流转：发现、待研判、已预警、处置编排中、处置执行中、已控制、已关闭、已复盘。
_Avoid_: Alert Status, Handling Status, 告警状态、处理状态

**Closure Basis（关闭依据）**:
The explainable evidence and reason required when an Airspace Event is closed.
空域事件被关闭时必须记录的可解释证据和原因。
_Avoid_: Target Disappeared, Automatic Closure, 目标消失、自动关闭

**Response Plan Candidates（处置方案候选集）**:
An explainable ranked set of response plans produced by decision support, not a single automatic command.
智慧决策输出的可解释处置方案排序，而不是自动唯一命令。
_Avoid_: Single Plan, Automatic Decision, 唯一方案、自动决策

**Responsible Party（处置责任主体）**:
The person, team, organization, or external coordination unit currently responsible for assessing, responding to, or reviewing an Airspace Event.
对空域事件当前研判、处置或复盘负责的人、队伍、组织或外部协同单位。
_Avoid_: Approver, Operator, 审批人、操作员

**Disaster Emergency Scenario（灾害应急场景）**:
A high-priority scenario inside the Airspace Event Response Loop, not a parallel event system.
空域事件处置闭环中的高优先级业务场景，而不是平行的独立事件体系。
_Avoid_: Disaster Emergency Module, Independent Emergency System, 灾害应急模块、独立应急系统

**Raw Observation（原始观测）**:
An unnormalized record provided by an external source at a specific time and spatial range, retaining source, raw payload, confidence, intake channel, and processing status.
外部来源在特定时间和空间范围内提供的未归一化数据记录，保留来源、原始载荷、可信度、接入通道和处理状态。
_Avoid_: Business Data, Device Data, Interface Data, 业务数据、设备数据、接口数据

**Fused Assessment（融合判断）**:
The platform's current trusted explanation derived from multiple Raw Observations, retaining evidence, confidence, and conflict information.
平台基于多个原始观测形成的当前可信解释，必须保留证据、置信度和冲突信息。
_Avoid_: Overwrite Update, Latest Value, 覆盖更新、最新值

**No-Fly/Control-Zone Intrusion Event Loop（禁飞/管控区入侵事件闭环）**:
The first-stage minimum viable loop where an Airspace Target entering an Airspace Constraint creates an Airspace Event, receives a Risk Level, displays evidence and impact area, matches available Response Capability Coverage, proposes Response Plan Candidates, and records Event History.
第一阶段最小可用闭环：当空域目标进入空域约束范围时，平台生成空域事件，计算风险等级，展示证据和影响范围，匹配可用处置能力覆盖，给出处置方案候选集，并记录事件历史。
_Avoid_: Full Platform, Comprehensive Demo, 全量平台、综合演示

**Mixed Input（混合输入）**:
The MVP allowance to combine real configuration, manual entry, simulated tracks, historical tracks, static data, and low-frequency data to validate event loops and the domain model.
MVP 阶段允许同时使用真实配置、人工录入、模拟轨迹、历史轨迹、静态数据和低频数据来验证事件闭环与领域模型。
_Avoid_: Fully Simulated Input, Fully Live Integration, 全模拟、全量真实接入

**Height Datum（高度基准）**:
The vertical reference meaning of height values in Airspace Constraints, targets, route planning, and event evidence, such as AMSL, AGL, or ELLIPSOID.
解释空域约束、目标高度、航线规划和事件证据中高度数值含义的垂直参考语义，如 AMSL、AGL 或 ELLIPSOID。
_Avoid_: Height, Altitude, Relative Height, 高度、海拔、相对高度

**Intrusion Determination（入侵判定）**:
The business judgment that decides whether an Airspace Target has entered an Airspace Constraint.
判断空域目标是否进入空域约束的业务判断。
_Avoid_: Grid Hit, Geometry Intersection, 网格命中、几何相交

**Target Track（目标航迹）**:
The platform's continuous tracking result for the same Airspace Target over a period of time, including current state and historical observations.
平台对同一个空域目标在一段时间内的连续跟踪结果，包含当前状态和历史观测。
_Avoid_: Track Point, Point Sequence, 轨迹点、点序列

**Intrusion Confirmation Window（入侵确认窗口）**:
The duration, consecutive observation count, or confidence condition required to upgrade an Airspace Target hitting an Airspace Constraint from a candidate to a formal Airspace Event.
目标航迹命中空域约束后，从候选事件升级为正式空域事件所需的持续时间、连续观测点数或置信度条件。
_Avoid_: Immediate Alert, Single-Point Trigger, 立即告警、单点触发

**Candidate Event Record（候选事件记录）**:
A lightweight record created when a Target Track hits an Airspace Constraint but has not yet satisfied the Intrusion Confirmation Window.
目标航迹命中空域约束但尚未满足入侵确认窗口时产生的轻量记录。
_Avoid_: Airspace Event, Alert, 空域事件、告警

**Rule Template（规则模板）**:
An explainable rule set used in the MVP to produce Response Plan Candidates from event type, Risk Level, constraint type, Response Capability Coverage, and Device Access Level.
MVP 阶段生成处置方案候选集的可解释规则集合，按事件类型、风险等级、约束类型、处置能力覆盖和设备接入级别组合推荐方案。
_Avoid_: AI Decision, Automatic Optimization, AI 决策、自动优化

**Simulated Linkage（模拟联动）**:
A demo or test linkage that validates Response Orchestration, authorization records, action status, and Event History without triggering real third-party countermeasure actions.
在不触发真实第三方反制动作的前提下，验证处置编排、授权记录、动作状态和事件历史的演示或测试联动。
_Avoid_: Automatic Countermeasure, Real Control, 自动反制、真实控制

**Risk Classification Rule（风险分级规则）**:
A fixed, explainable, auditable rule set used in the MVP to produce Risk Levels.
MVP 阶段用于生成风险等级的固定、可解释、可审计规则集合。
_Avoid_: Rule Engine, Display Color Configuration, 规则引擎、展示颜色配置

**Response Priority（处置优先级）**:
The degree to which the platform should prioritize attention, personnel, devices, or Emergency Capabilities for an Airspace Event; it is different from Risk Level.
平台应优先投入注意力、人员、设备或应急能力处理某个空域事件的程度；它不同于风险等级。
_Avoid_: Risk Level, Alert Level, 风险等级、告警等级

**Event Claiming（事件认领）**:
A workflow action where a Responsible Party takes current primary handling responsibility for an Airspace Event.
处置责任主体对某个空域事件承担当前主处理责任的工作流动作。
_Avoid_: View Event, Handler Field, 查看事件、处理人

**Collaborating Unit（协同单位）**:
An external unit, team, or organization participating in an Airspace Event response without taking primary handling responsibility.
参与某个空域事件处置但不承担主处理责任的外部单位、队伍或组织。
_Avoid_: Primary Responsible Party, Collaboration Workflow, 主责任主体、协同流程

**Decision Evidence Chain（决策证据链）**:
The evidence set in Event History that supports key state changes, risk assessment, Response Orchestration, human choices, and Closure Basis.
事件历史中支撑关键状态变化、风险判断、处置编排、人工选择和关闭依据的证据集合。
_Avoid_: State Log, Operation Record, 状态日志、操作记录

**UAV Forest-Fire Patrol Warning Loop（无人机林火巡查预警闭环）**:
An MVP emergency-warning scenario where Aircraft Assets execute forest inspection tasks and use thermal hotspots, visible-smoke points, manual annotations, or historical tracks to form Fused Assessments and Suspected Forest-Fire Warnings.
MVP 中的应急预警场景：无人机资产执行林区巡查任务，基于热红外热点、可见光烟点、人工标注或历史轨迹形成融合判断，并生成林火疑似预警空域事件。
_Avoid_: Disaster Emergency System, Forest-Fire Business Platform, 灾害应急系统、林火业务平台

**Suspected Forest-Fire Warning（林火疑似预警）**:
An Airspace Event type in the UAV Forest-Fire Patrol Warning Loop indicating that the platform believes a location may have a forest fire and needs review, notification, or response.
无人机林火巡查预警闭环中的空域事件类型，表示平台认为某处可能发生林火，需要复核、通知或处置。
_Avoid_: Fire Situation, Confirmed Fire, UAV Alert, 火情、火灾确认、无人机告警

**Suspected Fire-Point Review Loop（疑似火点复核闭环）**:
The business boundary where the platform discovers a suspected fire point and triggers review, notification, or escalation without automatically confirming a fire.
平台发现疑似火点并触发复核、通知或升级处置的业务边界，但不自动确认火灾。
_Avoid_: Automatic Fire Confirmation, Fire Recognition System, 自动火灾确认、火灾识别系统

**Fire-Point Lead（火点线索）**:
A possible forest-fire-related observation object discovered by UAV inspection, sensors, or manual report, such as a thermal hotspot, visible-smoke point, suspected open flame area, abnormal temperature rise, or manual annotation.
无人机巡查、传感器或人工上报发现的可能与林火相关的观测对象，例如热红外热点、可见光烟点、明火疑似区域、异常温升或人工标注点。
_Avoid_: Fire, Confirmed Fire Situation, 火灾、火情

**Inspection Task（巡查任务）**:
A lightweight UAV patrol or inspection task in a specified time window over a forest area, Airspace Grid, region, or route.
无人机资产在指定时间窗口内，对某个林区、空域网格、区域或航线执行观测的轻量业务任务。
_Avoid_: Flight Task, Route Playback, 飞行任务、航线播放

**Reported Flight（报备飞行）**:
A display object ingested from an external approval or reporting source that represents a unit's planned or approved flight activity in a specified time window.
由外部审批或报备来源接入的平台展示对象，表示某个单位在指定时间窗口内计划或获准开展的飞行活动。
_Avoid_: Platform Approval Workflow, Internal Approval Form, 平台审批流程、内部审批单

**Flight Activity（飞行架次）**:
A unified planned or actual flight instance used for large-screen statistics and situation display, sourced from a Reported Flight or an Inspection Task.
用于大屏统计和态势展示的一次计划或实际飞行实例，可来源于报备飞行或巡查任务。
_Avoid_: Approval Record, Task Record, 审批记录、任务记录

**Patrol Responsibility Area（巡查责任区）**:
The forest area, reserve, manually drawn region, or Airspace Grid range covered by an Inspection Task.
巡查任务面向的林区、保护区、人工绘制区域或空域网格范围。
_Avoid_: Forest Layer, Independent Spatial System, 林区图层、独立空间体系

**Fire-Point Confirmation Window（火点确认窗口）**:
The multi-evidence, duration, consecutive-frame, or high-confidence manual annotation condition required to upgrade a Fire-Point Lead to a formal Suspected Forest-Fire Warning.
火点线索从候选林火预警升级为正式林火疑似预警所需的多证据、持续时间、连续帧数或人工高置信标注条件。
_Avoid_: Single-Point Fire Alert, Immediate Confirmation, 单点火警、立即确认

**Forest-Fire Risk Classification Rule（林火风险分级规则）**:
A fixed, explainable, auditable rule set for Suspected Forest-Fire Warnings that outputs the shared Risk Level and Response Priority.
用于林火疑似预警的固定、可解释、可审计风险分级规则，输出统一的风险等级与处置优先级。
_Avoid_: Intrusion Risk Rule, Fire Severity Grade, 入侵风险规则、火灾等级

**Forest-Fire Review and Notification（林火复核与通知）**:
The MVP response boundary for Suspected Forest-Fire Warnings: dispatch Aircraft Assets for secondary review, adjust Inspection Tasks, notify rangers or duty operators, recommend nearby Emergency Capabilities, and escalate to manual emergency handling when needed.
MVP 中林火疑似预警的处置边界：派无人机资产二次复核、调整巡查任务、通知护林员或值班员核查、推荐附近应急能力作为参考，必要时升级为人工应急处置流程。
_Avoid_: Firefighting Dispatch, Fire Command, 灭火调度、消防指挥

**MVP Event Queue（MVP 事件队列）**:
The shared Airspace Event handling queue used by the MVP for both No-Fly/Control-Zone Intrusion Events and Suspected Forest-Fire Warnings.
MVP 中禁飞/管控区入侵事件与林火疑似预警共用的空域事件处置队列。
_Avoid_: Intrusion Module, Forest-Fire Module, Separate Event List, 入侵模块、林火模块、独立事件列表

**Flight Path Plan（飞行路径规划方案）**:
A planned route request made of start, end, and optional waypoint control points, with planning settings such as cruise height, Height Datum, planning time, and safety buffer.
由起点、终点和可选航路点控制点组成的航线规划请求，并包含巡航高度、高度基准、计划飞行时间和安全缓冲等规划设置。
_Avoid_: Flight Activity, Reported Flight, Inspection Task, 飞行架次、报备飞行、巡查任务

**Flight Path Result（飞行路径规划结果）**:
The computed route, trajectory, grid path, and summary metrics produced from a Flight Path Plan.
根据飞行路径规划方案计算得到的路线、轨迹、网格路径和统计指标。
_Avoid_: Plan, Activity Route Preview, 规划方案、活动航线预览

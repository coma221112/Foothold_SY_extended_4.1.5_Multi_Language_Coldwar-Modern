# Foothold LLM State Design

## 目标

为 Foothold 任务提供一套面向 LLM 的无线电氛围导出方案。

LLM 不直接消费 DCS 世界对象的原始 dump，也不需要像参谋系统一样总结战役。它只消费三类信息：全局 zone 态势、当前任务、当前空中单位。目标是每 5 分钟生成一批中文无线电碎片，由任务脚本在下一次 submit 前轮播，让战场频道听起来更像活着的 Foothold 世界。

## 范围

- 面向蓝方广播。
- 输出中文。
- 允许给出轻量行动建议，但不要求每条都是建议。
- 遵守战争迷雾。
- 可以使用玩家名字，但只在态势中有上下文时偶尔使用。
- 可以使用虚构无线电呼号，但不能用来编造具体战果、传感器读数、天气、民航、民用车辆、热信号或精确坐标。
- 固定间隔生成一批广播内容，任务内轮播。

## 非目标

- 不让 LLM 直接分析所有 DCS units/groups。
- 不把 dormant group、隐藏刷怪模板、未公开敌情、内部 group/template name 直接暴露给 LLM。
- 不让 LLM 控制任务逻辑。
- 不把每条广播做成完整任务简报。

## 当前实现 Schema v2

```json
{
  "meta": {
    "schemaVersion": 2,
    "exporterVersion": "0.2.0",
    "missionTimeSec": 123,
    "map": "Syria",
    "era": "Coldwar",
    "audience": "blue"
  },
  "llmTask": {
    "output": "strict_json_array",
    "language": "zh-CN",
    "allowedSpeakers": ["AWACS", "蓝方战区指挥部", "前线管制", "JTAC", "友军飞机", "地面部队", "后勤频道", "塔台"],
    "allowedPriorities": ["high", "normal", "flavor"]
  },
  "world": {
    "summary": {
      "blueZones": 1,
      "redZones": 68,
      "neutralZones": 2,
      "blueCredits": 395,
      "activeBluePlayers": 1
    },
    "zones": [
      {
        "name": "Akrotiri",
        "side": "blue",
        "pos": { "x": -230, "z": -10, "unit": "km_grid" },
        "ground": "medium",
        "roughGroundCount": 6,
        "tags": ["airbase", "blue_main_base"]
      }
    ]
  },
  "missions": [
    {
      "type": "Attack",
      "zone": "Ercan",
      "waypoint": "WP12",
      "status": "active",
      "intel": "confirmed"
    }
  ],
  "airUnits": [
    {
      "display": "蓝方 CAP",
      "side": "blue",
      "role": "CAP",
      "origin": "Akrotiri",
      "area": "Ercan",
      "state": "taking_off",
      "intel": "confirmed"
    },
    {
      "display": "疑似红方 CAS",
      "side": "red",
      "role": "CAS",
      "origin": "Paphos",
      "area": "Akrotiri",
      "state": "airborne",
      "intel": "inferred"
    }
  ],
  "players": [
    {
      "name": "vesnow",
      "unitType": "AH-64D_BLK_II",
      "nearestZone": "Akrotiri",
      "role": "aircraft"
    }
  ],
  "radioMemory": {
    "lastTone": "unknown",
    "lastMentionedZones": []
  }
}
```

## State Schema v1 历史设计

以下是早期较重的参谋式 schema，保留作设计背景。当前实现已经收敛为上面的 v2。

```json
{
  "meta": {
    "schemaVersion": 1,
    "missionTimeSec": 12345,
    "map": "Syria",
    "era": "Coldwar/Modern",
    "audience": "blue"
  },
  "campaign": {
    "blueZones": 18,
    "redZones": 31,
    "neutralZones": 4,
    "blueCredits": 1200,
    "activeBluePlayers": 6
  },
  "activeObjectives": [
    {
      "type": "Attack",
      "zone": "Minakh",
      "waypoint": "WP12",
      "intel": "confirmed",
      "priority": "high"
    }
  ],
  "frontlineFocus": {
    "primaryAxis": {
      "friendlyZone": "Hatay",
      "enemyZone": "Minakh",
      "distanceNm": 18,
      "direction": "east"
    },
    "contestedPairs": [
      {
        "blue": "Hatay",
        "red": "Minakh",
        "distanceNm": 18
      }
    ]
  },
  "playerActivity": {
    "players": [
      {
        "name": "PlayerName",
        "unitType": "F/A-18C",
        "nearestZone": "Hatay",
        "role": "strike",
        "nearObjective": true
      }
    ],
    "summary": {
      "nearFrontline": 4,
      "nearObjectives": 2,
      "logisticsAircraft": 1
    }
  },
  "logisticsStatus": {
    "zonesNeedingSupply": [
      {
        "zone": "Hatay",
        "reason": "damaged_or_incomplete_upgrades",
        "priority": "high"
      }
    ],
    "activeSupplyRuns": [
      {
        "side": "blue",
        "from": "Akrotiri",
        "to": "Hatay",
        "state": "inair",
        "intel": "confirmed"
      }
    ]
  },
  "enemyPressure": {
    "summary": "red counterpressure rising near Minakh",
    "pressureZones": [
      {
        "zone": "Minakh",
        "pressure": "high",
        "intel": "inferred"
      }
    ],
    "knownEnemyActions": []
  },
  "activeFriendlySupport": {
    "cap": 1,
    "cas": 0,
    "sead": 1,
    "supply": 1
  },
  "recentEvents": [
    {
      "type": "objective_started",
      "objective": "Attack",
      "zone": "Minakh",
      "timeAgoSec": 120
    }
  ],
  "radioMemory": {
    "lastPrimaryFocus": "Hatay-Minakh",
    "lastTone": "offensive",
    "lastMentionedZones": ["Hatay", "Minakh"],
    "lastBatchSummary": "蓝方围绕 Hatay-Minakh 方向推进，补给压力上升。"
  }
}
```

## 字段来源

### meta

来源：

- `timer.getTime()` 或 `timer.getAbsTime()`
- 当前地图/任务配置变量
- 当前任务 era 配置

用途：

- 给 LLM 时间背景。
- 让后续 schema 能兼容升级。

### campaign

来源：

- `bc.zones`
- `bc.accounts`
- `getBluePlayersCount()`

用途：

- 提供战役大势。
- 不应作为主要广播内容，除非战局发生明显变化。

### activeObjectives

来源：

- `MissionCommander.missions` 中 `isRunning == true` 的任务
- `ActiveCurrentMission[zone]`
- 动态任务变量对应的 zone，例如 attack/resupply/capture/sead/dead/recon/runway

任务类型：

- `Attack`
- `Resupply`
- `Capture`
- `SEAD`
- `DEAD`
- `Recon`
- `CAP`
- `CAS`
- `Bomb runway`
- `Escort`
- `Strike`

用途：

- 这是广播主轴。
- 优先说玩家可执行的当前任务。

### frontlineFocus

来源：

- `Frontline`
- `bc.connections`
- `bc:getConnectionZones(connection)`
- zone side/active/suspended/isHidden

筛选原则：

- 只导出蓝红相邻或接近的关键接触面。
- 不导出全图所有连接。
- 优先包含 active objective 附近的前线。

用途：

- 让 LLM 知道主攻方向和压力方向。
- 支持连续广播，例如“仍以 Hatay-Minakh 方向为主”。

### playerActivity

来源：

- `coalition.getPlayers(coalition.side.BLUE)`
- `unit:getPlayerName()`
- `unit:getTypeName()`
- `bc:getZoneOfPoint(unit:getPoint())`
- active objective / frontline distance 判断

规则：

- 玩家名字可以进入 state。
- LLM 只能在玩家靠近任务区、前线、补给区，或有明确行动上下文时偶尔点名。
- 不做随机点名。

### logisticsStatus

来源：

- `ZoneCommander:canRecieveSupply()`
- `_needsSupplyForMenu`
- `_supplyMenuUpgradeCount`
- `_supplyMenuTotalUpgrades`
- active supply `GroupCommander`
- `bc:getActiveSupplyCount(side, targetZone)`
- warehouse low supply 数据，如存在

用途：

- 给运输机、直升机、地面补给玩家提供方向。
- 避免 LLM 只关注空战和攻击。

### enemyPressure

来源：

- red reactive pressure 摘要
- `bc._redReactivePressureByZone`
- 前线距离/玩家接近红方前线
- 已公开的 ActiveMission / MissionTargets / recon intel

规则：

- 只能导出 `inferred` 或已确认敌情。
- 不导出 dormant group。
- 不导出未公开的具体敌方编队、数量、型号、路线。

### activeFriendlySupport

来源：

- `bc:getActiveCAPCount(2, missionType)`
- `bc:getActiveStrikeCount(2, "attack", missionRole, unitCategory)`
- `bc:getActiveSupplyCount(2, targetZone)`

用途：

- 避免 LLM 建议重复请求已经存在的支援。
- 让广播能提到“已有 CAP/SEAD/补给在路上”。

### recentEvents

来源：

- exporter 自己保存上一份 snapshot 并计算 delta。
- zone side 变化。
- active objective 新增/结束。
- supply need 新增/消失。
- player focus 明显变化。
- red reactive pressure 明显变化。

初期可先实现：

- `objective_started`
- `objective_ended`
- `zone_captured`
- `zone_lost`
- `supply_needed`
- `supply_resolved`
- `frontline_focus_changed`

### radioMemory

来源：

- mission side 保存上一批 LLM 输出摘要。
- exporter 保存上一轮主方向、语气、重点 zone。

用途：

- 避免每 5 分钟像失忆一样重新广播。
- 如果态势没有明显变化，继续沿用主方向。
- 如果态势变化，明确切换重点。

## 情报分级

### confirmed

可以明确广播。

包括：

- MissionCommander 已公开任务。
- ActiveCurrentMission zone 标签。
- 玩家已侦察/任务系统公开的目标。
- 已触发 ActiveMission / MissionTargets。
- 已发生的 zone capture/lost。
- 已公开的补给需求。

### inferred

可以模糊广播。

包括：

- 红方前线压力上升。
- 敌方可能组织反击。
- 某方向敌方反应增强。
- 补给压力增加。

措辞要求：

- 使用“迹象”“可能”“压力上升”“需要警惕”等表达。
- 不给具体未确认单位、数量、型号、坐标。

### hidden

不能进入 LLM state，或只能经过摘要降级为 inferred。

包括：

- dormant group。
- 未触发刷怪模板。
- 未公开敌机/防空/车队。
- 纯脚本知道但玩家无从得知的路线和目标。

## LLM 输出格式

LLM 每次返回严格 JSON 数组：

```json
[
  {
    "speaker": "蓝方战区指挥部",
    "priority": "high",
    "text": "蓝方注意，哈塔伊到米纳赫方向仍是当前主攻轴线。固定翼优先压制目标区防空与装甲威胁。"
  }
]
```

字段约束：

- `speaker` 必须来自白名单。
- `priority` 只能是 `high`、`normal`、`flavor`。
- `text` 为中文。
- 每条 1 到 2 句。
- 每条最多约 90 个中文字符。
- 每批 6 到 10 条。

speaker 白名单：

- `蓝方战区指挥部`
- `前线管制`
- `JTAC`
- `友军飞机`
- `地面部队`
- `后勤频道`

## Prompt v1

```text
你是 Foothold 战场无线电频道编排器。

根据用户提供的 world.zones、missions、airUnits 和 players，生成 6 到 10 条中文无线电碎片，用于未来 5 分钟轮播。

允许的 speaker：
- AWACS
- 蓝方战区指挥部
- 前线管制
- JTAC
- 友军飞机
- 地面部队
- 后勤频道
- 塔台

要求：
- 输出严格 JSON 数组，不要 Markdown，不要解释。
- 每项包含 speaker、priority、text。
- priority 只能是 high、normal、flavor。
- 每条 1 到 2 句，最多约 90 个中文字符。
- 可以严肃，也可以像频道里随口聊天，不要都像任务简报。
- 空中单位发言必须来自 airUnits。
- 地面部队发言必须绑定 world.zones 里真实存在的 zone。
- 可以使用虚构呼号，但不能用虚构呼号编造战果、传感器读数、天气、民航、民用车辆、热信号或精确坐标。
- 可以偶尔提到玩家名字，但只能在态势中有上下文时使用。
- 只能使用 confirmed 或 inferred 情报。
- hidden 情报不能说。
- 红方 inferred 情报必须使用“可能”“迹象”“疑似”“监测到”等不确定措辞。
- 可以根据 zone 归属、低精度位置和 ground 强度描述模糊态势。
- 不要引用内部 group name，不要编造不存在的单位、zone、任务或战果。
```

## 示例输出

```json
[
  {
    "speaker": "蓝方战区指挥部",
    "priority": "high",
    "text": "蓝方注意，哈塔伊到米纳赫方向仍是当前主攻轴线。固定翼优先压制目标区防空与装甲威胁。"
  },
  {
    "speaker": "后勤频道",
    "priority": "normal",
    "text": "哈塔伊补给需求上升，运输机和直升机可准备进入补给窗口。"
  },
  {
    "speaker": "前线管制",
    "priority": "normal",
    "text": "米纳赫方向敌方反应有增强迹象，各机进入目标区前保持高度和航线间隔。"
  },
  {
    "speaker": "友军飞机",
    "priority": "flavor",
    "text": "锤头二号正在前线外侧盘旋，目视范围内火光不少，没看到可以确认的新增目标。"
  }
]
```

## 轮播规则建议

- LLM submit 间隔：5 分钟。
- 每批生成：6 到 10 条。
- 轮播间隔：25 到 45 秒随机。
- 单条显示时长：20 到 30 秒。
- `high` 可以优先播放。
- 同一 speaker 不连续超过 2 条。
- 同一 zone 同一主题每批最多出现 2 次。
- 至少 2 条行动建议。
- 至少 2 条氛围无线电。

## 失败降级

LLM 请求失败时：

- 不刷错误到玩家屏幕。
- 优先继续播放上一批未过期内容。
- 如果没有可用内容，使用本地 fallback。

fallback 示例：

```text
蓝方战区指挥部：当前通信链路不稳定，各机继续执行现有任务，优先关注地图标记目标。
```

## 调试文件

当 `.llmenv` 中设置：

```text
FOOTHOLD_LLM_DEBUG_FILES=true
FOOTHOLD_LLM_WORK_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
FOOTHOLD_LLM_DEBUG_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
```

当前约定是 LLM 运行包集中放在：

```text
C:\Users\Drac\Saved Games\DCS\Missions\LLM
```

该目录包含：

- `.llmenv`
- `llmbridge.dll`
- `FootholdLLM_state.json`
- `FootholdLLM_raw_response.txt`
- `FootholdLLM_batch.json`
- `native.log`
- `inputoutput.log`

mission exporter 会写出：

- `FootholdLLM_state.json`：本次提交给 DLL/LLM 的语义 state。
- `FootholdLLM_raw_response.txt`：DLL 返回给 mission 的原始 LLM 文本。
- `FootholdLLM_batch.json`：mission 成功解析后准备轮播的 radio batch。

DLL 自身使用同一个工作目录：

- `native.log`
- `inputoutput.log`，当 `LLM_DEBUG_IO=true` 时写入完整 HTTP 请求/响应。

## 关键 `.llmenv` 参数

```text
LLM_SYSTEM_PROMPT="你是 Foothold 战场无线电频道编排器。..."
FOOTHOLD_LLM_SUBMIT_INTERVAL=300
FOOTHOLD_LLM_TICK_INTERVAL=10
FOOTHOLD_LLM_BROADCAST_DURATION=30
FOOTHOLD_LLM_RADIO_MIN_INTERVAL=25
FOOTHOLD_LLM_RADIO_MAX_INTERVAL=45
FOOTHOLD_LLM_DEBUG_FILES=true
LLM_WORK_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
LLM_LOG_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
FOOTHOLD_LLM_WORK_DIR=C:\Users\Drac\Saved Games\DCS\Missions\LLM
FOOTHOLD_LLM_DLL_PATH=C:\Users\Drac\Saved Games\DCS\Missions\LLM\llmbridge.dll
FOOTHOLD_LLM_MAX_ZONES=120
FOOTHOLD_LLM_MAX_MISSIONS=16
FOOTHOLD_LLM_MAX_AIR_UNITS=24
```

## 实现步骤

1. Mission exporter 生成 schema v2：`world.zones`、`missions`、`airUnits`、`players`。
2. DLL 用 OpenAI-compatible chat completions 请求模型。
3. Mission 端解析 JSON batch，按 25 到 45 秒间隔轮播。
4. debug 开关打开时，state、原始响应、解析后的 batch 都写入 `DCS\Missions\LLM`。

## 待验证

- `MissionCommander.missions` 中不同任务的 title/zone/target 字段是否足够统一。
- `ActiveCurrentMission` 是否能覆盖所有玩家可见 zone mission。
- `bc:getZoneOfPoint()` 对空中玩家定位是否稳定。
- zone 地面力量的模糊强度是否足够让 LLM 写出自然的地面频道。
- 本地模型、DeepSeek、Gemini 对 schema v2 的守规程度差异。
- LLM JSON 返回异常时的 parser/fallback 行为。

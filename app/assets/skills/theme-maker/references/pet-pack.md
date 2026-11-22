# 宠物包格式（pet pack）

宠物包是 dsh-go 的桌宠数据：一个 ZIP（或一个目录）里一份 `pack.json` 加若干图集 PNG。
手机在「设置 › 宠物 › 导入」校验并安装；主题包也能带一个宠物包（见 `appearance-theme.md` §6）。

- 权威实现：`app/lib/pets/pet_pack.dart`（字段解析）、`pet_pack_validator.dart`（ZIP/JSON/PNG/图集）、`pet_library.dart`（安装）。
- 运行时：Flutter 端和内嵌悬浮窗（`PetPack.kt`）读同一份包，悬浮窗的导入门更严（整数与帧格几何）。
- 离线自查：`scripts/pet_pack_check.py`（对目录），导入前必须 PASS。

## 1. 目录 / ZIP 结构

```
pack.json
idle.png            # 图集，文件名由 pack.json 的 sheet 字段引用
thinking.png
...
```

- `pack.json` 必须恰好 1 个：在 ZIP 根，或**恰好一层**目录里（`cat/pack.json`）。目录形式导入时，`pack.json` 在被导入目录的根。
- 图集名必须是**平铺的 PNG 文件名**：不能带 `/`、`\`、NUL，不能以 `.` 开头，不区分大小写地以 `.png` 结尾。
- ZIP：加密、非 store/deflate 压缩、路径穿越、NFC+casefold 重名、非常规条目全部拒绝；条目 ≤256、ZIP ≤64 MiB、解压总量 ≤64 MiB。
- 未引用的额外文件会被忽略，导入后不保留。

## 2. `pack.json` 字段

`schema` 目前只接受 `1`。必填：`schema`、`id`、`canvas`、`contentBox`、`animations`、`states.idle`。

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `schema` | number | — | 必须 `1` |
| `id` | string | — | 非空；安装时会映射成 `user-…`（见 §6） |
| `name` | string | `id` | 展示名 |
| `author` / `license` / `source` | string | 无 | 本地可缺省；工坊要求三项齐全。宠物页底部显示 `author · license` |
| `pixelArt` | bool | `true` | 像素画：缩放取整数倍、边缘锐利 |
| `scale` | number | `1` | 源图相对逻辑像素的倍率；导入门要求整数 `1..4096` |
| `canvas` | `{w,h}` | — | 画布逻辑尺寸，正数；导入门要求整数 `1..2^30` |
| `anchor` | `{x,baseline}` | 画布中心 / 底边 | `x` 是水平中心（镜像轴），`baseline` 是脚线 |
| `contentBox` | `{x,y,w,h}` | — | 身体范围，决定大小档缩放；`w,h` 必须为正 |
| `animations` | object | — | 动画名 → 动画，不能为空，见 §3 |
| `states` | object | — | 状态名 → 动画名数组，必须含 `idle`，见 §4 |
| `tiers` | object | 无 | 状态 → `[{min, anim}]`，按会话数分档 |
| `timings` | object | 无 | `minDisplay` / `autoReturn` / `playMs` / `wakeMs`，毫秒 |
| `reactions` | object | 无 | 反应名 → 动画名（或数组），见 §5 |
| `roam` | object | 无 | `{anim, faces: "left"\|"right"\|"front"}`；`flip:false` 也等于正面 |
| `sleep` | object | 无 | `{afterMs}`，默认 60000 |
| `hitBoxes` | object | 无 | `{default, wide, sleeping, wideAnims, sleepingAnims, byAnim}`，逻辑像素；缺省用 `contentBox` |
| `idlePool` | object/list | 无 | 随机待机，见 §4 |
| `bonus` | object | 无 | 状态 → `{anims:[...], chance:0..1}` 彩蛋 |

未知字段会被忽略（不会因为多写字段拒绝），但导出时会被丢掉。字段里出现的动画名必须真实存在于 `animations`。

## 3. `animations` 与图集几何

每个动画：

```json
"idle": {
  "sheet": "idle.png",
  "frameW": 180, "frameH": 120, "cols": 21,
  "box": { "x": 12, "y": 26, "w": 36, "h": 24 },
  "loop": true,
  "frames": [ { "i": 0, "ms": 50 }, { "i": 1, "ms": 50 } ]
}
```

- `sheet`：图集文件名；一张图可以给多个动画用。
- `frameW`/`frameH`：**每个格子的像素宽高**，必须正整数，并且（导入门）等于 `trunc(Float32(Float32(box.w/h) × scale))`。
- `cols`：图里每行几格；默认单行横条。约束：`cols ≤ 图宽 // frameW`，且 `(最大帧号 // cols + 1) ≤ 图高 // frameH`。
- `box`：该动画的帧格贴回画布的位置（逻辑像素），`w,h > 0`。
- `frames`：`{i, ms}` 数组；`i` 是图里第几格（≥0），`ms` 是这一帧时长（>0）。相同帧只存一格，靠重复的 `i` 引用。导入门要求 `i`/`ms` 都是整数，缺字段的帧直接拒绝（App 解析会跳过，悬浮窗不会）。
- `loop`：默认 `true`；`false` 表示播一遍。

图集规则：每格/每张图每边 ≤4096，解码后 `w×h×4 ≤16 MiB`，压缩后单文件 ≤8 MiB，整包 ≤64 张、合计 ≤48 MiB；必须是完整可解码的 PNG（CRC、IDAT、zlib、filter 全部检查），拒绝 APNG、未知关键块、尾随数据。

## 4. 状态（状态名沿用 Clawd on Desk）

| 状态 | 含义 |
|---|---|
| `idle` | 空闲（必填，`states.idle[0]` 是基础待机） |
| `thinking` | 思考中 |
| `working` | 干活（可按会话数分档） |
| `juggling` | 同时跑多个对话 |
| `error` | 出错 |
| `attention` | 做完了 / 等你 |
| `notification` | 等你确认或回答 |
| `sweeping` | 压缩上下文 |
| `carrying` | 搬东西（工具调用等） |
| `sleeping` | 睡觉（60 秒无操作） |
| `waking` | 被唤醒 |
| `roam` | 游走 |

`states`：状态 → 动画名数组；缺某个状态时播 `states.idle[0]`；未知状态名会被接受（以后扩展用）。

`tiers`：只在需要的状态上分档，例如 `"working": [{"min": 3, "anim": "building"}, {"min": 1, "anim": "typing"}]`；没写 `tiers` 就播该状态的主动画。

`idlePool`：随机待机插播。

```json
"idlePool": {
  "everyMs": { "mean": 120000, "min": 45000, "max": 300000 },
  "anims": [ { "anim": "idle-look", "ms": 6800, "weight": 1 } ]
}
```

只在空闲且可见时计时；`ms` 为 0 表示播一遍。基础待机 `states.idle[0]` 不放进池子。

`timings`：`minDisplay`（状态至少停留）、`autoReturn`（自动回 idle 的上限）、`playMs`（一次性动画时长）、`wakeMs`（唤醒动画时长），单位毫秒。

## 5. 反应（触摸互动）

```json
"reactions": {
  "tapLeft": "poke-left", "tapRight": "poke-right",
  "tickle": "tickle", "tickle2": "tickle-b", "tickle3": "tickle-c",
  "annoyed": "annoyed", "drag": "drag"
}
```

- 常用反应名：`tapLeft`、`tapRight`、`tickle`、`annoyed`、`drag`。没写某个反应时，对应的手势静默跳过，不报错。
- 同一反应有多个候选时，用「基础名 + 编号」：`tickle`、`tickle2`、`tickle3`…。旧版 App 只读基础名、忽略编号键；当前 App 合并成候选列表随机抽。**数组写法只在本 App 内可读，跨版本分享用编号。**
- 基础名不存在时，孤立的 `tickle2` 保留为独立反应名（不会被静默丢掉）。
- 需要在状态外保持固定姿势的地方（如拖动）只读第一项。

## 6. 安装与 id

- 装到 `<应用支持目录>/pets/<安装 id>/`，并把 `pack.json` 里的 `id` 改写成这个安装 id。
- 安装 id 由 `userPetIdFor(pack.json 的 id)` 决定（`app/lib/pets/pet_ids.dart`）：
  - 去掉已有 `user-` 前缀后，若 ≤48 字符且是小写 kebab-case，安装 id = `user-<它>`；
  - 否则把非 `[a-z0-9]` 换成 `-`、截到 32 字符，拼 `-` + 原 id 的 sha256 前 8 位（空 slug 用 `pet`）。
  - 例：`cat` → `user-cat`；`小猫` → `user-pet-<8 位哈希>`。同一个 id 再导入还是同一只。
- 主题包带宠物时，`theme.json` 的 `pet.id` 必须正好等于这个安装 id（写主题参考 §6）。
- 导入走 staging + 原子替换；失败不会留下半只宠物。

## 7. 校验与错误

`pet_pack_check.py <pack-dir>` 覆盖：

1. **JSON**：严格 UTF-8（无 BOM、无重复键、无非有限数、无孤立代理项、深度 ≤64），再过 `PetPack.parse`。
2. **悬浮窗导入门**：`scale`、`canvas`、`frameW`/`frameH`、`cols`、每帧 `i`/`ms` 必须是整数；`frameW/H = trunc(Float32(Float32(box) × scale))`；不能有缺字段的帧。
3. **图集**：名字安全、存在、PNG 完整、尺寸/文件/总量上限。
4. **帧范围**：每段动画的每一帧都在图集内。
5. **引用**：`states.*[]`、`tiers.*[].anim`、`reactions.*`、`roam.anim`、`idlePool[].anim`、`bonus.*.anims[]` 都必须指向存在的动画。

失败时按脚本输出的错误改；`--compat-reactions` 还会要求反应值是普通字符串（旧版 App 也认的写法）。`check_theme_pack.py` 里的宠物部分使用 `theme-pet-*` 错误码，含义见 `appearance-theme.md` §6。

**校验通过 ≠ 真机效果**：不同机型、悬浮窗尺寸和系统字体都可能让观感不同，最后请用户在手机上导入看一眼。

## 8. 相关脚本

| 脚本 | 用途 |
|---|---|
| `pet_theme_convert.py` | 素材目录 → 宠物包目录（clawd-on-desk 主题、GIF/APNG/WebP/PNG、逐帧目录、Aseprite、单图） |
| `pet_pack_check.py` | 宠物包目录离线校验（必须 PASS） |
| `make_pet_pack.py` | 底层打包/取色库，转换脚本依赖它 |
| `pet_svg_frames.py` | clawd-on-desk 主题里 SVG/CSS 关键帧的光栅化 |

## 9. 常见坑

1. 把整张精灵表直接丢进去：先拆帧或导出 Aseprite JSON。
2. 一个目录混放多种素材：转换脚本只认一种，混放请分开。
3. `box` 和 `scale` 对不上：导入门按 Kotlin 浮点算法算帧格，差 1 像素就拒。用 `pet_theme_convert.py`/`make_pet_pack.py` 生成，不要手写。
4. 图集用 GIF/WebP 改名：必须真 PNG。
5. 状态名写错不会报错，只会一直播 idle；用上面表里的 Clawd 状态名。
6. 动画名被引用但没定义：整包拒绝。
7. 第三方同人素材（尤其 CC BY-NC-SA）只做自用转换，不打包进发行版或市场。

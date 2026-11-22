# 外观主题包格式（theme pack）

一个主题包就是一个 ZIP，里面一个 `theme.json`（可选带图片、字体，以及配套宠物 `pet.zip`）。
手机在「设置 › 外观 › 导入主题包 (.zip)」校验并安装；本文件只写手机真的会检查的规则。

- 权威实现：`app/lib/themes/theme_pack.dart`（字段与解析）、`theme_pack_validator.dart`（ZIP/素材/上限）、`theme_library.dart`（导入与用户可见错误）。
- 离线自查：`scripts/check_theme_pack.py`（本技能里），导入前必须 PASS。

## 0. 一页速查

- 必填只有 3 个：`schema`、`id`、`name`。其余都有默认值。
- `schema` 是 **1 或 2**。普通主题写 1；带 `pet` 的必须写 2（`pet` 不能出现在 schema 1 里）。
- 素材引用写成和 `theme.json` **同目录的纯文件名**，不能带目录、`..`、绝对路径。
- 图片只收 **PNG**（`.png`，扩展名大小写不敏感，内容必须是真 PNG）；字体只收 **`.ttf`/`.otf`**。
- 颜色只接受 `#RRGGBB` 或 `#AARRGGBB`（8 位是 **AARRGGBB**，alpha 在前）。
- 所有层级**未知字段一律拒绝**，不做拼写容错、不做前向兼容。
- 图片：单文件 ≤8 MiB、单边 ≤4096、`宽×高×4 ≤16 MiB`；字体单文件 ≤16 MiB；所有被引用素材合计 ≤32 MiB；`theme.json` ≤128 KiB；ZIP ≤64 MiB、条目 ≤256、解压总量 ≤64 MiB。
- 自定义字体最多 **2 个不同文件**。
- 本地导入不要求 `author`/`license`/`source`；投稿工坊（market）要求三者齐全且 `license` 在白名单里。

## 1. 包结构

```
# 形式 A：theme.json 在 ZIP 根
theme.json
bg.png                # 可选，仅当 theme.json 引用
hero.png              # 可选
book.otf              # 可选
pet.zip               # 可选，带宠物的主题包
preview.png           # 可选，未被引用的额外文件会被忽略（导入后也不保留）
```

```
# 形式 B：theme.json 在一层目录内（素材必须同目录）
pack/theme.json
pack/bg.png
pack/book.otf
pack/pet.zip
```

- `theme.json` 候选必须**恰好 1 个**：名字精确等于 `theme.json`，或在**恰好一层**目录下（`pack/theme.json`）。`a/b/theme.json` 不合法；根和目录各放一个也不合法（`archive-theme-count`）。
- 素材按「`theme.json` 所在目录 + 引用名」查找，逐字符精确匹配（大小写、Unicode 形式都敏感）。`pack/theme.json` 只能引用 `pack/xxx.png`。
- ZIP 内所有条目按 NFC + casefold 去重：`bg.png` 和 `BG.png` 同时存在直接拒绝（`archive-duplicate`）。
- 拒绝加密、非 store/deflate 压缩、目录以外的非常规条目、绝对路径、反斜杠、`..`、含 `:` 的路径段。

## 2. 顶层字段

未知字段的报错文案是 `Unknown theme.json field: <key>`，统一由 UI 显示为 `theme-schema`。

| 字段 | 类型 | 必填 | 默认 | 约束 |
|---|---|---|---|---|
| `schema` | number | **是** | — | `1` 或 `2`；`1.0` 也接受，`"1"` 拒绝；>2 → `theme-schema-version` |
| `id` | string | **是** | — | 小写 kebab-case `^[a-z0-9]+(?:-[a-z0-9]+)*$`，≤40 字符 |
| `name` | string | **是** | — | 非空白，≤120 字符，不能有控制字符/孤立代理项 |
| `title` | object | 否 | 无 | 只允许 `zh`、`en`，值同 `name` 规则；`{}` 合法 |
| `description` | string | 否 | `""` | 允许 `""`；否则非空白、≤512 字符 |
| `tags` | string[] | 否 | `[]` | ≤8 个，每个非空白、≤32 字符，**唯一** |
| `author` | string | 否 | 无 | 非空白、≤256 字符 |
| `license` | string | 否 | 无 | 非空白、≤100 字符；market 必须白名单 |
| `source` | string | 否 | 无 | 非空白、≤2048，必须是合法 `https` URL（无空白、有 host、无 userinfo） |
| `palette` | object | 否 | 默认 seed `#4B67B4` | §3.1 |
| `surfaces` | object | 否 | `preset: glass` | §3.2 |
| `typography` | object | 否 | 系统字体 | §3.3 |
| `shapes` | object | 否 | 布局默认值 | §3.4 |
| `components` | object | 否 | 组件默认值 | §3.5 |
| `emptyState` | object | 否 | 空状态默认值 | §3.6 |
| `pet` | object | 否 | 无 | 只有 schema 2 允许；§6 |

`palette`/`surfaces`/`typography`/`shapes`/`components`/`emptyState` 写 `null` 等价于省略。

文本细则：`name`/`title` 里不能有 `<0x20` 控制字符（换行、制表符会拒绝）；`tags` 的「唯一」区分大小写；`description` 是唯一允许空串的非必填文本。

## 3. 嵌套结构

### 3.1 `palette`

| 字段 | 默认 | 取值 |
|---|---|---|
| `seed` | `#4B67B4` | 颜色 |
| `seedDark` | 无 | 颜色；深色模式的显式种子 |
| `tintHue` | 无 | `0..360` |
| `tintChroma` | `1.0` | `0..2` |
| `glowOpacity` | `1.0` | `0..1` |
| `light` | `{}` | 21 个颜色 token 的子集，明色模式覆盖 |
| `dark` | `{}` | 同上，暗色模式覆盖 |

颜色 token（21 个，大小写敏感）：`backdropTop`、`backdropBottom`、`glowPrimary`、`glowSecondary`、`surface`、`onSurface`、`onSurfaceVariant`、`outline`、`outlineVariant`、`primary`、`onPrimary`、`primaryContainer`、`onPrimaryContainer`、`userBubble`、`onUserBubble`、`assistantBubble`、`onAssistantBubble`、`codeWellBg`、`codeWellHeader`、`codeWellFg`、`codeWellBorder`。

- `light`/`dark` 不是两套必填配色，只写想覆盖的 token；其余由 seed 派生。
- token 写显式 `null` 合法（等于没写）。
- 未知 token → `palette.light.<key> is not a supported color token`。

### 3.2 `surfaces`

| 字段 | 默认 | 取值 |
|---|---|---|
| `preset` | `glass` | `glass` \| `paper` \| `flat` \| `outlined` |
| `chromeBlur` / `sheetBlur` | 无 | `0..40` |
| `cardOpacity` / `pillOpacity` | 无 | `0..1` |
| `hairlineWidth` | 无 | `0..3` |
| `rimOpacity` / `shadowOpacity` | 无 | `0..1` |
| `backdropImage` | 无 | 同目录 PNG 纯文件名 |
| `backdropOpacity` | `0.18` | `0..1`；**只有存在 `backdropImage` 时导出** |
| `backdropRepeat` | `false` | bool；**只有存在 `backdropImage` 且为 true 时导出** |

没有 `backdropImage` 时写 `backdropOpacity`/`backdropRepeat` 不报错，但会被静默丢弃。

### 3.3 `typography`

| 字段 | 默认 | 取值 |
|---|---|---|
| `uiFont` / `readingFont` / `headingFont` | `system` | 内置角色或自定义 `.ttf`/`.otf` 文件名 |
| `codeFont` | `JetBrainsMono` | 同上 |
| `readingScale` | `1.0` | `0.85..1.25` |
| `readingLineHeight` | `1.55` | `1.2..2.0` |
| `headingScale` | `1.0` | `0.85..1.35` |

内置角色（区分大小写）：`system`、`serif`、`mono`、`JetBrainsMono`、`monospace`。不在集合里的值会被当成自定义素材名，必须是以 `.ttf`/`.otf` 结尾的纯文件名且真实存在；去重后最多 2 个字体文件（同一文件可给多个角色复用）。

### 3.4 `shapes`

| 字段 | 默认 | 范围 |
|---|---|---|
| `cornerScale` | `1.0` | `0..1.6` |
| `borderWidth` | `0.5` | `0..2.5` |
| `turnGap` | `24.0` | `12..40` |
| `inTurnGap` | `8.0` | `4..20` |
| `gutter` | `16.0` | `10..28` |

### 3.5 `components`

枚举值必须精确匹配（区分大小写，`floatingGlass` 不能写 `floating_glass`）。

| 字段 | 默认 | 取值 |
|---|---|---|
| `headerStyle` | `glass` | `glass` \| `ghost` \| `outlined` \| `minimal` |
| `composerStyle` | `floatingGlass` | `floatingGlass` \| `solidPaper` \| `outlined` |
| `sendButtonStyle` | `primary` | `primary` \| `ink` \| `tonal` |
| `userBubbleStyle` | `soft` | `soft` \| `outlined` \| `accent` \| `minimal` |
| `assistantStyle` | `plain` | `plain` \| `card` \| `leftRule` |
| `suggestionCardStyle` | `glass` | `glass` \| `paper` \| `outlined` \| `minimal` |
| `codeBlockStyle` | `well` | `well` \| `outlined` \| `card` |
| `useReadingFontForReply` | `false` | JSON bool（`"true"` 拒绝） |

### 3.6 `emptyState`

| 字段 | 默认 | 取值 |
|---|---|---|
| `layout` | `centered` | `centered` \| `editorial` \| `compact` |
| `heroStyle` | `whale` | `whale` \| `badge` \| `customImage` \| `hidden` |
| `heroImage` | 无 | 同目录 PNG 纯文件名 |
| `useReadingFontForGreeting` | `false` | bool |
| `showConnectedSubtitle` | `true` | bool |
| `suggestionsDisplay` | `expanded` | `expanded` \| `collapsible` \| `grid` |

- `heroStyle: customImage` 时 `heroImage` **必填**。
- 只要写了 `heroImage`（即使 `heroStyle` 不是 `customImage`），它也会被当成引用图片校验并安装；但界面不会用它。

## 4. 素材规则

被引用的素材只有两类：

- 图片：`surfaces.backdropImage`、`emptyState.heroImage`；
- 字体：`typography` 里所有非内置角色值（去重）。

素材名规则：长度 1..80，`^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$`，不得含 `..`，扩展名必须匹配（图片 `.png`；字体 `.ttf`/`.otf`，不区分大小写）。所以 `assets/bg.png`、`.hidden.png`、`bg.jpeg`、`bg.png.bak` 都过不了 schema。

图片校验顺序：

1. 非空且 ≤8 MiB → 否则 `theme-asset-too-large`；
2. PNG 签名、IHDR、可读尺寸 → 否则 `theme-png-header`；
3. 宽高各 `1..4096` 且 `宽×高×4 ≤16 MiB` → 否则 `theme-png-dimensions`；
4. 完整 PNG（chunk CRC、IHDR/PLTE/tRNS 合法、连续 IDAT、zlib EOF/Adler32、scanline 长度与 filter byte、真实像素解码、拒绝 APNG/未知关键块/尾随数据）→ 否则 `theme-png-corrupt`。

结论：**JPEG/WebP 改名成 `.png` 一定失败**；带 APNG 动画的截图也失败。字体只查大小和 4 字节 magic（`0x00010000`、`OTTO`、`true`），不解析字体表；11 字节以下或 magic 不对 → `theme-font-invalid`。

未引用的额外文件不校验、也不会写进安装目录。

## 5. 限额

| 项目 | 上限 |
|---|---|
| `theme.json` | 128 KiB |
| 单个图片 | 8 MiB |
| 单个字体 | 16 MiB（且 ≥12 字节） |
| 被引用素材合计 | 32 MiB |
| 图片单边 | 4096 px |
| 图片解码后 | 16 MiB（`w×h×4`） |
| 自定义字体文件数 | 2 |
| ZIP 文件 | 64 MiB |
| ZIP 条目数 | 256（含目录条目） |
| ZIP 解压总量 | 64 MiB |
| `pet.zip` 成员 | 64 MiB（再按宠物自己的规则查，见 `pet-pack.md`） |

## 6. 配套宠物：`pet` 与 `pet.zip`（schema 2）

```json
{
  "schema": 2,
  "id": "xmas-night",
  "name": "圣诞雪夜",
  "pet": { "id": "user-xmas-narwhal", "name": "雪独角鲸" }
}
```

- `pet` 只能出现在 **schema 2** 里；schema 1 写 `pet` → `theme.json pet requires schema 2`。
- `pet` 只允许 `id`/`name` 两个键，其他键拒绝。
- `pet.id`：必填，必须是已安装用户宠物的 `user-…` id：`user-` 开头、总长 ≤64、`user-` 后缀是小写 kebab-case（`^[a-z0-9]+(?:-[a-z0-9]+)*$`）。**不是**宠物包自己的 id。
- `pet.name`：可选，仅展示用，≤120 字符；不写时安装时用宠物的 `pack.json` 里的 `name` 补。
- ZIP 里必须有一个名为 **`pet.zip`** 的成员（与 `theme.json` 同目录；`pack/theme.json` 对应 `pack/pet.zip`），内容是一个完整的宠物包 zip（`pack.json` + 图集）。
- 校验顺序与错误码：
  - 有 `pet` 但没有 `pet.zip` → `theme-pet-missing`；
  - 有 `pet.zip` 但没有 `pet` → `theme-pet-unexpected`；
  - `pet.zip` 不是合法 ZIP → `theme-pet-archive`；
  - 宠物包体量超限（zip 64 MiB、条目 256、解压总量 64 MiB、`pack.json` 256 KiB、单图集 8 MiB、图集数 64、图集合计 48 MiB）→ `theme-pet-too-large`；
  - 宠物 `pack.json` 字段/JSON 有误 → `theme-pet-pack`；
  - 图集缺失、PNG 损坏、引用不存在的动画 → `theme-pet-asset`；
  - **`pet.id` 与 `userPetIdFor(pet.zip 里 pack.json 的 id)` 不一致** → `theme-pet-id`，detail 形如 `user-xmas-narwhal != user-other`。
- `userPetIdFor` 的算法（`app/lib/pets/pet_ids.dart`）：id 去掉已有 `user-` 前缀后，若是 ≤48 字符的小写 kebab-case，结果就是 `user-<它>`；否则把非 `[a-z0-9]` 换成 `-`、截到 32 字符、再拼 `-` + 原 id 的 sha256 前 8 位（空 slug 用 `pet`）。**别手算，用 `make_theme_pack.py --pet` 生成。**
- 安装顺序：宠物先装，再装主题；宠物失败则主题不动。宠物装好后在「设置 › 宠物」里可选。
- **导出与投稿会剥离宠物**：导出的 zip 只有 `theme.json` + 被引用素材，`pet` 被移除且 schema 回到 1；工坊上架的是纯主题。宠物只留在装它的手机上。

## 7. 错误码与用户提示

导入层把校验码归成 7 类（`theme_library.dart` → UI）：

| 码 | 用户看到 |
|---|---|
| `archive-size`、`archive-entries`、`archive-expanded-size`、`archive-member-size`、`theme-size`、`theme-asset-too-large`、`theme-asset-total-size`、`theme-pet-too-large` | 体积超限 |
| `theme-asset-missing`、`theme-pet-missing`、`archive-member-missing` | 缺少素材（带文件名） |
| `archive-path`、`theme-asset-alias`、`theme-png-*`、`theme-font-*`、`theme-pet-asset` | 图片或字体无效 |
| `archive-theme-count` | 找不到 `theme.json` |
| 其余 `json-*`、`theme-*`（含 `theme-schema`、`theme-json-object`、`theme-metadata`、`theme-pet-*` 里未列出的） | 主题配置格式有误 |
| 其他 ZIP 结构错误（`archive-invalid` 等） | 不是有效 ZIP |
| 写盘失败 | 无法写入本地存储 |

`theme.json` 里的 JSON 层：BOM → `json-bom`；语法/尾随内容 → `json-syntax`；重复键 → `json-duplicate-key`；`NaN`/`Infinity` → `json-number`；深度 >64 → `json-depth`；孤立代理项 → `json-unicode`。

## 8. 两个最小合法示例

### 8.1 schema 1：无素材的最小浅色主题

ZIP 里只有 `theme.json`：

```json
{
  "schema": 1,
  "id": "quiet-mist",
  "name": "Quiet Mist",
  "palette": { "seed": "#3F6FD8" },
  "surfaces": { "preset": "paper" }
}
```

只留 `schema`/`id`/`name` 也合法；保留 `palette`/`surfaces` 让主题有明确外观。生成等价包：

    python3 scripts/make_theme_pack.py --id quiet-mist --name "Quiet Mist" \
        --seed "#3F6FD8" --mode light --out quiet-mist.zip

### 8.2 schema 2：带配套宠物（和素材）的主题

```json
{
  "schema": 2,
  "id": "ink-scroll",
  "name": "墨卷",
  "title": { "zh": "墨卷", "en": "Ink Scroll" },
  "palette": { "seed": "#8A5A3C", "dark": { "backdropTop": "#0E0906", "surface": "#19100B" } },
  "surfaces": {
    "preset": "paper",
    "backdropImage": "texture.png",
    "backdropOpacity": 0.24
  },
  "typography": { "readingFont": "book.otf" },
  "emptyState": { "heroStyle": "customImage", "heroImage": "hero.png" },
  "pet": { "id": "user-cat", "name": "小猫" }
}
```

ZIP 内容：

```
theme.json
texture.png     # 真 PNG
hero.png        # 真 PNG（可以和 texture 共用同一个文件，此时只写一份）
book.otf        # 真 OTF（magic 校验通过）
pet.zip         # 宠物包，其 pack.json 的 id 为 cat（→ user-cat）
```

生成方式（推荐，`pet.id` 自动算好）：

    python3 scripts/make_theme_pack.py --id ink-scroll --name "墨卷" \
        --seed "#8A5A3C" --mode dark --backdrop texture.png --hero hero.png \
        --font readingFont=book.otf --pet cat.zip --out ink-scroll.zip

## 9. 常见坑

1. `theme.json` 层级不对：套了两层目录、两个 `theme.json`，用户会看到「找不到 theme.json」。
2. 素材引用写成路径（`assets/bg.png`、`./bg.png`）→ schema 拒绝；必须与 `theme.json` 同目录的纯文件名。
3. 拼错字段名（`seed_dark`、`corner_scale`）或放错层级（`layout` 写进 `surfaces`）→ `theme-schema`，没有别名容错。
4. 颜色写成 `#FFF`、`rgb(...)`、`red`；8 位是 AARRGGBB，容易误按 RRGGBBAA 写。
5. 字体名大小写：`jetbrainsmono` 不是内置角色，会被当素材名而以「不是 .ttf/.otf」拒绝。
6. 图片必须完整可解码；截图工具的 APNG、CRC 损坏、尾随数据都会被拒。
7. 文件名大小写/Unicode 形式不一致会找不到素材；`bg.png` 与 `BG.png` 同时存在直接拒绝。
8. 带 `pet` 但 schema 还是 1，或写了 `pet.zip` 忘了 `pet`，都会失败。
9. 不要复用内置 ID（`paper`、`bamboo-celadon`、`terminal-noir`、`sakura-card`、`amber-cafe`）。
10. 投稿工坊要补 `author`/`license`/`source`，`license` 只收 `CC0-1.0`、`CC-BY-4.0`、`CC-BY-SA-4.0`、`MIT`、`Apache-2.0`、`BSD-2-Clause`、`BSD-3-Clause`、`LicenseRef-Author-Permission`。

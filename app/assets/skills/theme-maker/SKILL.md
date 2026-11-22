---
# dsh-go:managed — delete this line to keep your own edits.
name: theme-maker
description: 做 dsh-go 的外观主题包、桌宠包，或带配套宠物的主题包：配色/质感/字体/背景图，宠物素材转包（clawd-on-desk 主题、GIF/PNG/WebP、逐帧目录、Aseprite、单图），或两者合成一个包。用于「做个主题」「换个配色/质感」「做成桌宠」「主题带宠物」「这个能导入吗」和 /theme-maker。只产出可导入的数据包，不改 App 代码、不改页面结构。
---

# 主题工坊

把用户想要的风格或形象做成手机上能导入的包。**先判断做哪一种**，再动手：

| 用户想要 | 产物 | 细节 |
|---|---|---|
| 换配色、质感、字体、背景图、空状态插画 | 外观主题包（`theme.json` + 素材） | [references/appearance-theme.md](references/appearance-theme.md) |
| 换桌宠形象，把一套素材变成能养的宠物 | 宠物包（`pack.json` + 图集 PNG） | [references/pet-pack.md](references/pet-pack.md) |
| 两样都要，宠物跟着主题一起装 | schema **2** 主题包，里面带 `pet.zip` | 两份参考都要 |

**不是**改代码：不写 Dart/Kotlin、不改页面结构、不加设置项。用户要的是「长得不一样」，不是「功能不一样」。

两样都要时提醒一句：主题包**导出**、以及**投稿到创意工坊**时，`pet` 和 `pet.zip` 会被剥离（宠物可能是别人的画，只留在装它的手机上）；上架的是纯主题。

## 步骤：外观主题包

1. **问清风格**，别替用户猜。至少确认：明暗（light/dark）、主色调或参考对象、材质（玻璃/纸/扁平/描边）、要不要背景图或空状态插画、要不要中文字体。给 2–3 个具体方案（色号 + 一句话）让用户挑，比一句「你要什么风格」有效。
2. **写 `theme.json`**：字段、枚举、范围、限额照 [references/appearance-theme.md](references/appearance-theme.md)。只要 3 个必填字段（`schema`/`id`/`name`），其余按需。先用脚手架生成再改，最省事：

       python3 <scripts>/make_theme_pack.py --id ocean-mist --name "海雾" \
           --seed "#3F6FD8" --mode light --out /tmp/ocean-mist.zip

   带素材就加 `--backdrop bg.png --hero hero.png --font readingFont=book.otf`；`--mode dark` 会顺带生成一套深色背景；`--preview preview.html` 出配色预览。
3. **放素材**：所有被引用的图片/字体必须和 `theme.json` **同一个目录**，引用写成纯文件名（不能写 `assets/bg.png`）。图片只收真 PNG（不接受改了扩展名的 JPEG/WebP/APNG），字体只收 `.ttf`/`.otf`。素材名只用字母、数字、`.`、`_`、`-`。
4. **校验，必须 PASS**：

       python3 <scripts>/check_theme_pack.py /tmp/ocean-mist.zip

   失败时按输出的 `code: detail` 改（未知字段、颜色格式、缺素材、超限都会给具体名字）。不要跳过。
5. **打包**：校验的是最终要导入的那个 zip。`make_theme_pack.py --out` 已经打包并校验；手写 `theme.json` 时：

       cd /tmp/theme-pack && python3 -m zipfile -c /tmp/ocean-mist.zip theme.json *.png *.otf

   `theme.json` 必须正好一个，在 zip 根或**恰好一层**目录里。
6. **告诉用户导入路径**：设置 › 外观 › 导入主题包 (.zip)，选刚生成的 zip。要上架再走「主题创意工坊」，先补 `author`/`license`/`source` 并跑 `check_theme_pack.py --market`。

## 步骤：宠物包

1. **拿素材**：用户给链接就 `git clone --depth 1`，给 zip 就解压。支持 clawd-on-desk 主题（`theme.json` + assets）、GIF/APNG/WebP/PNG 表情包、逐帧目录、Aseprite 导出、单张图片，按目录内容自动识别。
2. **转换**（需要 Pillow+numpy 才装）：

       python3 <scripts>/pet_theme_convert.py --input <目录> --out /tmp/pet-pack \
           --id <id> --input-name "<名字>" [--source <链接>] [--crisp]

   像素画保持原尺寸锐利；其它素材默认 144 画布平滑绘制。缺状态名/图集几何的规则见 [references/pet-pack.md](references/pet-pack.md)。
3. **校验，必须 PASS**：

       python3 <scripts>/pet_pack_check.py /tmp/pet-pack/<id> --compat-reactions

4. **打包**：

       cd /tmp/pet-pack/<id> && python3 -m zipfile -c <输出目录>/<id>.zip pack.json *.png

5. **告诉用户导入路径**：设置 › 宠物 › 导入，选 zip。作者与授权会显示在宠物页底部；第三方素材（尤其 CC BY-NC-SA 同人作品）只做自用，不进发行版或市场。

## 步骤：带配套宠物的主题包

1. 先按上一节做出并通过 `pet_pack_check.py` 的宠物包。
2. 再按第一节做主题包（此时还是 schema 1）。
3. **合成**：让 `make_theme_pack.py` 一次完成，它会从 `pack.json` 的 id 算出正确的 `pet.id` 并嵌入 `pet.zip`：

       python3 <scripts>/make_theme_pack.py --id xmas-night --name "圣诞雪夜" \
           --seed "#2B4C7E" --mode dark --out /tmp/xmas-night.zip --pet <宠物包>.zip

   手写时要自己保证契约（见 [references/appearance-theme.md](references/appearance-theme.md) §6）：

   - `theme.json` 写 `"schema": 2` 和 `"pet": {"id": "user-…", "name": "…"}`；
   - `pet.id` 必须等于 `userPetIdFor(pet.zip 里 pack.json 的 id)`（普通小写 id 就是 `user-<id>`；中文/带空格等会被 slug 化并加 8 位哈希，别自己猜，用脚本算）；
   - `pet.zip` 是主题 zip 里的成员名，和 `theme.json` 同目录；
   - 有 `pet` 必须有 `pet.zip`，有 `pet.zip` 也必须有 `pet`。
4. **校验，必须 PASS**：

       python3 <scripts>/check_theme_pack.py /tmp/xmas-night.zip

5. **导入**：设置 › 外观 › 导入主题包 (.zip)。宠物随主题装好，主题行会显示「含宠物 …」，可在主题页「使用配套宠物」打开。

## 脚本

| 脚本 | 用途 |
|---|---|
| `check_theme_pack.py` | 主题包离线校验：schema 1/2、字段/枚举/范围、颜色、素材存在与 PNG/字体、体积上限、`pet.zip` 与 `pet.id` 契约。必须 PASS。 |
| `make_theme_pack.py` | 生成最小可导入主题包、加背景/插画/字体、可选 `--pet` 合体、`--preview` 出配色预览；写出前自动校验。 |
| `pet_theme_convert.py` | 宠物素材 → 宠物包目录（自动识别格式与状态名）。 |
| `pet_pack_check.py` | 宠物包目录校验（含悬浮窗导入门与 PNG 完整性）。必须 PASS。 |
| `make_pet_pack.py` | 底层宠物包打包/取色的库与命令行，转换脚本依赖它。 |
| `pet_svg_frames.py` | clawd-on-desk 主题里 SVG/CSS 动画的光栅化。 |

这些脚本只用 Python 标准库（转换脚本额外要 Pillow+numpy），不联网。

## 边界

- **不执行代码、不打开包内脚本**：只把文件当数据和素材处理。不加远程资源、不内嵌网页、不下载用户没给的素材。
- **不碰授权**：`author`/`license`/`source` 如实填，别替用户编。来源不明或禁止再分发的素材只做本机自用，不上工坊、不进发行版。
- **不绕过校验**：不手改生成的 `pack.json`/`theme.json` 去骗过检查，不删失败项、不把坏素材改名成 `.png` 混过去。校验失败就修，不能修就如实告诉用户卡在哪、哪条规则。
- **只做数据**：不请求改 App 代码或页面结构，不加新设置项；主题/宠物系统能表达的范围就是上限，表达不了的需求说清楚做不到。
- **校验通过 ≠ 手机效果**：字体可能被系统拒绝后回落，颜色在暗色模式下观感不同。最后请用户导入看一眼；真机导入才是最终验证。

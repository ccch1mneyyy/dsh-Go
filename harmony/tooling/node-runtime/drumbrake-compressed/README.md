# Node 24.2.0 鸿蒙 DrumBrake 压缩配置重放材料

本目录对应未剥离运行库SHA256 `b2c73a809530bb0e83b1b87797063da65c10a11c49dedd488698a6bb83ed4cb5`。它替代上层目录中历史lazy-Undici基线的构建说明；不能叠加旧Undici或启动诊断补丁。

## 来源与实际核验

固定官方Node commit为`591ba692bfe30408e6a67397e7d18bfa1b9c3561`（v24.2.0）。`node-v24.2.0-ohos.patch`来自成功构建后2026-11-01 14:02保存的完整tracked源码diff，SHA256 `55b4de6dae5f48fe2f1c2b9e82f9201223ccbcb1a478b501df108902b99c7273`，涉及10个文件。

本轮没有把Windows同名旧源码树当成成功来源。实际成功源码保存在ext4构建镜像；使用只读debugfs提取10个补丁目标和config，并同官方commit的git archive重新应用结果逐文件比较。10个文件内容全部相符；实际镜像中libuv linux.c是CRLF，其他9个是LF，仓库重放统一使用LF，清单同时保留原镜像原始摘要及规范化摘要。没有将仅行尾不同夸大为语义改动。

另独立核对8个原版关键文件：`src/node.cc`、`src/node_main.cc`、`src/node_errors.cc`、`src/api/environment.cc`、`deps/undici/undici.js`、`Makefile`、`common.gypi`、`node.gyp`。其实际镜像内容与官方commit完全相符（统一LF比较），表明这些启动/异常/Undici路径没有旧诊断handler或fetch替代。记录见`unchanged-source-check.json`。并未宣称对镜像内每个未改文件重新独立逐字节审计；完整变更范围还依赖当时保存的tracked git diff。

补丁内容包括：鸿蒙共享库SONAME与gyp链接规则、关闭可选io_uring、启用DrumBrake构建目标、匹配同版本Wasm类型API/字段布局、引用位判断、根块类型编码、ARM64大立即数通过`Cmp`正确物化。保留原断言/BRK及bounds checks，不通过删除错误处理掩盖故障。

## 固定工具与输入

- OpenHarmony官方Linux LLVM19日构建20261030_061421及其sysroot（下载地址与摘要见上层NATIVE-RUNTIME-BUILD.md；不要混用Windows CLT库）；需要包含`aarch64-unknown-linux-ohos-clang[++]`目标包装器的完整LLVM目录。
- 已用Python3.13、Linux host Clang、GNU make和host libatomic。若该Linux LLVM依赖额外兼容库，由调用环境正确安装或设置`LD_LIBRARY_PATH`，本脚本不下载、不改系统库。
- WSL可用，但正式长构建建议Linux/ext4源码工作区，避免9p构建慢与生成文件问题。磁盘镜像/工作区放用户指定D盘；本脚本不创建/挂载镜像。
- `config-template.json`保存成功候选的完整配置结构，仅把安装前缀替换为`${INSTALL_PREFIX}`，不含本机绝对路径。原始配置SHA为`94ed1adbbaad899930b13555bc754dd73a166a663a8d7af5e64359b764f4dfe3`。

## 从干净官方源码准备

下面在Linux/WSL运行；SOURCE、LLVM、PYTHON、OUTPUT、RECIPE由调用者设为实际路径。必须使用干净官方检出，禁用自动CRLF转换，不能复用未知改动树。

```bash
git -c core.autocrlf=false clone https://github.com/nodejs/node.git "$SOURCE"
git -C "$SOURCE" checkout 591ba692bfe30408e6a67397e7d18bfa1b9c3561
python3 "$RECIPE/prepare.py" --source "$SOURCE" --check
bash "$RECIPE/replay.sh" "$SOURCE" "$LLVM" "$PYTHON" "$OUTPUT" configure
```

`prepare.py`核补丁摘要及10个官方前/后摘要、8个原版关键文件，执行`git apply --check`后才应用；混合或未知源码立即失败。已完整应用时允许幂等。使用官方commit的git archive也可以，但来源由调用者核验，本脚本不以某个目录名证明其余未列文件可信。

`replay.sh`默认需明确选择`configure`或`build`。配置使用原成功命令：

```text
--dest-cpu=arm64 --dest-os=openharmony --cross-compiling
--openssl-no-asm --shared --experimental-enable-pointer-compression
-Dv8_enable_drumbrake=1 --prefix=<独立output/install>
```

CC/CXX使用目标包装器加`-fno-emulated-tls`，host CC/CXX使用同套LLVM Clang，CFLAGS/CXXFLAGS为`-DNDEBUG -Wno-error=implicit-function-declaration`。`verify-config.py`比较完整配置结构，仅忽略安装前缀；发现其他差异立即停止，不能悄悄换ABI。

js2c的实际依赖清单由生成的`out/libnode.target.mk`提取，只将其JS/MJS输入规范为LF。不能省略检查：此前CRLF字节长度与C++ raw literal不一致会导致启动异常。

## 长构建（本轮没有执行）

确认没有其他make使用同一源码目录后才运行：

```bash
MAKE_JOBS=4 bash "$RECIPE/replay.sh" "$SOURCE" "$LLVM" "$PYTHON" "$OUTPUT" build
```

该命令会重新配置并校验，然后只调用一个make；host链接固定`-Wl,--no-as-needed -latomic -Wl,--as-needed`，不修改target链接。产物位于OUTPUT/install/lib/libnode.so，并检查AArch64与SONAME libnode.so；随后须核依赖仅预期C++/libc，重编匹配ABI桥并真机验证。脚本不会安装App或启动设备。

## 本轮完成与剩余边界

已完成干净官方archive上的patch dry-run、实际应用、10文件与真实镜像比对、原版关键文件核对，以及使用实际Linux工具链的完整configure重放。生成配置与成功候选完整结构一致，仅安装前缀不同；js2c依赖检查通过（干净LF源码无需改写）。未执行新一轮长make，因此不宣称已证明干净全编后二进制SHA可复现；debug路径、工具环境和构建时间也可能影响未剥离二进制摘要。

现有B2C产物的真机结果由主验收证据维护，包括Wasm42/原fetch以及上层工具权限测试。它们不意味着所有Wasm提案/共享引用类型均已穷尽验证。发布PR前仍应完成干净长构建、测试入口清理和正常UI最终验收。

许可：保留官方完整`NODE-LICENSE`以及相关`V8-LICENSE`、`LIBUV-LICENSE`，补丁中保留原源码版权上下文。Node其他捆绑组件许可包含在官方完整LICENSE中；重分发运行库仍需按对应条款随包保留通知。

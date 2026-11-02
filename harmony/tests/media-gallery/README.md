# 原图片保存通道的鸿蒙后端

`DshMediaPlugin.ets` 实现原 `dsh/media.saveImage`，通过系统 `showAssetsCreationDialog` 取得单次图库写入目标，不申请广泛图库读写权限。只有用户同意、实际复制及目标字节数核对成功后返回目标 URI；取消、错误 URI、短写与复制失败不返回成功。

临时图片放在 SDK 创建的唯一私有缓存目录，完成后关闭句柄并清理该文件和空目录。原 PNG/JPEG/GIF/WebP 类型入口保持不变，格式与设备支持性仍以系统实际返回为准。

SDK 依据：[PhotoAccessHelper](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-photoaccesshelper)；已核对 API 26 的实际接口声明。

```powershell
node harmony/tests/media-gallery/native.test.cjs D:/工具链/typescript
```

7 项测试直接转译原 ArkTS 源，覆盖真实目标写入的控制流程、取消、错误目标、短写、复制失败、类型拒绝、并发及临时资源清理。系统文件和图库服务使用内存替身，不能替代实际图库写入。正常包 135 已编译、签名并覆盖安装；该阶段尚待真机验证的系统保存与图库可见性，后续结果见下节。

## 2026-11-02 真机保存与取消

临时普通 UIAbility 直接调用同一生产 DshMediaPlugin 和真实 MethodCall，仅使用固定合成 DSH TEST PNG，不初始化账号、引擎或 Flutter。首次测试在弹窗前失败且未保存；核官方文件 API 后发现 mkdtemp 路径必须以 XXXXXX 结尾，已对替身加入该契约先红后绿，生产仅补齐模板后缀。依据：[OpenHarmony fileIo.mkdtemp](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-core-file-kit/js-apis-file-fs.md#fileiomkdtemp)。

构建 145 的实际系统弹窗点击允许后，生产保存操作返回授权 URI，已通过原生产写入长度核对，临时缓存数量恢复；随后第二次弹窗选择禁止，原 permission 取消结果、未保存和缓存恢复全部通过。URI 仅留内存，不保存或枚举用户图库。

授权目标的 READ_ONLY 完整字节读回仍为 unavailable，具体原因未确证，完整字节核验仍为 false；不能将保存操作成功写成完整读回已过，也没有追加广泛图库读取权限。首次失败版本的一次性门保留，确认未保存后仅使用新版本验收门，不删除 guard 或重复创建测试图片。

## 2026-11-02 用户确认图库可见性

用户完成图库查看后回复“能看到测试图片”，固定合成 DSH TEST 图片的实际图库可见性记为通过，证据来源是用户操作报告。该结果补充145的系统授权保存、写入长度核对、取消与缓存清理证据，没有为确认可见性再次创建图片或枚举用户图库。

目视可见不等于授权 URI 完整字节读回；该读回仍为 unavailable。此处也不据独立生产桥夹具通过，宣称所有原 Flutter 保存入口、图片格式或设备均已验收。

# 原图片保存通道的鸿蒙后端

`DshMediaPlugin.ets` 实现原 `dsh/media.saveImage`，通过系统 `showAssetsCreationDialog` 取得单次图库写入目标，不申请广泛图库读写权限。只有用户同意、实际复制及目标字节数核对成功后返回目标 URI；取消、错误 URI、短写与复制失败不返回成功。

临时图片放在 SDK 创建的唯一私有缓存目录，完成后关闭句柄并清理该文件和空目录。原 PNG/JPEG/GIF/WebP 类型入口保持不变，格式与设备支持性仍以系统实际返回为准。

SDK 依据：[PhotoAccessHelper](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-photoaccesshelper)；已核对 API 26 的实际接口声明。

```powershell
node harmony/tests/media-gallery/native.test.cjs D:/工具链/typescript
```

7 项测试直接转译原 ArkTS 源，覆盖真实目标写入的控制流程、取消、错误目标、短写、复制失败、类型拒绝、并发及临时资源清理。系统文件和图库服务使用内存替身，不能替代实际图库写入。正常包 135 已编译、签名并覆盖安装；系统保存弹窗、实际相册出现和取消体验待用户真机试用。

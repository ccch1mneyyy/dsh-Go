# 鸿蒙桌面图标通道测试

使用本机已安装的Node.js和TypeScript编译器转译实际DshLauncherIconPlugin.ets，BundleManager采用固定替身，不访问设备、不改真实桌面图标。

```powershell
node .\harmony\tests\launcher-icons\native.test.cjs 'D:\开发工具\TypeScript模块目录'
```

若已在Node模块查找路径安装TypeScript，可省略第二个参数；不需要为本测试联网安装任何包。本机验证使用官方Windows CLT附带的TypeScript。

覆盖真实state/set契约、三种备用样式、恢复默认、重复默认不撤销、无效参数、系统查询或设置失败、设置后未生效不得成功、未知/多重启用状态、异步完成和detach；另核对app.json5配置及四份资源与安卓原PNG字节一致。

这是固定夹具与配置校验，不代替ArkTS编译或API26真机桌面切换验收。

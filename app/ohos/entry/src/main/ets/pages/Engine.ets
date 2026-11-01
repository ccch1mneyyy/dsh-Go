// 引擎 Ability 的占位页面：加载后窗口立即隐藏，仅用于让 Ability 保持存活。
@Entry
@Component
struct Engine {
  build() {
    Column() {
    }
    .width('100%')
    .height('100%')
  }
}

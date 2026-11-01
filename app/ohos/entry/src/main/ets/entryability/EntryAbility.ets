
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import DshSecureStoragePlugin from '../plugins/DshSecureStoragePlugin';
import DshLauncherIconPlugin from '../plugins/DshLauncherIconPlugin';
import DshRuntimePlugin from '../plugins/DshRuntimePlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    // super 必须先执行：Flutter 引擎的平台通道（含输入法文本通道）在这里建立。
    super.configureFlutterEngine(flutterEngine)
    AppStorage.setOrCreate<common.UIAbilityContext>('uiAbilityContext', this.context);
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new DshSecureStoragePlugin());
    flutterEngine.getPlugins()?.add(new DshLauncherIconPlugin());
    flutterEngine.getPlugins()?.add(new DshRuntimePlugin());
  }
}


import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import DshSecureStoragePlugin from '../plugins/DshSecureStoragePlugin';
import DshLauncherIconPlugin from '../plugins/DshLauncherIconPlugin';
import DshRuntimePlugin from '../plugins/DshRuntimePlugin';
import DshVoicePlugin from '../plugins/DshVoicePlugin';
import DshAppPlugin from '../plugins/DshAppPlugin';
import DshMediaPlugin from '../plugins/DshMediaPlugin';

export default class EntryAbility extends FlutterAbility {
  private voicePlugin: DshVoicePlugin = new DshVoicePlugin();

  onBackground(): void {
    void this.voicePlugin.cancelCurrent();
    super.onBackground();
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    // super 必须先执行：Flutter 引擎的平台通道（含输入法文本通道）在这里建立。
    super.configureFlutterEngine(flutterEngine)
    AppStorage.setOrCreate<common.UIAbilityContext>('uiAbilityContext', this.context);
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new DshSecureStoragePlugin());
    flutterEngine.getPlugins()?.add(new DshLauncherIconPlugin());
    flutterEngine.getPlugins()?.add(new DshRuntimePlugin());
    flutterEngine.getPlugins()?.add(this.voicePlugin);
    flutterEngine.getPlugins()?.add(new DshAppPlugin());
    flutterEngine.getPlugins()?.add(new DshMediaPlugin());
  }
}

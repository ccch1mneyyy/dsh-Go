
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import DshSecureStoragePlugin from '../plugins/DshSecureStoragePlugin';
import DshLauncherIconPlugin from '../plugins/DshLauncherIconPlugin';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new DshSecureStoragePlugin());
    flutterEngine.getPlugins()?.add(new DshLauncherIconPlugin());
  }
}

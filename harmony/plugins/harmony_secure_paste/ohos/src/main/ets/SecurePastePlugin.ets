import common from '@ohos.app.ability.common';
import inputMethod from '@ohos.inputMethod';
import window from '@ohos.window';
import { ComponentContent } from '@ohos.arkui.node';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import AbilityAware from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityAware';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import MethodChannel, { MethodCallHandler, MethodResult } from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodChannel';
import MethodCall from '@ohos/flutter_ohos/src/main/ets/plugin/common/MethodCall';

class SecurePasteSession {
  private result: MethodResult;
  private finished: boolean = false;
  private reading: boolean = false;

  constructor(result: MethodResult) {
    this.result = result;
  }

  isFinished(): boolean {
    return this.finished;
  }

  cancel(): void {
    this.finish(null);
  }

  private finish(text: string | null): void {
    if (this.finished) return;
    this.finished = true;
    this.result.success(text);
  }

  async paste(result: PasteButtonOnClickResult): Promise<boolean> {
    if (this.finished || this.reading || result !== PasteButtonOnClickResult.SUCCESS) return false;
    this.reading = true;
    console.info('[secure-paste] read stage=1');
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      console.info('[secure-paste] read code=0');
      if (!this.finished && data.hasType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        const text = data.getPrimaryText();
        if (text.length > 0) {
          this.finish(text);
          console.info('[secure-paste] send stage=1');
          return true;
        }
      }
    } catch (error) {
      const code = (error as BusinessError).code;
      console.info(`[secure-paste] read code=${typeof code === 'number' ? code : -1}`);
    } finally {
      this.reading = false;
    }
    return false;
  }
}

@Component
struct SecurePasteDialog {
  close: () => void = () => {};
  session: SecurePasteSession | null = null;
  @State status: string = '';

  build() {
    Column({ space: 20 }) {
      Text('粘贴到输入框').fontSize(20)
      Text('请点击系统粘贴按钮确认本次粘贴。').fontSize(16)
      PasteButton()
        .padding({ top: 12, bottom: 12, left: 24, right: 24 })
        .onClick((_event: ClickEvent, result: PasteButtonOnClickResult, error?: BusinessError<void>) => {
          console.info(`[secure-paste] click result=${result} code=${error?.code ?? 0}`);
          if (result !== PasteButtonOnClickResult.SUCCESS) {
            this.status = '系统未允许此次粘贴，请重试或取消。';
            return;
          }
          const session = this.session;
          if (session === null) return;
          session.paste(result).then((sent: boolean) => {
            if (sent) {
              this.close();
            } else {
              this.status = '没有可粘贴的文本，或此次操作已取消。';
            }
          });
        })
      if (this.status.length > 0) {
        Text(this.status).fontSize(14)
      }
      Button('取消').onClick(() => {
        this.session?.cancel();
        this.close();
      })
    }.padding(24).width(320).backgroundColor(Color.White).borderRadius(20)
  }
}

class SecurePasteDialogParams {
  session: SecurePasteSession;
  close: () => void;

  constructor(session: SecurePasteSession, close: () => void) {
    this.session = session;
    this.close = close;
  }
}

@Builder
function buildSecurePasteDialog(params: SecurePasteDialogParams) {
  SecurePasteDialog({ session: params.session, close: params.close })
}

export default class SecurePastePlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private session: SecurePasteSession | null = null;
  private closeDialog: (() => void) | null = null;

  getUniqueClassName(): string {
    return 'SecurePastePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/secure_paste');
    this.channel.setMethodCallHandler(this);
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    console.info(`[secure-paste] request context=${this.context === null ? 0 : 1}`);
    if (call.method !== 'requestPaste') {
      result.notImplemented();
      return;
    }
    this.showConfirmation(result);
  }

  private async showConfirmation(result: MethodResult): Promise<void> {
    const context = this.context;
    if (context === null || (this.session !== null && !this.session.isFinished())) {
      result.success(null);
      return;
    }
    const session = this.session = new SecurePasteSession(result);
    try {
      try {
        await inputMethod.getController().hideTextInput();
      } catch (error) {
        const code = (error as BusinessError).code;
        console.info(`[secure-paste] keyboard code=${typeof code === 'number' ? code : -1}`);
      }
      const mainWindow = await window.getLastWindow(context);
      if (session.isFinished() || this.context !== context) return;
      const uiContext = mainWindow.getUIContext();
      const prompt = uiContext.getPromptAction();
      let content: ComponentContent<SecurePasteDialogParams> | null = null;
      const close = (): void => {
        if (content !== null) {
          prompt.closeCustomDialog(content).catch(() => {});
        }
      };
      content = new ComponentContent(uiContext, wrapBuilder(buildSecurePasteDialog),
        new SecurePasteDialogParams(session, close));
      this.closeDialog = close;
      await prompt.openCustomDialog(content, {
        autoCancel: true,
        alignment: DialogAlignment.Center,
        onDidDisappear: () => session.cancel()
      });
      console.info('[secure-paste] dialog stage=1');
    } catch (error) {
      const code = (error as BusinessError).code;
      console.info(`[secure-paste] dialog code=${typeof code === 'number' ? code : -1}`);
      session.cancel();
    }
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.context = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.session?.cancel();
    this.closeDialog?.();
    this.closeDialog = null;
    this.context = null;
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.onDetachedFromAbility();
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }
}

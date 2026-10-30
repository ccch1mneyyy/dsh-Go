import { DshClient } from '../network/DshClient';
import { SessionSummary, ChatMessage, FollowUpdate } from '../network/protocol';

@Entry
@Component
struct Index {
  @State private screen: string = 'connect';
  @State private host: string = '';
  @State private token: string = '';
  @State private directory: string = '';
  @State private input: string = '';
  @State private status: string = '连接你的 DSH 主机';
  @State private error: string = '';
  @State private busy: boolean = false;
  @State private connected: boolean = false;
  @State private synchronized: boolean = false;
  @State private running: boolean = false;
  @State private title: string = '对话';
  @State private sessions: SessionSummary[] = [];
  @State private messages: ChatMessage[] = [];
  private client: DshClient = new DshClient();
  private sessionId: string = '';
  private connectionGeneration: number = 0;
  private viewGeneration: number = 0;
  private messageScroller: Scroller = new Scroller();

  aboutToDisappear(): void {
    this.connectionGeneration++;
    this.viewGeneration++;
    this.client.close();
  }

  onBackPress(): boolean {
    if (this.screen === 'chat') {
      this.backToSessions();
      return true;
    }
    if (this.screen === 'sessions') {
      this.disconnect();
      return true;
    }
    return false;
  }

  private explain(error: Error): string {
    return error.message || '暂时无法完成，请检查主机连接后重试';
  }

  private async connect(): Promise<void> {
    if (this.busy) return;
    const generation = ++this.connectionGeneration;
    this.busy = true;
    this.error = '';
    this.status = '正在连接主机…';
    this.client.close();
    this.client = new DshClient();
    this.client.onDisconnect = (message: string): void => {
      if (generation !== this.connectionGeneration) return;
      this.connected = false;
      this.synchronized = false;
      this.error = message;
      this.status = '连接已断开，主机任务可能仍在运行';
    };
    try {
      await this.client.connect(this.host, this.token);
      if (generation !== this.connectionGeneration) return;
      this.connected = true;
      this.token = '';
      this.sessions = await this.client.listSessions();
      if (generation !== this.connectionGeneration) return;
      this.screen = 'sessions';
      this.status = '已连接';
    } catch (error) {
      if (generation !== this.connectionGeneration) return;
      this.error = this.explain(error as Error);
      this.status = '连接未完成';
      this.connected = false;
      this.client.close();
    } finally {
      if (generation === this.connectionGeneration) this.busy = false;
    }
  }

  private async refresh(): Promise<void> {
    if (!this.connected || this.busy) return;
    const generation = this.connectionGeneration;
    this.busy = true;
    this.error = '';
    try {
      const sessions = await this.client.listSessions();
      if (generation === this.connectionGeneration && this.connected) this.sessions = sessions;
    } catch (error) {
      if (generation === this.connectionGeneration) this.error = this.explain(error as Error);
    } finally {
      if (generation === this.connectionGeneration) this.busy = false;
    }
  }

  private async openSession(id: string, title: string): Promise<void> {
    if (!this.connected || this.busy) return;
    const generation = ++this.viewGeneration;
    this.screen = 'chat';
    this.sessionId = id;
    this.title = title;
    this.messages = [];
    this.error = '';
    this.input = '';
    this.running = false;
    this.synchronized = false;
    this.busy = true;
    this.status = '正在同步会话…';
    try {
      await this.client.watchSession(id, (update: FollowUpdate): void => {
        if (generation !== this.viewGeneration || !this.connected) return;
        this.messages = update.messages;
        this.running = update.running;
        this.synchronized = true;
        this.status = update.status;
      });
    } catch (error) {
      if (generation === this.viewGeneration) this.error = this.explain(error as Error);
    } finally {
      if (generation === this.viewGeneration) this.busy = false;
    }
  }

  private async createSession(): Promise<void> {
    if (!this.connected || this.busy) return;
    this.busy = true;
    this.error = '';
    const generation = this.connectionGeneration;
    try {
      const id = await this.client.createSession(this.directory.trim());
      if (generation !== this.connectionGeneration || !this.connected) return;
      this.busy = false;
      await this.openSession(id, '新对话');
    } catch (error) {
      if (generation === this.connectionGeneration) this.error = this.explain(error as Error);
    } finally {
      if (generation === this.connectionGeneration) this.busy = false;
    }
  }

  private async send(): Promise<void> {
    if (!this.connected || !this.synchronized || this.busy || !this.input.trim()) return;
    const text = this.input;
    const generation = this.viewGeneration;
    this.busy = true;
    this.error = '';
    try {
      await this.client.sendPrompt(this.sessionId, text);
      if (generation === this.viewGeneration) this.input = '';
    } catch (error) {
      if (generation === this.viewGeneration) this.error = this.explain(error as Error);
    } finally {
      if (generation === this.viewGeneration) this.busy = false;
    }
  }

  private async stop(): Promise<void> {
    if (!this.connected || !this.synchronized || !this.running || this.busy) return;
    const generation = this.viewGeneration;
    this.busy = true;
    this.error = '';
    try {
      await this.client.cancelSession(this.sessionId);
      if (generation === this.viewGeneration) this.status = '已请求停止，正在等待主机确认';
    } catch (error) {
      if (generation === this.viewGeneration) this.error = this.explain(error as Error);
    } finally {
      if (generation === this.viewGeneration) this.busy = false;
    }
  }

  private backToSessions(): void {
    this.viewGeneration++;
    this.busy = false;
    this.screen = 'sessions';
    this.synchronized = false;
    this.refresh();
  }

  private disconnect(): void {
    this.connectionGeneration++;
    this.viewGeneration++;
    this.client.close();
    this.connected = false;
    this.synchronized = false;
    this.busy = false;
    this.sessions = [];
    this.messages = [];
    this.screen = 'connect';
    this.status = '连接你的 DSH 主机';
    this.error = '';
  }

  @Builder
  private header() {
    Row({ space: 12 }) {
      if (this.screen === 'chat') {
        Button('返回').fontSize(14).fontColor('#426BA4').backgroundColor('#E8F0FC')
          .onClick(() => this.backToSessions())
      } else {
        Text('DSH').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#426BA4')
      }
      Column({ space: 3 }) {
        Text(this.screen === 'chat' ? this.title : 'DSH Go').fontSize(20).fontWeight(FontWeight.Medium)
          .fontColor('#202C3E').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.screen === 'connect' ? '鸿蒙远程预览版' : this.status).fontSize(12).fontColor('#65748B')
          .maxLines(2)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.connected) {
        Button('断开').fontSize(13).fontColor('#65748B').backgroundColor(Color.Transparent)
          .onClick(() => this.disconnect())
      }
    }.width('100%').padding({ left: 20, right: 16, top: 18, bottom: 18 })
      .backgroundColor('#FFFFFF')
  }

  @Builder
  private errorNotice() {
    if (this.error.length > 0) {
      Column({ space: 8 }) {
        Text(this.error).fontSize(14).fontColor('#8C3B2C').width('100%')
        if (!this.connected && this.screen !== 'connect') {
          Text('断线不会停止电脑上的任务。重新登录后可继续查看。').fontSize(12).fontColor('#65748B')
          Button('重新连接').onClick(() => { this.screen = 'connect'; this.busy = false; })
        }
      }.alignItems(HorizontalAlign.Start).width('100%').padding(16).backgroundColor('#FFF1EC')
    }
  }

  @Builder
  private connectPage() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 12 }) {
          Text('把电脑上的工作，\n带到手边。').fontSize(30).fontWeight(FontWeight.Medium).fontColor('#202C3E')
            .width('100%')
          Text('连接已启动的 DSH 主机，查看会话、发送消息并接收实时回复。').fontSize(15)
            .fontColor('#65748B').lineHeight(24).width('100%')
        }.padding({ top: 24, bottom: 12 }).alignItems(HorizontalAlign.Start)
        Column({ space: 10 }) {
          Text('主机地址').fontSize(14).fontWeight(FontWeight.Medium).width('100%')
          TextInput({ placeholder: 'https://你的主机地址', text: this.host })
            .onChange((value: string) => { this.host = value; })
            .enabled(!this.busy).height(52).backgroundColor('#EEF2F8').borderRadius(14)
          Text('输入手机能访问的 DSH 地址。USB 转发测试时使用本机回环地址。')
            .fontSize(12).fontColor('#65748B').width('100%').lineHeight(19)
          Text('启动令牌').fontSize(14).fontWeight(FontWeight.Medium).width('100%').margin({ top: 10 })
          TextInput({ placeholder: '粘贴 dsh web 启动时给出的 token', text: this.token })
            .type(InputType.Password).showPasswordIcon(true).onChange((value: string) => { this.token = value; })
            .enabled(!this.busy).height(52).backgroundColor('#EEF2F8').borderRadius(14)
          Text('令牌与登录凭据仅保留在本次运行内存中，不写入日志。')
            .fontSize(12).fontColor('#65748B').width('100%').lineHeight(19)
          Button(this.busy ? '正在连接…' : '连接主机').width('100%').height(50)
            .backgroundColor('#426BA4').fontColor(Color.White).borderRadius(15)
            .enabled(!this.busy && this.host.trim().length > 0 && this.token.trim().length > 0)
            .onClick(() => this.connect()).margin({ top: 14 })
        }.padding(20).borderRadius(22).backgroundColor(Color.White)
        Text('首版支持 DSH HTTP(S) 直连；主机上的模型和任务设置继续沿用电脑端。')
          .fontSize(13).fontColor('#65748B').lineHeight(21).width('100%')
      }.padding(22).width('100%').alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).width('100%')
  }

  @Builder
  private sessionsPage() {
    Column({ space: 14 }) {
      Row() {
        Text('你的对话').fontSize(23).fontWeight(FontWeight.Medium).fontColor('#202C3E').layoutWeight(1)
        Button(this.busy ? '同步中…' : '刷新').fontColor('#426BA4').backgroundColor('#E8F0FC')
          .enabled(this.connected && !this.busy).onClick(() => this.refresh())
      }.width('100%')
      TextInput({ placeholder: '新会话目录（可选，使用主机上的路径）', text: this.directory })
        .onChange((value: string) => { this.directory = value; }).enabled(this.connected && !this.busy)
        .height(48).backgroundColor(Color.White).borderRadius(12)
      Button('＋ 新对话').width('100%').height(48).backgroundColor('#426BA4').fontColor(Color.White)
        .enabled(this.connected && !this.busy).onClick(() => this.createSession())
      if (this.sessions.length === 0) {
        Column({ space: 12 }) {
          Text('这里还没有对话').fontSize(20).fontColor('#202C3E')
          Text('点“新对话”，从一个具体任务开始。').fontSize(14).fontColor('#65748B')
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.sessions, (session: SessionSummary) => {
            ListItem() {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(session.title || '未命名对话').fontSize(16).fontWeight(FontWeight.Medium)
                    .fontColor('#202C3E').layoutWeight(1).maxLines(2)
                  if (session.running) {
                    Text('运行中').fontSize(12).fontColor('#426BA4').backgroundColor('#E8F0FC')
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(8)
                  }
                }.width('100%')
                Text(session.cwd || '主机默认目录').fontSize(12).fontColor('#65748B')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
              }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(16)
                .onClick(() => this.openSession(session.sessionId, session.title || '对话'))
            }
          }, (session: SessionSummary): string => session.sessionId)
        }.layoutWeight(1).width('100%')
      }
    }.padding(20).width('100%').layoutWeight(1)
  }

  @Builder
  private chatPage() {
    Column() {
      if (this.messages.length === 0) {
        Column({ space: 12 }) {
          Text(this.synchronized ? '今天想完成什么？' : '正在读取会话…').fontSize(23).fontColor('#202C3E')
          Text(this.synchronized ? '消息会发送到你的 DSH 主机。' : '等待主机返回真实记录。')
            .fontSize(14).fontColor('#65748B')
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 16, scroller: this.messageScroller }) {
          ForEach(this.messages, (message: ChatMessage) => {
            ListItem() {
              Column({ space: 7 }) {
                Text(message.role === 'user' ? '你' : (message.streaming ? 'DSH · 正在回复' : 'DSH'))
                  .fontSize(12).fontColor('#65748B').width('100%')
                Text(message.text).fontSize(16).lineHeight(25).fontColor('#202C3E')
                  .copyOption(CopyOptions.LocalDevice).width('100%')
              }.alignItems(HorizontalAlign.Start).padding(16).width('100%').borderRadius(16)
                .backgroundColor(message.role === 'user' ? '#E8F0FC' : '#FFFFFF')
            }
          }, (message: ChatMessage): string => message.id)
        }.padding(18).width('100%').layoutWeight(1)
      }
      Column({ space: 10 }) {
        if (this.running) {
          Row() {
            Text('主机正在处理任务').fontSize(13).fontColor('#65748B').layoutWeight(1)
            Button('停止任务').fontSize(13).fontColor('#A24535').backgroundColor('#FFF1EC')
              .enabled(this.connected && this.synchronized && !this.busy).onClick(() => this.stop())
          }.width('100%')
        }
        Row({ space: 10 }) {
          TextArea({ placeholder: this.connected ? '发消息给 DSH…' : '连接断开，请重新登录', text: this.input })
            .onChange((value: string) => { this.input = value; }).height(82).layoutWeight(1)
            .enabled(this.connected && this.synchronized).backgroundColor('#EEF2F8').borderRadius(16)
          Button(this.busy ? '…' : '发送').height(48).backgroundColor('#426BA4').fontColor(Color.White)
            .enabled(this.connected && this.synchronized && !this.busy && this.input.trim().length > 0)
            .onClick(() => this.send())
        }.width('100%')
      }.padding(16).width('100%').backgroundColor(Color.White)
    }.width('100%').layoutWeight(1)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.header()
        this.errorNotice()
        if (this.screen === 'connect') {
          this.connectPage()
        } else if (this.screen === 'sessions') {
          this.sessionsPage()
        } else {
          this.chatPage()
        }
      }.width('100%').constraintSize({ maxWidth: 960 }).height('100%')
    }.width('100%').height('100%').backgroundColor('#F5F7FB')
  }
}

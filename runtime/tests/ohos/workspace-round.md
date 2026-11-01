# O4 工作区快照：真实 App 回合验收夹具

本文件与 `workspace-round-fixture.mjs` 只用于测试，不进入移动 profile 或产品装配。它复用已冻结 O0b 的 `round.mjs` 和假模型，不改变 write/edit/read/grep/bash 的五步请求。

fixture 只接受显式 `confirmEmptyTestWorkspace: true`，而且要求引擎启动 cwd 是新空目录。它用已批准且锁定的 isomorphic-git 1.44.9 初始化测试仓库，写入三个被跟踪的初始文件和一个被忽略的文件。第一个工具结果出现后，测试夹具直接修改“仅快照可见.txt”；这个写入没有经过 DSH 的 fs/write-intent，故只靠文件工具的退化记录无法发现它。

固定 DSH 的 `agent/turn-stopping` 通过串行 dispatch 逐个等待回调。fixture 注入 workspaceChanges 后才注册自己的回调，因此原插件的回合结束快照先完成。随后测试要求：

* summary 有不同的 before/after Git tree ID；
* 中文模型文件和夹具的外部改动都在摘要里；被忽略及未改动文件不在；
* 外部改动的生产 diff 包含 before/after 文本；
* 原 `.git` 内每个文件的内容摘要和文件集合不变，覆盖用户 index、objects、refs；
* 再经过真实 token→Cookie 认证，调用客户端现有 `/api/changes.summary` 与 `/api/changes.diff`，返回内容与生产服务相同。

断言发生在原回合的停止钩子中；失败会使未修改的 O0b 驱动器把本轮记为 BLOCKED。报告在回合结束前写完，没有靠 sleep 或终止后抢读内存记录。一个新工作区只跑一轮，输出报告必须不存在。

## 运行

需要原 O0b，固定 DSH prefix，以及 O4 的固定 isomorphic-git 安装目录；fixture 按相对位置从 `runtime/ohos/process/package.json` 解析依赖。报告路径在工作区之外。

生成一个 JSON（同时也是有效 YAML）overlay：

```json
[
  {
    "insert": [
      {
        "id": "ohos-workspace-test-fixture",
        "name": "file:///absolute/repository/runtime/tests/ohos/workspace-round-fixture.mjs",
        "config": {
          "confirmEmptyTestWorkspace": true,
          "output": "/absolute/new-workspace-summary.json"
        }
      }
    ]
  }
]
```

先校准未替换的 JIT / native git 路径：

```sh
node runtime/ohos/sim/round.mjs --prefix /absolute/prefix --out /absolute/new-jit-case \
  --mode jit --patch /absolute/workspace-fixture.patch.yml
```

再叠加移动 profile、网络和严格 O0：

```sh
node runtime/ohos/sim/round.mjs --prefix /absolute/prefix --out /absolute/new-sim-case \
  --mode sim --platform --expose-internals --import runtime/ohos/net/preload.mjs \
  --patch /absolute/mobile.patch.yml --patch /absolute/workspace-fixture.patch.yml
```

上述 `--expose-internals` 只复用现有实验加载器以隔离 O4；按 ADDENDUM 追加2，它不能进入产品，本夹具不实现或批准其替代。两个样本必须用不同的 case 和报告路径。父驱动器保留创建子进程的测试能力，严格约束加在被测引擎；不能把父驱动器套进 O0 后再宣称原 git 基线失败。

## 已取得的前后证据

原 JIT/native git 路径已通过完整五工具、两次审批以及上述快照/HTTP/仓库元数据断言。当前 O4a v1 没有 git，严格仿真得到 `repository baseline snapshot is required`；summary 只有模型文件、没有外部改动，也没有 snapshot 字段，O0b 正确记为 BLOCKED。后续 Git 后端需要让同一测试通过，不能删除快照或外部改动断言。

这是普通仓库的单轮端到端验收。未合并索引、私有对象库的备选读取、工作树链接、子模块、重命名和二进制计数另由 Git 子项的对照测试覆盖；本文件不把这些尚未执行的情况算入通过。

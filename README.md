# Command Recall — 让 Tab 弹窗里出现你真正用过的参数

Tern 插件。它记住你在终端里敲过的命令参数，并让这些参数出现在 **Tab 弹窗**里，按使用频率、最近使用时间、退出状态排序。

效果（就在你截图的那个弹窗里）：

```
$ agy ·Tab·
┌─ 常用参数 ─────────────────────────────┐
│ --dangerously-skip-permissions  用了 2 次 · 今天 │
│ --model                         用了 1 次 · 今天 │
│ claude-opus                     用了 1 次 · 今天 │
├─ 普通补全 ─────────────────────────────┤
│ bin/   README.md   src/                          │
└────────────────────────────────────────┘
```

`README.md`、`src/` 那些是 zsh 原本就会给的文件补全，一条不少；上面那组是学出来的。

## 它怎么工作

```
你按回车
  ↓ Tern shell 集成报 OSC 133（命令行、退出码、耗时）
host.luau（常驻会话 daemon）
  → 拆命令行：程序 + 子命令路径 + 每个参数
  → 打分入库：~/Library/Application Support/Tern/plugin-data/command-recall/
       state.json            全量记忆（重启后重放）
       learned/<程序>        给 shell 读的纯文本排名表
  ↓
zsh completer（shell/tern-recall.zsh，一行 source）
  → 按「当前程序 + 已敲的子命令路径」取行
  → compadd 成本组，交给 Tern 的原生 Tab 弹窗显示
  → return 1：zsh 原本的补全照常往下跑
```

Tern 插件无法拦截终端窗格里的逐字击键（`tern.bind` 拿不到 `up`/`down`/`tab`，日志会写 `plugin bind left out: the preset binds these keys`），也无法自己往 Tab 弹窗里塞选项——弹窗里的行全部来自 shell 的 `compadd`。所以「学」在 Tern 插件里，「显示在 Tab 弹窗里」必须经过 shell 的补全系统。这也是每个成熟的同类方案的做法（zsh-autosuggestions、atuin、carapace 都在 shell 侧）。

## 安装

1. 装上插件（已在 `~/Library/Application Support/Tern/plugins/command-recall` 时可跳过）：

   ```sh
   /Applications/Tern.app/Contents/MacOS/tern plugin install ~/Documents/project/tern-command-recall
   ```

2. 在 `~/.zshrc` **末尾**（`compinit` 之后）加一行：

   ```zsh
   [ -n "$TERN_RECALL_DIR" ] && . "$TERN_RECALL_DIR/tern-recall.zsh"
   ```

   `TERN_RECALL_DIR` 由插件在每个 shell 启动时注入，所以同一行在正式 App 和 `TERN_CONFIG_DIR` 的调试实例里都有效，也不用写死路径。没有这个变量（别的终端、脚本、旧版本插件）时这一行什么都不做。

   想在 Tern 里拿到这一行：命令面板（⇧⌘P）→ `Command Recall: 复制 shell 绑定`。

3. 新开一个 Tab，用几条命令，然后 `agy ` + Tab。

## 排序（可解释的在线学习）

每个 (程序, 子命令路径, 参数) 记三样：用过几次 `n`、失败几次 `f`、最后一次用的时间 `t`。

```
score = sqrt(n) × 1/(1 + 天数/14) × (1 − 0.6 × f/n)
```

- `sqrt(n)`：用得多就靠前，但收益递减（iTerm2 Autocomplete 的做法），避免老习惯永久霸榜。
- `1/(1+天数/14)`：14 天半衰期的衰减（atuin 的 frecency 思路），最近用过的优先。
- `(1 − 0.6 × f/n)`：失败惩罚。同一个参数老是失败，它会自己沉下去——但不会消失，下次成功又会浮上来。奖励信号就是 shell 报的退出码，即在线学习（mcfly 的 `exit_factor` 特征）。

参数按上限收敛：每个 (程序,子命令) 最多 60 行、每个程序最多 200 行、最多 400 个程序，按分数裁剪，所以 Tab 读的文件永远是几十行的量级。

学什么、不学什么：

| 学 | 不学 |
|---|---|
| `--long-option`（≤64 字符）、`-s`、裸子命令（`push`、`compose`） | 路径（含 `/`）、通配、`$VAR`、引号里的词、`a=b` |

子命令路径不含参数与数据：`docker compose -f docker/dev.yml up -d` 学成 `compose` → `up`，而不是把 `docker/dev.yml` 当上下文。

## 隐私与清理

全部在本机：`~/Library/Application Support/Tern/plugin-data/command-recall/`，不发网络请求。清空：

```sh
rm -rf "$HOME/Library/Application Support/Tern/plugin-data/command-recall"
```

下次写入会自己重建（`learned/` 在每次落盘前都会 `mkdir`）。

## 已知限制

- 只认 shell 报告的 `command_finished`，所以只学**真的执行过**的命令；Tab 里选中但没回车的不会算。
- 目前只写了 zsh 的 completer。bash 需要类似的 `complete -F`，fish 需要 `complete -c`（数据格式是纯文本，可复用）。
- 参数级学习按「子命令路径」分桶，不区分 `-m` 后面的自由文本；那是数据不是选项，故意不学。
- Tern 弹窗里本组的图标取决于 zsh 的 completion tag：`-` 开头的走 option 图标，裸词（子命令）是通用图标。

## 开发

```sh
zsh shell/test.zsh            # shell 侧 24 项断言（程序识别、上下文、取行、注册顺序）
```

- `tern plugin link ~/Documents/project/tern-command-recall` 直接跑工作区里的副本。
- 插件每次加载都会把自测结果写到 `plugin-data/command-recall/selftest.json`（10 项：长参数、失败惩罚、跳过路径、管道拆分、wrapper 跳过……），是真实 Luau VM 里的证据，不污染你的记忆库。
- 只在 **daemon 重启**时才会重载 host 半边（窗口进程不持有它）；改 `host.luau`/`common.luau` 后要 `tern plugin reload` 且 daemon 重启，或 `pkill -f 'tern daemon'` 后重开窗口。

## 文件

| 文件 | 作用 |
|---|---|
| `plugin.toml` | manifest（`host` + `window` 两半） |
| `common.luau` | 命令行解析、打分、读写记忆（两半共用） |
| `host.luau` | 监听 `command_finished`、落盘、注入 `TERN_RECALL_DIR`、自测 |
| `window.luau` | 状态栏条目、`查看已学命令` 选择器、复制 shell 绑定 |
| `shell/tern-recall.zsh` | 真正的 completer（Tab 弹窗那一步） |
| `shell/test.zsh` | shell 侧断言 |

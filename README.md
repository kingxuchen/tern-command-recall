# Command Recall — 让所有终端的 Tab 补全里都出现你真正用过的参数

通用 Zsh 插件（同时兼容 Tern 扩展面板）。它记住你在任何终端（**Ghostty、Tern、tty7、Otty、iTerm2、Alacritty、Kitty、tmux、SSH**）里敲过的命令参数，并让这些高频参数出现在 **Tab 补全列表最上方**，按使用频率、最近使用时间、退出状态码自动排序。

效果：

```
$ agy ·Tab·
┌─ 常用参数 ─────────────────────────────┐
│ --dangerously-skip-permissions           │
│ --model                                  │
├─ 普通补全 ─────────────────────────────┤
│ bin/   README.md   src/                  │
└────────────────────────────────────────┘
```

`README.md`、`src/` 以及 carapace / `_git` 原本就会给的补全一条不少；最上面那组是从你真实敲过的命令里学出来的。

## 它怎么工作

```
你在任意终端按回车
  ↓ zsh preexec / precmd 钩子（纯 zsh 内置模块，零外部进程开销）
shell/tern-recall.zsh
  → 拆命令行：程序 + 子命令路径 + 每个参数
  → 按（频率 × 14天时间衰减 × 退出码失败惩罚）打分并加锁（zsystem flock）落盘：
       ~/.local/share/command-recall/learned/<程序>
  ↓
你按 Tab
  → zsh completer（_tern_recall）读取当前程序与子命令上下文的高分参数
  → 排在第一组（常用参数），并 return 1 让 zsh 原有补全（carapace、_git、文件）继续运行
  → 在 Tern 里自动进入原生 GUI 弹窗；在 Ghostty / 标准终端里自动开启分组标题与方向键高亮菜单（menuselect）

## 自动化安装（支持所有终端）

### 方式一：在 Ghostty / Otty / tty7 / iTerm2 中一键自动安装

在任意终端执行一行命令，会自动将插件克隆到 `~/.local/share/command-recall/plugin`、备份 `~/.zshrc.bak`、在 `~/.zshrc` 末尾安全追加加载块并导入历史命令：

```sh
curl -fsSL https://raw.githubusercontent.com/kingxuchen/tern-command-recall/main/scripts/install.sh | zsh
```

如果仓库已在本地，直接运行：

```sh
zsh scripts/install.sh
```

### 方式二：通过 Zsh 插件管理器安装（Zinit / Antidote / Oh-My-Zsh / Sheldon / Zap）

仓库根目录已包含标准入口 `tern-command-recall.plugin.zsh`，可直接在任意 Zsh 插件管理器中添加 `kingxuchen/tern-command-recall`：

```zsh
# Zinit
zinit light kingxuchen/tern-command-recall

# Antidote (.zsh_plugins.txt)
kingxuchen/tern-command-recall

# Zap
plug "kingxuchen/tern-command-recall"
```

### 方式三：在 Tern 中通过 GitHub 安装（自动配置 `~/.zshrc`）

```sh
/Applications/Tern.app/Contents/MacOS/tern plugin install github.com/kingxuchen/tern-command-recall --force
```

- 首次打开 Tern 窗口时（若尚未生成 `~/.local/share/command-recall/zshrc-configured` 标记），会自动备份 `~/.zshrc.bak` 并把通用加载行写入 `~/.zshrc`（若你日后手动从 `~/.zshrc` 删除该块以停用，由于标记已存在，不会再次强行写回）。
- 你也可以随时在命令面板（⇧⌘P）运行 `Command Recall: 写入 ~/.zshrc（全终端生效）`。

### 想保持 `~/.zshrc` 精简

安装器只往 `~/.zshrc` 写一个带标记的块，块体就是一行 source。把这一行换成指向你自己的文件、其余加载都放进去，安装器照样认得、重跑更新也不会写回第二份：

```zsh
# ~/.zshrc 里只留这一行
[ -r "$HOME/.config/zsh/command-recall.zsh" ] && . "$HOME/.config/zsh/command-recall.zsh"
```

```zsh
# ~/.config/zsh/command-recall.zsh
[ -r "$HOME/Library/Application Support/Tern/plugins/command-recall/shell/tern-recall.zsh" ] &&
  . "$HOME/Library/Application Support/Tern/plugins/command-recall/shell/tern-recall.zsh"
```

判定规则：安装器只看标记块里那条引号路径**是否存在**，存在就认为已装好，不会重写；路径写错或文件被删才会重新写回标准块。

### Tab 弹窗（fzf-tab）

插件只负责“给什么候选”，弹窗由渲染方决定：Tern 里是它自己的 GUI 弹窗；其他终端想要带边框的弹窗面板，装上 `fzf` + `fzf-tab` 即可，「常用参数」会和文件名、`git` 子命令一起出现在弹出的面板里。注意 Tern 会把 `compadd` 换成自己的桥，所以加载 fzf-tab 时要跳过 Tern：

```zsh
if [ -z "${TERN_COMPLETE-}" ] && [ -r "$HOME/.fzf-tab/fzf-tab.plugin.zsh" ]; then
  . "$HOME/.fzf-tab/fzf-tab.plugin.zsh"
  zstyle ':fzf-tab:*' fzf-flags --border=rounded --info=inline-right
  # --height = 候选数 + fzf-pad。默认 pad=2 只够查询行+分隔线；圆角边框还要
  # 上下各一行，不补上 3 个候选就只能露出 1 行。
  zstyle ':fzf-tab:*' fzf-pad 4
  # 有分组标题时 fzf-tab 默认给每条候选加 `·` 当分组标记，去掉免得像是命令的一部分
  zstyle ':fzf-tab:*' prefix ''
fi
```

（`·` 的来源：只要存在 `zstyle ':completion:*:descriptions' format`——本插件会设——fzf-tab 就认为列表是分组的，于是给每条加前缀。`prefix ''` 只关掉这个符号，分组仍由标题行区分。）

### 更新：重跑一遍安装命令

```sh
curl -fsSL https://raw.githubusercontent.com/kingxuchen/tern-command-recall/main/scripts/install.sh | zsh
```

同一条命令就是更新，一次把两处都对齐到最新代码：`~/.local/share/command-recall/plugin`（shell 插件的 git clone）和 `~/Library/Application Support/Tern/plugins/command-recall`（Tern 插件包）。本机没装 Tern 就只更新 shell 侧。

在 clone 里手改过代码也不会再卡住更新：

- 手改的内容和上游最新版本一样 → 直接用最新代码，不重复留一份；
- 是自己的真改动 → 先存进 `git stash` 再更新，脚本会打印取回命令 `git stash pop`；
- clone 里有自己的提交 → 自动更新会丢掉东西，所以停下不动，并提示怎么 rebase。

在本地仓库里开发时 `zsh scripts/install.sh` 表示「用当前这份代码安装」：只刷新 shell 加载块和 Tern 插件包，不动上游。用 `tern plugin link` 把插件指向开发目录的话，更新会跳过覆盖，改完代码 `tern plugin reload command-recall` 即可。

### 终端内检索与查看（`recall`）

```zsh
recall            # 若装有 fzf 则弹出交互式选择器并直接填入命令行；否则列出所有已学程序
recall git        # 查看 git 已学的高频参数（按频率与最近使用排序，不显示次数和日期）
recall forget git --no-pager   # 忘掉 git 的 --no-pager（这个命令的所有上下文一起删）
recall --list     # 纯文本列出所有已学程序及前 3 个常用参数
recall --install  # 手动触发安全写入 ~/.zshrc
```

### 忘记学到的东西

记忆里的每一行是 `程序 [子命令] 参数`（比如 `git log --no-pager`）。**搜索能一路搜到参数这一级**，删的也是你选中的那一行：`git log --no-pager` 被删时，`git --no-pager`（不带子命令的那条）不受影响。删完没有拉黑——你下次再用，会被重新学到、重新开始计数。

| 界面 | 怎么删 |
|---|---|
| Tern | 命令面板（⇧⌘P）→「Command Recall: 忘记某条」→ 一个列表列出所有命令的所有行，输入即过滤（命令、子命令、选项都能搜），↵ 删除选中行 |
| `recall` 的 fzf 选择器 | 所有程序的所有行在同一个列表里，输入过滤到参数级；选中后按 **Delete**（也可以 fn+Delete）只删那一行，**Enter** 仍把选中行填入命令行 |
| `recall forget <程序> <词>` | 任意终端：忘掉这个词的所有上下文；`recall forget <程序> <词> <子命令>` 只删那一行 |
| fzf-tab 的 Tab 弹窗 | 选中那一条直接按 **Delete**（那颗键盘上 `+` 右边的键）：删掉、面板关闭，命令行上方出现 `已忘记 --no-pager · git` |
| 任意终端里正在编辑的那行 | 光标停在这个词上，按 **Ctrl+X Ctrl+D** |

几点要先说清：

- 面板里的 **Delete 只对「常用参数」那组生效**：fzf-tab 自带的文件名、`git` 子命令即使和你学过的词同名，按 Delete 也什么都不做（不删记忆，也不关面板）。识别办法是给我们的每一行加一个不可见标记（零宽空格），Delete 只认带标记的行。
- 而且**只在搜索框是空的时候忘词**；你已经在搜索框里敲了过滤字符时，它照旧删搜索字符——不然改错别字就会顺手删掉记忆。想忘词就让搜索框空着（`Ctrl+U` 清空）再按 Delete。
- 面板关闭时 zle 会响一声，tty7 会把它画成屏幕闪一下；插件把交互式提示音直接关掉了（和早就关掉的补全列表铃声一样）。想留着提示音，就在 `~/.zshrc` 的加载块**之后**加一句 `setopt beep`。
- 如果你在 `~/.zshrc` 里自己设了 `zstyle ':fzf-tab:*' fzf-bindings`，它会把这里的删除键顶掉；要保留就把绑定一起带上（`bspace:transform:…`，值见 `shell/tern-recall.zsh` 里的 `_tern_recall_fzf_binding`）。
- 不装 fzf-tab 时，zsh 自带的高亮列表按 Delete 仍然只是删字符：zsh 的菜单键位表（`menuselect`）只认它内置的那几件函数，插件加不进自己的键（实测：绑上去的 widget 完全不触发）。用 **Ctrl+X Ctrl+D** 或上面两条路代替；这个组合键只在 `^X^D` 还没被占用时才绑，你自己绑过就不动它。

## 排序（可解释的在线学习）

每个 (程序, 子命令路径, 参数) 记三样：用过几次 `n`、失败几次 `f`、距离上次使用的天数 `days`。

```
score = sqrt(n) × 1/(1 + days/14) × (1 − 0.6 × f/n)
```

- `sqrt(n)`：用得多就靠前，但收益递减，避免老习惯永久霸榜。
- `1/(1+days/14)`：14 天半衰期的衰减，最近用过的优先。
- `(1 − 0.6 × f/n)`：失败惩罚。同一个参数老是报错退出（`$? != 0`），它会自己沉下去——但不会消失，下次成功又会浮上来。

学什么、不学什么：

| 学 | 不学 |
|---|---|
| `--long-option`（≤64 字符）、`-s`、裸子命令（`push`、`compose`） | 路径（含 `/`）、通配、`$VAR`、引号里的词、`a=b`、顶层选项后面的参数值 |

## 各终端适配说明
- **Tern**：自动接入 Tern 原生 GUI Tab 弹窗，并对后续补全组中的同名项去重。
- **Ghostty / iTerm2 / Alacritty / Kitty / WezTerm / tmux**：在非 Tern 终端下自动启用 Zsh `menuselect` 方向键高亮菜单与 `── 常用参数 ──` 分组头。
- **tty7 / Otty**：在其中敲的每条命令都会实时计入共享记忆库；若将终端的 Tab 补全交给 Shell（如在 tty7 设置中关闭内置 `Tab completion`），Tab 同样直接展示 `常用参数`。
- **多少条就渲染多少条**：候选超过 zsh 的 `LISTMAX`（默认 100）且列表比窗口高时，zsh 第一下什么都不画，只问 `zsh: do you wish to see all N possibilities (M lines)?`，得再按一次键；插件在非 Tern 弹窗的终端里把 `LISTMAX` 抬到 `100000`，第一下 Tab 就把全部候选渲染出来（不用翻页，也不用先答一句）。想改回 zsh 的问法：在 `~/.zshrc` 的 Command Recall 块**之后** `export LISTMAX=100`。
## 隐私与清理

全部在本机：`~/.local/share/command-recall/`，不发任何网络请求。清空记忆：

```sh
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/command-recall"
```

## 开发与测试

```sh
zsh -f shell/test.zsh         # 全绿即通过（学习引擎、失败惩罚、历史导入、并发文件锁、.zshrc 安全安装与升级、去重、recall 命令、安装与更新两条链路）
```

## 文件

| 文件 | 作用 |
|---|---|
| `tern-command-recall.plugin.zsh` | 标准 Zsh 插件管理器入口（Zinit / Antidote / Oh-My-Zsh / Zap） |
| `shell/tern-recall.zsh` | 核心实现：纯 Zsh 在线学习（`preexec`/`precmd`）、历史导入、Tab 补全器、`recall` 命令、`--install` |
| `scripts/install.sh` | 一键安装 / 更新脚本：对齐 shell 插件的 clone 与 Tern 插件包，重跑即更新 |
| `shell/test.zsh` | 自动化回归测试套件 |
| `plugin.toml` | Tern 插件清单（可选，仅挂载 `window.luau`） |
| `window.luau` | Tern 窗口扩展：首次启动自动配置 `~/.zshrc`、「忘记某条」选择器（全部已学行扁平列出，搜索过滤、选中删除） |

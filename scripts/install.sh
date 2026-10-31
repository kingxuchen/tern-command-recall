#!/usr/bin/env zsh
# One-line universal installer & updater for Ghostty, Otty, tty7, Tern, iTerm2, Alacritty:
#   curl -fsSL https://raw.githubusercontent.com/kingxuchen/tern-command-recall/main/scripts/install.sh | zsh
#
# Re-running that command IS the update. One tree feeds two surfaces:
#   shell plugin — a git clone under $TERN_RECALL_DIR/plugin, sourced from ~/.zshrc
#   Tern plugin  — $plugins/command-recall, re-installed with `tern plugin install --force`
#
# A local edit inside the clone never blocks the update again: an edit whose content
# already matches the newest upstream commit is dropped, a real edit is stashed so
# nothing is lost, and commits of your own stop the update instead of being erased.
set -euo pipefail

REPO_URL="${COMMAND_RECALL_REPO:-https://github.com/kingxuchen/tern-command-recall.git}"
DATA_DIR="${TERN_RECALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/command-recall}"
INSTALL_DIR="${COMMAND_RECALL_INSTALL_DIR:-$DATA_DIR/plugin}"

# The fully qualified remote-tracking ref this checkout follows: its upstream, else
# the first remote plus the current branch. Qualified so a ref can never be ambiguous.
_upstream_ref() {
  local dir=$1 upstream remote branch
  upstream=$(git -C "$dir" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null) ||
    upstream=''
  if [[ $upstream == refs/remotes/*/* ]]; then
    print -r -- "$upstream"
    return 0
  fi
  branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null) || branch=main
  remote=$(git -C "$dir" remote 2>/dev/null) || remote=''
  remote=${remote%%$'\n'*}
  print -r -- "refs/remotes/${remote:-origin}/$branch"
}

# Install or update the shell plugin's source tree in place. Returns 1 when the
# newest code could not be reached, keeping whatever is already on disk working.
_sync_shell_clone() {
  local dir=$1
  if [[ ! -d "$dir/.git" ]]; then
    if [[ -e "$dir" ]]; then
      print -ru2 -- "✗ $dir 已经存在，但它不是 git 仓库，没法自动更新。"
      print -ru2 -- "  确认里面没有你要留的东西后删掉再重跑：rm -rf \"$dir\""
      exit 1
    fi
    mkdir -p "${dir:h}"
    if ! git clone --depth 1 --quiet "$REPO_URL" "$dir"; then
      print -ru2 -- "✗ 下载代码失败（网络不通或仓库地址不对）：$REPO_URL"
      exit 1
    fi
    print -r -- "✓ 已下载最新代码：$dir"
    return 0
  fi
  local ref tail remote branch before want
  ref=$(_upstream_ref "$dir")
  tail=${ref#refs/remotes/}
  remote=${tail%%/*}
  branch=${tail#*/}
  before=$(git -C "$dir" rev-parse --short HEAD)

  local fetch_out
  if ! fetch_out=$(git -C "$dir" fetch --quiet "$remote" "+refs/heads/$branch:$ref" 2>&1); then
    print -ru2 -- "✗ 拉取最新代码失败：${fetch_out:-未知错误}"
    print -ru2 -- "  先用着当前版本 $before，网络恢复后重跑一次即可"
    return 1
  fi
  want=$(git -C "$dir" rev-parse --short "$ref")

  # Files edited locally, judged against the newest upstream version by path: what
  # upstream already shipped is simply dropped, what is genuinely yours is kept in a
  # stash. Whole-tree comparison would never match — upstream usually ships more.
  local -a edited
  edited=( ${(0)"$(git -C "$dir" diff --name-only --no-renames -z HEAD)"} )

  if (( ${#edited[@]} == 0 )) && [[ $before == $want ]]; then
    print -r -- "↻ shell 插件已经是最新（$want）"
    return 0
  fi

  if ! git -C "$dir" merge-base --is-ancestor HEAD "$ref" 2>/dev/null; then
    print -ru2 -- "! 这份 clone 的历史和上游不在一条线上（你有额外提交，或上游被重写过），自动更新会丢掉东西，所以先不动。"
    print -ru2 -- "  想继续自己维护：git -C \"$dir\" log --oneline \"$ref..HEAD\"，改完 git -C \"$dir\" rebase $ref"
    return 1
  fi

  if (( ${#edited[@]} )); then
    if git -C "$dir" diff --quiet "$ref" -- "${edited[@]}"; then
      print -r -- "! 本地手改的 ${#edited[@]} 个文件内容和上游最新版本一样，直接用最新代码，不重复留一份"
    elif git -C "$dir" stash push --quiet --message "command-recall update from $before" 2>/dev/null; then
      print -r -- "! 已把你的本地改动存进 git stash，更新后想拿回来："
      print -r -- "    git -C \"$dir\" stash pop"
    else
      print -ru2 -- "✗ 本地改动没能存进 stash，为安全起见没有更新"
      return 1
    fi
  fi

  if ! git -C "$dir" reset --hard --quiet "$ref"; then
    print -ru2 -- "✗ 代码已经拉到本地，但工作树没能切换过去（可能是 .git/index.lock 被占），当前版本保持不动"
    return 1
  fi
  print -r -- "↑ shell 插件已更新：$before → $want"
  return 0
}

# Refresh the Tern package from that same tree. No Tern on this machine, a linked
# developer checkout, or a missing manifest all skip instead of breaking the shell side.
_sync_tern_plugin() {
  local src=$1
  [[ -f "$src/plugin.toml" ]] || return 0
  if ! command -v tern >/dev/null 2>&1; then
    print -r -- "– 这台机器没有 tern 命令，只更新了 shell 插件"
    return 0
  fi

  local id pdir
  id=$(awk -F'"' '/^[[:space:]]*id[[:space:]]*=/ { print $2; exit }' "$src/plugin.toml")
  if [[ -z $id ]]; then
    print -ru2 -- "! plugin.toml 里读不到 id，跳过 Tern 插件更新"
    return 0
  fi
  pdir=$(tern plugin dir 2>/dev/null) || pdir=''
  if [[ -z $pdir ]]; then
    print -ru2 -- "! tern plugin dir 没返回路径，跳过 Tern 插件更新"
    return 0
  fi

  if [[ -f "$pdir/$id.path" ]]; then
    print -r -- "– Tern 插件 link 的是开发目录（$(<"$pdir/$id.path")），不覆盖，改完代码 tern plugin reload $id 即可"
    return 0
  fi

  # `tern plugin install` copies the whole directory, so a development checkout would
  # also drop its build output (dist/), scratch files and gitignored junk into the
  # plugins dir. When the tree holds anything beyond what git tracks, install only the
  # tracked files. `status --ignored` reports untracked (`??`) and ignored (`!!`) both,
  # which `ls-files --ignored` alone would miss.
  local -a junk
  junk=( ${(f)"$(git -C "$src" status --porcelain --ignored --untracked-files=all 2>/dev/null | grep -E '^\s*(\?\?|!!) ')"} )
  local stage=''
  if (( ${#junk[@]} )) && command -v rsync >/dev/null 2>&1; then
    stage=$(mktemp -d)/$id
    if ! mkdir -p "$stage" ||
       ! rsync -a --files-from=<(git -C "$src" ls-files) "$src/" "$stage/" 2>/dev/null; then
      print -ru2 -- "! 没能只打包 git 跟踪的文件，改为整个目录安装（可能带上 dist/）"
      rm -rf "${stage:h}" 2>/dev/null
      stage=''
    else
      src="$stage"
    fi
  fi

  local install_out
  if install_out=$(tern plugin install "$src" --force 2>&1); then
    print -r -- "✓ Tern 插件已更新：$pdir/$id"
  else
    print -ru2 -- "✗ Tern 插件更新失败（shell 插件不受影响）：${install_out:-未知错误}"
    print -ru2 -- "  手动重试：tern plugin install \"$1\" --force"
    [[ -n $stage ]] && rm -rf "${stage:h}"
    return 1
  fi
  [[ -n $stage ]] && rm -rf "${stage:h}"
  return 0
}

# Running from a local checkout means "install/update from what you are editing".
SCRIPT_SOURCE="${(%):-%x}"
stale=0
if [[ -n "$SCRIPT_SOURCE" && -f "${SCRIPT_SOURCE:A:h:h}/shell/tern-recall.zsh" ]]; then
  INSTALL_DIR="${SCRIPT_SOURCE:A:h:h}"
  print -r -- "↻ 用当前仓库代码安装：$INSTALL_DIR"
elif ! _sync_shell_clone "$INSTALL_DIR"; then
  # 拉不到最新不代表装不了：磁盘上这一份仍然是可用的，把两个面都对齐到它。
  stale=1
fi

/bin/zsh "$INSTALL_DIR/shell/tern-recall.zsh" --install
tern_status=0
_sync_tern_plugin "$INSTALL_DIR" || tern_status=1

print -r -- "✓ Command Recall 就绪：$INSTALL_DIR"
print -r -- "  新开一个 Tab（或先 source ~/.zshrc）就能在 Ghostty、Otty、tty7、Tern、iTerm2 生效"
exit $(( tern_status || stale ))

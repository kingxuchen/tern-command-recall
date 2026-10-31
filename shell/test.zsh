#!/usr/bin/env zsh
# Drives the tern-recall helpers without an active completion: assigns the two
# names zsh would set ($words, $CURRENT) and checks what each helper answers.
# Run: zsh shell/test.zsh
set -u

here=${0:A:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

mkdir -p $tmp/learned
row() {
	print -r -- "${(j:	:)@}"
}
# Rows are `token \t uses \t fails \t last_used \t score \t context', best first —
# the same shape the plugin writes. The empty context (a row for the first
# argument) is the last column, so `read' keeps it.
zmodload zsh/datetime
now_ts=$EPOCHSECONDS
{
	row status 3 0 $now_ts 1.0000 ''
	row commit 2 0 $(( now_ts - 86400 )) 0.9000 ''
	row origin 2 0 $now_ts 0.8000 push
	row --force-with-lease 1 1 $now_ts 0.3200 push
	row HEAD 1 0 $now_ts 0.7000 'push origin'
} >$tmp/learned/git
row up 1 0 $now_ts 0.5000 compose >$tmp/learned/docker
row -la 1 0 $(( now_ts - 3 * 86400 )) 0.4000 '' >$tmp/learned/ls
row --silent 2 0 $now_ts 1.0000 'test:web' >$tmp/learned/pnpm
export TERN_RECALL_DIR=$tmp
source "$here/tern-recall.zsh"

fails=0
check() {
	local name=$1 want=$2 got=$3
	if [[ $want == $got ]]; then
		print -r -- "ok   $name"
	else
		print -r -- "FAIL $name: want [$want] got [$got]"
		((fails++))
	fi
}

# 0. Sourcing stops zsh's list bell — terminals render it as a beep or, with a
# visual bell, a screen flash on every Tab that lists.
check "bell: listbeep off after source" 0 $([[ -o listbeep ]] && print 1 || print 0)

# 0b. Past LISTMAX (100 by default) zsh draws nothing on the first Tab and only asks
# `do you wish to see all N possibilities?' — one wasted keypress per long list, and this
# plugin's own group only makes lists longer. Outside Tern's popup the plugin raises
# LISTMAX so a single Tab renders every match however many there are — a big positive
# number, because `-1' renders everything on zsh 5.9 yet zshparam documents a negative
# value as line-based, and the two can't both be trusted. A LISTMAX the user moved off
# the default is left alone, and `list-prompt' is never touched: any value there, the
# empty string included, puts zsh back into its paging list instead of rendering.
cat > "$tmp/listprobe.zsh" <<'PROBE'
eval "${PRELUDE:-zmodload zsh/zutil}"
source "$1"
print -r -- "LISTMAX=${LISTMAX-unset} list-prompt=$(zstyle -s ':completion:*' list-prompt V && print -r -- "[$V]" || print -r -- unset)"
PROBE
list_probe() {  # $1: zsh to run before sourcing; $2: TERN_COMPLETE value
	env -u TERN_COMPLETE ${2:+TERN_COMPLETE=$2} PRELUDE="${1:-zmodload zsh/zutil}" \
		TERN_RECALL_DIR="$tmp/styledir" HISTFILE=/nonexistent \
		/bin/zsh -f "$tmp/listprobe.zsh" "$here/tern-recall.zsh"
}
check "list: one Tab renders every match" "LISTMAX=100000 list-prompt=unset" "$(list_probe)"
check "list: a LISTMAX the user moved off the default survives" "LISTMAX=200 list-prompt=unset" \
	"$(list_probe 'zmodload zsh/zutil; export LISTMAX=200')"
check "list: Tern's popup leaves zsh's listing alone" "LISTMAX=100 list-prompt=unset" \
	"$(list_probe 'zmodload zsh/zutil' 1)"

# 1. The program is the first word that is neither a wrapper nor VAR=value.
words=(git push '')
CURRENT=3
_tern_recall_program
check "program: git" git "$REPLY"
check "program: at" 1 "$_tern_recall_at"

words=(sudo git push '')
CURRENT=4
_tern_recall_program
check "program: after sudo" git "$REPLY"
check "program: sudo at" 2 "$_tern_recall_at"

words=(GIT_CLOUD=1 git push '')
CURRENT=4
_tern_recall_program
check "program: after assignment" git "$REPLY"

words=(/usr/bin/git push '')
CURRENT=3
_tern_recall_program
check "program: basename" git "$REPLY"

# 2. Nothing to add while the command word itself is being completed.
words=('')
CURRENT=1
_tern_recall_program
check "program: none yet" 1 $?

# 3. Context = the subcommand path, without flags or data.
words=(git push '')
CURRENT=3
_tern_recall_program
_tern_recall_context
check "context: push" push "$REPLY"

words=(sudo git push origin '')
CURRENT=5
_tern_recall_program
_tern_recall_context
check "context: push origin" "push origin" "$REPLY"

words=(docker compose -f docker/dev.yml up '')
CURRENT=6
_tern_recall_program
_tern_recall_context
check "context: skips flags and paths" "compose up" "$REPLY"

words=(git -C /tmp status '')
CURRENT=5
_tern_recall_program
_tern_recall_context
check "context: skips -C and its path" status "$REPLY"

# 4. Rows come back in stored (score) order, as bare words.
words=(git push '')
CURRENT=3
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$TERN_RECALL_DIR/learned/git" "$REPLY"
check "rows: count" 2 ${#_tern_recall_tok[@]}
check "rows: first" origin "${_tern_recall_tok[1]}"
check "rows: second" --force-with-lease "${_tern_recall_tok[2]}"

words=(git '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$TERN_RECALL_DIR/learned/git" "$REPLY"
check "rows: top level" "status commit" "${(j: :)_tern_recall_tok[@]}"

words=(git status '')
CURRENT=3
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$TERN_RECALL_DIR/learned/git" "$REPLY"
check "rows: unseen context" 1 $?

_tern_recall_rows "$TERN_RECALL_DIR/learned/nope" ''
check "rows: unseen program" 1 $?

words=(ls '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$TERN_RECALL_DIR/learned/ls" "$REPLY"
check "rows: flags are learned too" "-la" "${_tern_recall_tok[1]}"

# 4b. Namespaced script names build the context, and a typed word is not re-offered.
words=(pnpm test:web --reporter '')
CURRENT=4
_tern_recall_program
_tern_recall_context
check "context: colon in a word" "test:web" "$REPLY"
_tern_recall_rows "$TERN_RECALL_DIR/learned/pnpm" "$REPLY"
check "rows: namespaced context" "--silent" "${_tern_recall_tok[1]}"

words=(git push --force-with-lease '')
CURRENT=4
_tern_recall_program
_tern_recall_context
check "context: flags stay out" push "$REPLY"
_tern_recall_rows "$TERN_RECALL_DIR/learned/git" "$REPLY"
check "rows: skips the word already typed" 1 ${#_tern_recall_tok[@]}
check "rows: offers the one not typed" origin "${_tern_recall_tok[1]}"

# 5. The completer is registered ahead of the default pair, once.
local -a completers
zstyle -a ':completion:*' completer completers
check "register: first" _tern_recall "${completers[1]}"
check "register: ours precedes _complete" 1 $(( ${completers[(Ie)_tern_recall]} < ${completers[(Ie)_complete]} ? 1 : 0 ))
source "$here/tern-recall.zsh"
zstyle -a ':completion:*' completer completers
check "register: idempotent" 3 ${#completers[@]}
check "register: still one" 1 ${completers[(Ie)_tern_recall]}

# 6. Deduplication across groups in Tern's completion arrays (_tern_cmp_*).
typeset -ga _tern_cmp_hit _tern_cmp_w _tern_cmp_d _tern_cmp_g _tern_cmp_k _tern_cmp_s _tern_cmp_c
typeset -gA compstate
_tern_cmp_hit=(commit commit copy-ignored)
_tern_cmp_w=(commit commit copy-ignored)
_tern_cmp_d=('' 'Stage and commit' 'Copy gitignored')
_tern_cmp_g=(0 1 1)
_tern_cmp_k=(other value value)
_tern_cmp_s=('' '' '')
_tern_cmp_c=(1 2 2)
compstate=(list 'ambiguous ' insert 'automenu-unambiguous')
_tern_recall_post
check "dedup: keeps unique words in order" "commit copy-ignored" "${(j: :)_tern_cmp_w[@]}"
check "dedup: learned row keeps no description" "" "${_tern_cmp_d[1]}"
check "dedup: upgrades kind from _complete" "value" "${_tern_cmp_k[1]}"
check "dedup: leaves insert alone when >1 unique match" "automenu-unambiguous" "${compstate[insert]}"

# Single unique match across both groups collapses to 1 match and inserts once.
_tern_cmp_hit=(commit commit)
_tern_cmp_w=(commit commit)
_tern_cmp_d=('' 'Stage and commit')
_tern_cmp_g=(0 1)
_tern_cmp_k=(other value)
_tern_cmp_s=('' '')
_tern_cmp_c=(1 2)
compstate=(list 'ambiguous ' insert 'automenu-unambiguous')
RBUFFER=''
_tern_recall_post
check "single unique: count is 1" 1 ${#_tern_cmp_w[@]}
check "single unique: clears list" "" "${compstate[list]}"
check "single unique: inserts first match once with space" "1 " "${compstate[insert]}"

# 7. Standalone shell learning (replaces the old Luau host selftest transcript).
learn_tmp=$(mktemp -d)
trap 'rm -rf $tmp $learn_tmp' EXIT
TERN_RECALL_DIR=$learn_tmp

_tern_recall_learn "git status --short" 0 0 1700000000
_tern_recall_learn "git status --short" 0 0 1700000000
_tern_recall_learn "git status" 0 0 1700000000
_tern_recall_learn "git commit -m fix" 0 0 1700000000
_tern_recall_learn "git commit -am fix" 0 0 1700000000
_tern_recall_learn "git push origin HEAD" 0 0 1700000000
_tern_recall_learn "git push --force-with-lease" 2 0 1700000000
_tern_recall_learn "sudo git push origin main" 0 0 1700000000
_tern_recall_learn "pnpm test:web --reporter dot" 0 0 1700000000
_tern_recall_learn "pnpm vitest run src/foo.test.ts" 0 0 1700000000
_tern_recall_learn "pnpm install --frozen-lockfile" 0 0 1700000000
_tern_recall_learn 'echo "hello | world" && ls -la /tmp' 0 0 1700000000
_tern_recall_learn "docker compose -f docker/dev.yml up -d" 0 0 1700000000
_tern_recall_learn 'ls -la $HOME/Library' 0 0 1700000000
_tern_recall_learn "cat ./README.md" 0 0 1700000000
_tern_recall_learn "agy --dangerously-skip-permissions" 0 0 1700000000
_tern_recall_learn "agy --dangerously-skip-permissions" 0 0 1700000000
_tern_recall_learn "agy --model claude-opus" 0 0 1700000000

words=(git '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$learn_tmp/learned/git" "$REPLY"
check "learn: top git subcommands ranked" "status commit push" "${(j: :)_tern_recall_tok[@]}"

words=(git push '')
CURRENT=3
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$learn_tmp/learned/git" "$REPLY"
check "learn: failure penalised below success" "origin --force-with-lease" "${(j: :)_tern_recall_tok[@]}"

[[ -e $learn_tmp/learned/sudo ]]; check "learn: wrapper sudo is not a program" 1 $?
[[ -e $learn_tmp/learned/cat ]]; check "learn: skips paths (cat ./README.md)" 1 $?
[[ -e $learn_tmp/learned/echo ]]; check "learn: skips quoted data (echo)" 1 $?

words=(ls '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$learn_tmp/learned/ls" "$REPLY"
check "learn: splits pipeline and skips expansion" "-la" "${(j: :)_tern_recall_tok[@]}"

words=(docker compose '')
CURRENT=3
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$learn_tmp/learned/docker" "$REPLY"
check "learn: context ignores flag data" "-f up" "${(j: :)_tern_recall_tok[@]}"

words=(agy '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$learn_tmp/learned/agy" "$REPLY"
check "learn: keeps long flags, skips flag value, ranks by use" "--dangerously-skip-permissions --model" "${(j: :)_tern_recall_tok[@]}"

# 8. preexec + precmd lifecycle: preexec counts use, precmd adds failure mark without double-counting uses.
_tern_recall_learn "curl --fail --silent" 0 0 $now_ts
_tern_recall_learn "curl --fail --silent" 22 1 $now_ts
words=(curl '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$learn_tmp/learned/curl" "$REPLY"
check "hooks: preexec + failing precmd offers the flag" --fail "${_tern_recall_tok[1]}"
local curl_line
IFS= read -r curl_line < "$learn_tmp/learned/curl"
check "hooks: failing precmd records fails=1 and epoch" $'--fail\t1\t1\t'"${now_ts}"$'\t0.4000\t' "$curl_line"

# 9. History import: parses zsh extended timestamps, skips continuations and meta bytes.
hist_tmp=$(mktemp -d)
trap 'rm -rf $tmp $learn_tmp $hist_tmp' EXIT
TERN_RECALL_DIR=$hist_tmp
cat > "$hist_tmp/zsh_history" <<EOF
: $(( now_ts - 100 )):0;rg --hidden --files
: $(( now_ts - 50 )):0;rg --hidden
rg --smart-case
: $(( now_ts - 10 )):0;rg --broken \\
EOF
_tern_recall_import_history "$hist_tmp/zsh_history" $now_ts
words=(rg '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$hist_tmp/learned/rg" "$REPLY"
check "history: imports and ranks recent higher than undated" "--hidden --files --smart-case" "${(j: :)_tern_recall_tok[@]}"
check "history: writes history-imported marker" "3 commands" "$(<$hist_tmp/history-imported)"

# 10. `recall' CLI inspector works in any terminal.
check "recall cli: lists program summary" $'rg\t--hidden  --files  --smart-case' "$(recall --list)"
check "recall cli: inspects single program" $'rg --hidden\t用了 2 次 · 今天' "${"$(recall rg)"%%$'\n'*}"

# 11. Concurrent panes learning the same program keep every update via flock.
(
	for (( i = 1; i <= 10; i++ )); do
		_tern_recall_learn "cargo --release" 0 0 $now_ts
	done
) &
pid1=$!
(
	for (( i = 1; i <= 10; i++ )); do
		_tern_recall_learn "cargo --release" 0 0 $now_ts
	done
) &
pid2=$!
wait $pid1 $pid2
words=(cargo '')
CURRENT=2
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$hist_tmp/learned/cargo" "$REPLY"
local cargo_tok cargo_uses
IFS=$'\t' read -r cargo_tok cargo_uses _ < "$hist_tmp/learned/cargo"
check "flock: concurrent writers keep one row with all 20 uses" "--release 20" "$cargo_tok $cargo_uses"

# 12. `.zshrc' installer: appends safely with backup, is idempotent, upgrades legacy block, and preserves symlinks.
rc_tmp=$(mktemp -d)
trap 'rm -rf $tmp $learn_tmp $hist_tmp $rc_tmp' EXIT
TERN_RECALL_DIR="$rc_tmp/data"
print -r -- "export FOO=bar" > "$rc_tmp/real_zshrc"
chmod 600 "$rc_tmp/real_zshrc"
ln -s "$rc_tmp/real_zshrc" "$rc_tmp/.zshrc"

check "install: appends to symlinked zshrc" "installed" "$(_tern_recall_install_zshrc "$rc_tmp/.zshrc" "$here/tern-recall.zsh")"
[[ -L $rc_tmp/.zshrc ]]; check "install: preserves symlink" 0 $?
[[ -f $rc_tmp/real_zshrc.bak ]]; check "install: writes backup .zshrc.bak" 0 $?
check "install: idempotent on second run" "already-installed" "$(_tern_recall_install_zshrc "$rc_tmp/.zshrc" "$here/tern-recall.zsh")"

# Cross-plugin idempotency: if another plugin copy (e.g. Tern vs standalone shell plugin)
# is already valid in `.zshrc', the second plugin does not rewrite it (byte-for-byte identical),
# in both directions.
cp "$here/tern-recall.zsh" "$rc_tmp/other-plugin-copy.zsh"
before_zshrc=$(<"$rc_tmp/.zshrc")
check "install: cross-plugin idempotent (Tern -> standalone)" "already-installed" "$(_tern_recall_install_zshrc "$rc_tmp/.zshrc" "$rc_tmp/other-plugin-copy.zsh")"
check "install: cross-plugin leaves .zshrc byte-for-byte unchanged" "$before_zshrc" "$(<"$rc_tmp/.zshrc")"

print -r -- "export FOO=bar" > "$rc_tmp/reverse_zshrc"
check "install: standalone installs first" "installed" "$(_tern_recall_install_zshrc "$rc_tmp/reverse_zshrc" "$rc_tmp/other-plugin-copy.zsh")"
before_rev=$(<"$rc_tmp/reverse_zshrc")
check "install: cross-plugin idempotent (standalone -> Tern)" "already-installed" "$(_tern_recall_install_zshrc "$rc_tmp/reverse_zshrc" "$here/tern-recall.zsh")"
check "install: reverse cross-plugin leaves .zshrc byte-for-byte unchanged" "$before_rev" "$(<"$rc_tmp/reverse_zshrc")"
# Legacy `$TERN_RECALL_DIR' block is upgraded in place while preserving surrounding lines and file permissions (0600).
cat > "$rc_tmp/legacy_zshrc" <<'EOF'
export BEFORE=1
# >>> Tern command-recall >>>
[ -n "$TERN_RECALL_DIR" ] && [ -r "$TERN_RECALL_DIR/tern-recall.zsh" ] && . "$TERN_RECALL_DIR/tern-recall.zsh"
# <<< Tern command-recall <<<
export AFTER=1
EOF
chmod 600 "$rc_tmp/legacy_zshrc"
check "install: upgrades legacy block" "upgraded" "$(_tern_recall_install_zshrc "$rc_tmp/legacy_zshrc" "$here/tern-recall.zsh")"
[[ "$(<$rc_tmp/legacy_zshrc)" == *"export BEFORE=1"* && "$(<$rc_tmp/legacy_zshrc)" == *"export AFTER=1"* && "$(<$rc_tmp/legacy_zshrc)" != *'$TERN_RECALL_DIR/tern-recall.zsh'* ]]
check "install: legacy upgrade keeps surrounding content" 0 $?
check "install: legacy upgrade preserves 0600 mode" "600" "$(stat -f '%Lp' "$rc_tmp/legacy_zshrc")"
# 13. Standard Zsh plugin manager entrypoint (`tern-command-recall.plugin.zsh').
source "${here:h}/tern-command-recall.plugin.zsh"
check "plugin.zsh: entrypoint loads cleanly" 0 $?

# A fake `tern' on PATH records the calls the installer makes, and snapshots the tree
# it was handed, instead of touching the plugin directory of this machine.
stub=$(mktemp -d)
mkdir -p "$stub/bin" "$stub/plugins"
cat > "$stub/bin/tern" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$stub/calls"
if [ "\$1" = plugin ] && [ "\$2" = dir ]; then printf '%s\n' "$stub/plugins"; fi
if [ "\$1" = plugin ] && [ "\$2" = install ]; then
	printf '%s\n' "\$3" > "$stub/src"
	(cd "\$3" && find . -type f | sed 's|^\./||' | sort) > "$stub/tree"
fi
exit 0
STUB
chmod +x "$stub/bin/tern"

# 14. `scripts/install.sh' parses cleanly, installs into an isolated ZDOTDIR and
# refreshes the Tern package from the same tree it just installed.
/bin/zsh -n "${here:h}/scripts/install.sh"
check "install.sh: syntax check (zsh -n)" 0 $?
ZDOTDIR="$rc_tmp/zdot" TERN_RECALL_DIR="$rc_tmp/zdot-data" HISTFILE="$rc_tmp/nohist" \
  PATH="$stub/bin:$PATH" /bin/zsh "${here:h}/scripts/install.sh" >/dev/null
check "install.sh: executes cleanly" 0 $?
[[ -f "$rc_tmp/zdot/.zshrc" ]]; check "install.sh: writes ZDOTDIR/.zshrc" 0 $?
grep -qx shell/tern-recall.zsh "$stub/tree" && grep -qx plugin.toml "$stub/tree"
check "install.sh: Tern package carries the plugin files" 0 $?
grep -q '^dist/' "$stub/tree"
check "install.sh: build output stays out of the Tern package" 1 $?

# 15. Re-running `scripts/install.sh' is the update, and a local edit inside the
# clone never blocks it again: an edit already equal to the newest upstream commit is
# dropped, a real one is stashed for the user to pop, and a commit of your own stops
# the update instead of being erased.
up=$(mktemp -d)
trap 'rm -rf $tmp $learn_tmp $hist_tmp $rc_tmp $stub $up' EXIT
gcfg=(-c user.name=test -c user.email=test@example.com)
mkdir -p "$up/origin/shell" "$up/origin/scripts" "$up/tool/scripts"
cp "$here/tern-recall.zsh" "$up/origin/shell/"
cp "${here:h}/plugin.toml" "$up/origin/"
# Run the installer from a directory that is not a checkout, so the clone path runs.
cp "${here:h}/scripts/install.sh" "$up/tool/scripts/install.sh"
git init --quiet "$up/origin"
git -C "$up/origin" "${gcfg[@]}" add -A
git -C "$up/origin" "${gcfg[@]}" commit -qm v1
origin_head() { git -C "$up/origin" rev-parse HEAD; }
plugin_head() { git -C "$up/plugin" rev-parse HEAD; }
run_installer() {
	: > "$stub/calls"
	COMMAND_RECALL_REPO="file://$up/origin" COMMAND_RECALL_INSTALL_DIR="$up/plugin" \
		TERN_RECALL_DIR="$up/data" ZDOTDIR="$up/zdot" HISTFILE="$up/nohist" \
		PATH="$stub/bin:$PATH" /bin/zsh "$up/tool/scripts/install.sh" 2>&1
}

out=$(run_installer); st=$?
check "update: first run installs a clone" 0 $st
check "update: first run clones the newest commit" "$(origin_head)" "$(plugin_head)"
grep -q "plugin install $up/plugin --force" "$stub/calls"
check "update: first run installs the Tern package from the clone" 0 $?
# `git stash' needs an identity; do not depend on the machine running the suite.
git -C "$up/plugin" config user.name test
git -C "$up/plugin" config user.email test@example.com

out=$(run_installer); st=$?
check "update: clean tree exits clean" 0 $st
[[ $out == *已经是最新* ]]
check "update: says it is already newest" 0 $?
grep -q "plugin install $up/plugin --force" "$stub/calls"
check "update: newest code still refreshes the Tern package" 0 $?

# 仓库连不上了（离线 / 地址改了）：不更新，但磁盘上这一份照样把两个面装好。
git -C "$up/plugin" remote set-url origin "$up/gone"
out=$(run_installer); st=$?
check "update: unreachable repo reports failure" 1 $st
[[ $out == *拉取最新代码失败* && $out == *先用着当前版本* ]]
check "update: says it keeps running the current version" 0 $?
grep -q "plugin install $up/plugin --force" "$stub/calls"
check "update: still installs the on-disk copy without network" 0 $?
git -C "$up/plugin" remote set-url origin "file://$up/origin"

# Upstream usually ships more than the file you were editing — v2 touches two.
print -r -- '# v2' >> "$up/origin/shell/tern-recall.zsh"
print -r -- '# v2' >> "$up/origin/plugin.toml"
git -C "$up/origin" "${gcfg[@]}" commit -qam v2
out=$(run_installer); st=$?
check "update: fast-forwards a newer upstream" 0 $st
check "update: clone moved to v2" "$(origin_head)" "$(plugin_head)"

# The reported incident: the clone was rewound and the same fix typed in by hand.
# The newest code must win, no stash must pile up, and nothing may look dirty.
git -C "$up/plugin" reset -q --hard HEAD~1
print -r -- '# v2' >> "$up/plugin/shell/tern-recall.zsh"
out=$(run_installer); st=$?
check "update: hand edit equal to upstream does not block" 0 $st
check "update: hand edit equal to upstream lands on newest" "$(origin_head)" "$(plugin_head)"
[[ $out == *和上游最新版本一样* ]]
check "update: drops the duplicated hand edit by path, not by whole tree" 0 $?
check "update: duplicated hand edit creates no stash" 0 \
  "$(git -C "$up/plugin" stash list | wc -l | tr -d '[:space:]')"
[[ -z $(git -C "$up/plugin" status --porcelain) ]]
check "update: tree clean afterwards" 0 $?

# Stray build output (untracked or ignored) must not ride into the plugins dir: what
# gets installed is the tree git tracks.
mkdir -p "$up/plugin/dist"
print -r -- 'junk' > "$up/plugin/dist/command-recall-v0.0.1.zip"
out=$(run_installer); st=$?
check "package: run with stray build output succeeds" 0 $st
[[ $(<"$stub/src") != "$up/plugin" ]]
check "package: installs from a staged tree, not the working directory" 0 $?
grep -q '^dist/' "$stub/tree"
check "package: stray build output is left out of the stage" 1 $?
grep -qx shell/tern-recall.zsh "$stub/tree" && grep -qx plugin.toml "$stub/tree"
check "package: staged tree still holds the plugin files" 0 $?
rm -rf "$up/plugin/dist"

# A real local edit survives as a stash the user is told how to pop.
print -r -- '# mine' >> "$up/plugin/shell/tern-recall.zsh"
print -r -- '# v3' >> "$up/origin/shell/tern-recall.zsh"
git -C "$up/origin" "${gcfg[@]}" commit -qam v3
out=$(run_installer); st=$?
check "update: real local edit does not block" 0 $st
check "update: real local edit still moves to newest" "$(origin_head)" "$(plugin_head)"
check "update: real local edit is kept as one stash" 1 \
  "$(git -C "$up/plugin" stash list | wc -l | tr -d '[:space:]')"
git -C "$up/plugin" stash show -p 'stash@{0}' | grep -q '# mine'
check "update: stash holds the local edit" 0 $?
[[ $out == *'stash pop'* ]]
check "update: prints how to get the local edit back" 0 $?

# A linked plugin is a developer's own checkout: never overwrite it.
print -r -- "$up/plugin" > "$stub/plugins/command-recall.path"
out=$(run_installer); st=$?
[[ $out == *不覆盖* ]]
check "update: linked plugin is left alone" 0 $?
check "update: linked run still succeeds" 0 $st
[[ $(grep -c 'plugin install' "$stub/calls") == 0 ]]
check "update: linked plugin installs nothing" 0 $?
rm -f "$stub/plugins/command-recall.path"

# Commits made in the clone are nobody's to erase: stop, say so, change nothing.
print -r -- '# local work' >> "$up/plugin/shell/tern-recall.zsh"
git -C "$up/plugin" "${gcfg[@]}" commit -qam 'local work'
local_head=$(plugin_head)
print -r -- '# v4' >> "$up/origin/shell/tern-recall.zsh"
git -C "$up/origin" "${gcfg[@]}" commit -qam v4
out=$(run_installer); st=$?
check "update: refuses to drop your own commit" 1 $st
[[ $(plugin_head) == $local_head && -z $(git -C "$up/plugin" status --porcelain) ]]
check "update: own commit left untouched" 0 $?
[[ $out == *不在一条线上* ]]
check "update: says why it stopped" 0 $?

print -r -- ""
if ((fails == 0)); then
	print -r -- "all checks passed"
else
	print -r -- "$fails check(s) failed"
fi
exit $((fails > 0))

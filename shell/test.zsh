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
# Rows are `token \t uses \t fails \t age_days \t score \t context', best first —
# the same shape the plugin writes. The empty context (a row for the first
# argument) is the last column, so `read' keeps it.
{
	row status 3 0 0.0 1.0000 ''
	row commit 2 0 1.2 0.9000 ''
	row origin 2 0 0.5 0.8000 push
	row --force-with-lease 1 1 0.5 0.3200 push
	row HEAD 1 0 0.5 0.7000 'push origin'
} >$tmp/learned/git
row up 1 0 0.1 0.5000 compose >$tmp/learned/docker
row -la 1 0 3.0 0.4000 '' >$tmp/learned/ls
row --silent 2 0 0.0 1.0000 'test:web' >$tmp/learned/pnpm

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

# 4. Rows come back in stored (score) order, with a plain-language explanation.
words=(git push '')
CURRENT=3
_tern_recall_program
_tern_recall_context
_tern_recall_rows "$TERN_RECALL_DIR/learned/git" "$REPLY"
check "rows: count" 2 ${#_tern_recall_tok[@]}
check "rows: first" origin "${_tern_recall_tok[1]}"
check "rows: second" --force-with-lease "${_tern_recall_tok[2]}"
check "rows: says" "origin -- 用了 2 次 · 今天" "${_tern_recall_say[1]}"

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
check "rows: age in days" "-la -- 用了 1 次 · 3 天前" "${_tern_recall_say[1]}"

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

print -r -- ""
if ((fails == 0)); then
	print -r -- "all checks passed"
else
	print -r -- "$fails check(s) failed"
fi
exit $((fails > 0))

# tern-recall — learned argument ranking, served into Tern's Tab list.
#
# The command-recall Tern plugin writes this file and its data into the plugin's
# data directory; source it once from your shell init, after `compinit':
#
#   [ -n "$TERN_RECALL_DIR" ] && . "$TERN_RECALL_DIR/tern-recall.zsh"
#
# It adds one zsh *completer* ahead of the default pair (`_complete _ignored'),
# so Tab still runs the normal completion — carapace, _git, files — and the list
# additionally leads with what you actually use for the command and subcommand
# you are typing. A completer that returns non-zero leaves the chain running (see
# _main_complete), which is how both groups end up listed.
#
# The data is plain text, one file per program, written by the plugin:
#
#   $TERN_RECALL_DIR/learned/<program>
#     <token>\t<uses>\t<fails>\t<age_days>\t<score>\t<context>
#
# `<context>' is the subcommand path before the word being completed, with flags
# and data left out: `git push --force-with-lease' is learned under `push'. It is
# the last column because the first argument position has none, and `read' drops a
# leading empty field.
#
# The helpers read `$words' and `$CURRENT' directly — the same names zsh sets in a
# completion context — so `test.zsh' can drive them by assigning those two.

# The plugin injects TERN_RECALL_DIR when it starts a shell. Without it — another
# terminal, a script, an older plugin build — this file changes nothing.
if [[ $+TERN_RECALL_DIR -eq 0 || ! -d $TERN_RECALL_DIR/learned ]]; then
  return 0
fi

# Wrappers run another program, so they are not the program. Kept in sync with
# WRAPPERS in the plugin's common.luau: both sides must agree on which word names
# the command, and the shell cannot require Luau.
typeset -ga _tern_recall_wrappers
typeset -gi _tern_recall_at
typeset -ga _tern_recall_tok _tern_recall_say _tern_recall_completers
_tern_recall_wrappers=(sudo env time nice nohup command exec caffeinate doas)

# The program being run, in REPLY, with its word index in $_tern_recall_at.
# Fails while the cursor is still on the program word.
_tern_recall_program() {
  REPLY=''
  local i w
  for (( i = 1; i < CURRENT; i++ )); do
    w=${words[i]}
    if [[ ${_tern_recall_wrappers[(Ie)$w]} -eq 0 && $w != *=* ]]; then
      REPLY=${w:t}
      _tern_recall_at=$i
      return 0
    fi
  done
  return 1
}

# The subcommand path before the word being completed, in REPLY. Only words the
# plugin would have learned build it — same charset, same length cap, no flags,
# no paths, no expansions — so a row stored under `compose up' is found after
# `docker compose -f docker/dev.yml up <Tab>' too.
_tern_recall_context() {
  setopt localoptions extendedglob
  local -a pre
  local i w
  for (( i = _tern_recall_at + 1; i < CURRENT; i++ )); do
    w=${words[i]}
    [[ $w != -* && $w == [[:alnum:]+_,.:@-]## && ${#w} -le 64 ]] || continue
    (( ${#pre[@]} < 2 )) && pre+=$w
  done
  REPLY=${(j: :)pre}
}

# The stored rows of one context, into $_tern_recall_tok / $_tern_recall_say,
# best first. Fails when the file has none for this context. A word already on
# the line is not offered again.
_tern_recall_rows() {
  _tern_recall_tok=()
  _tern_recall_say=()
  local file=$1 context=$2
  [[ -r $file ]] || return 1
  local -a typed
  local i
  if (( ${+words} )); then
    for (( i = _tern_recall_at + 1; i < CURRENT; i++ )); do
      typed+=$words[i]
    done
  fi
  local row_tok row_uses row_fails row_age row_score row_ctx days
  while IFS=$'\t' read -r row_tok row_uses row_fails row_age row_score row_ctx; do
    [[ $row_ctx == "$context" && -n $row_tok ]] || continue
    (( ${typed[(Ie)$row_tok]} == 0 )) || continue
    days=${row_age%%.*}
    if [[ $days == 0 ]]; then
      row_age='今天'
    else
      row_age="${days} 天前"
    fi
    _tern_recall_tok+=$row_tok
    # `word -- description' is zsh's own display convention for an array passed
    # with -d: plain zsh lists the whole string, and Tern's list strips the part
    # before ` -- ' into the row's dim detail next to the word.
    _tern_recall_say+="${row_tok} -- 用了 ${row_uses} 次 · ${row_age}"
  done <$file
  (( ${#_tern_recall_tok[@]} ))
}

# The completer. Returns 1 even after adding matches, so the ordinary completers
# still run underneath ours.
_tern_recall() {
  (( CURRENT > 1 )) || return 1

  _tern_recall_at=0
  _tern_recall_program || return 1
  local prog=$REPLY
  [[ -n $prog ]] || return 1

  _tern_recall_context
  _tern_recall_rows "$TERN_RECALL_DIR/learned/$prog" "$REPLY" || return 1

  # -V keeps the stored score order instead of sorting alphabetically; -X becomes
  # the group's heading in Tern's list.
  compadd -V tern-recall -X '常用参数' -d _tern_recall_say -a _tern_recall_tok
  return 1
}

# Register once, ahead of whatever completers are in play.
zstyle -a ':completion:*' completer _tern_recall_completers ||
  _tern_recall_completers=(_complete _ignored)
if [[ ${_tern_recall_completers[(Ie)_tern_recall]} -eq 0 ]]; then
  zstyle ':completion:*' completer _tern_recall $_tern_recall_completers
fi

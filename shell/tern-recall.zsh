# tern-recall — universal zsh argument learning & Tab completion.
#
# Works in every terminal (Ghostty, Tern, tty7, Otty, iTerm2, Alacritty, Kitty,
# WezTerm, tmux, SSH). Learns from commands you run via zsh's own `preexec' and
# `precmd' hooks, scores arguments by frequency, 14-day recency half-life and
# exit-status failure penalty, and leads Tab completion with `常用参数' ahead of
# standard zsh completers (`_complete', carapace, files).
#
# Source once from `~/.zshrc' (after `compinit'):
#
#   source /path/to/shell/tern-recall.zsh
#
# Data lives in plain text, one file per program:
#
#   ${TERN_RECALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/command-recall}/learned/<program>
#     <token>\t<uses>\t<fails>\t<last_used>\t<score>\t<context>

[[ -n ${ZSH_VERSION-} ]] || return 0

zmodload zsh/mathfunc 2>/dev/null || return 0
zmodload zsh/datetime 2>/dev/null || return 0
zmodload zsh/system 2>/dev/null || return 0
zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm 2>/dev/null || return 0
zmodload zsh/complist 2>/dev/null

: ${TERN_RECALL_DIR:=${COMMAND_RECALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/command-recall}}
export TERN_RECALL_DIR
typeset -g _tern_recall_self=${${(%):-%x}:A}
# Wrappers run another program, so the program is the next word.
typeset -ga _tern_recall_wrappers
typeset -ga _tern_recall_keywords
typeset -ga _tern_recall_splits
typeset -gi _tern_recall_at
typeset -ga _tern_recall_tok _tern_recall_completers
typeset -g _tern_recall_started=''

_tern_recall_wrappers=(sudo env time nice nohup command exec caffeinate doas)
_tern_recall_keywords=(
  if then else elif fi for while until do done case esac
  function return local typeset declare shift break continue recall
)
_tern_recall_splits=("|" ";" $'\n' "&&" "||")

# A program name the store may hold: a plain word, no path, no traversal.
_tern_recall_is_name() {
  local p=$1
  (( ${#p} >= 1 && ${#p} <= 40 )) || return 1
  [[ $p != *..* && $p == [[:alnum:]._+-]## ]]
}

# Options and subcommands yes; paths, globs, expansions, quotes and data no.
_tern_recall_interesting() {
  local tok=$1
  (( ${#tok} >= 1 && ${#tok} <= 64 )) || return 1
  [[ $tok != *[/%\*\$~\'\"\`\(\)\<\>\|\&\;\{\}\[\]!#=\ \\$'\t'$'\n']* ]] || return 1
  [[ $tok == -* || $tok == [[:alnum:]+_,.:@-]## ]]
}

# Ranking: sqrt-damped frequency over a 14-day recency half-life, times a
# failure penalty. Sets REPLY to the float score.
_tern_recall_score() {
  local -i n=$1 f=$2
  local -F days=$3
  (( days < 0.0 )) && days=0.0
  local -F recency=$(( 1.0 / (1.0 + days / 14.0) ))
  local -F denom=$(( n > 1 ? n : 1 ))
  local -F success=$(( 1.0 - 0.6 * (f / denom) ))
  REPLY=$(( sqrt(1.0 * n) * recency * success ))
}

# What one command line teaches: sets `reply' to an array of
# `<program>\t<context>\t<token>' strings.
_tern_recall_lessons() {
  emulate -L zsh
  setopt extendedglob
  local line=$1
  reply=()
  [[ -n $line ]] || return 0

  local -a raw_tokens seg ctx
  local t w prog tok
  local -i i n j after_flag learnable is_value

  raw_tokens=( ${(Z+n+)line} )
  seg=()
  for t in "${raw_tokens[@]}" ";"; do
    if (( ${_tern_recall_splits[(Ie)$t]} )); then
      if (( ${#seg[@]} )); then
        i=1
        n=${#seg[@]}
        while (( i <= n )); do
          w=${seg[i]}
          if (( ${_tern_recall_wrappers[(Ie)$w]} )) || [[ $w == [A-Za-z_][A-Za-z0-9_]*=* ]]; then
            (( i++ ))
          else
            break
          fi
        done
        if (( i <= n )); then
          prog=${seg[i]:t}
          if _tern_recall_is_name "$prog" && (( ${_tern_recall_keywords[(Ie)$prog]} == 0 )); then
            ctx=()
            after_flag=0
            for (( j = i + 1; j <= n; j++ )); do
              tok=${seg[j]}
              _tern_recall_interesting "$tok" && learnable=1 || learnable=0
              (( after_flag && ${#ctx[@]} == 0 )) && [[ $tok != -* ]] && is_value=1 || is_value=0
              if (( learnable && !is_value )); then
                reply+=("${prog}"$'\t'"${(j: :)ctx}"$'\t'"${tok}")
              fi
              if (( learnable && !is_value )) && [[ $tok != -* ]] && (( ${#ctx[@]} < 2 )); then
                ctx+=("$tok")
              fi
              if (( learnable )) && [[ $tok == -* ]]; then
                after_flag=1
              else
                after_flag=0
              fi
            done
          fi
        fi
        seg=()
      fi
    else
      seg+=("$t")
    fi
  done
}

# Fold one command line into `$TERN_RECALL_DIR/learned/<program>'.
# Usage: _tern_recall_learn <line> [status=0] [penalty_only=0] [now=$EPOCHSECONDS]
_tern_recall_learn() {
  emulate -L zsh
  setopt extendedglob
  local line=$1
  local -i status_code=${2:-0} penalty_only=${3:-0} now=${4:-$EPOCHSECONDS}
  [[ -n $line ]] || return 1

  _tern_recall_lessons "$line"
  (( ${#reply[@]} )) || return 1
  local -a lessons=( "${reply[@]}" )

  local -A dirty_progs=()
  local item prog rest ctx tok k file tmpfile lockfile lockfd row_str s
  local r_tok r_u r_f r_ts r_score r_ctx
  local -F sc days
  local -i u_val f_val ts_val
  local -a sortable sorted out_lines
  local -A u_map f_map c_map t_map ts_map

  for item in "${lessons[@]}"; do
    prog=${item%%$'\t'*}
    dirty_progs[$prog]=1
  done

  [[ -d "$TERN_RECALL_DIR/learned" ]] || zf_mkdir -p "$TERN_RECALL_DIR/learned" 2>/dev/null || return 1

  for prog in "${(@k)dirty_progs}"; do
    file="$TERN_RECALL_DIR/learned/$prog"
    lockfile="${file}.lock"
    [[ -e $lockfile ]] || : >> "$lockfile" 2>/dev/null
    lockfd=''
    zsystem flock -t 2 -f lockfd "$lockfile" 2>/dev/null || continue
    {
      u_map=() f_map=() c_map=() t_map=() ts_map=()
      if [[ -r $file ]]; then
        while IFS=$'\t' read -r r_tok r_u r_f r_ts r_score r_ctx; do
          [[ -n $r_tok ]] || continue
          k="${r_ctx}"$'\1'"${r_tok}"
          u_map[$k]=$(( r_u ))
          f_map[$k]=$(( r_f ))
          ts_map[$k]=$(( r_ts ))
          c_map[$k]=$r_ctx
          t_map[$k]=$r_tok
        done < "$file"
      fi

      for item in "${lessons[@]}"; do
        [[ ${item%%$'\t'*} == "$prog" ]] || continue
        rest=${item#*$'\t'}
        ctx=${rest%%$'\t'*}
        tok=${rest#*$'\t'}
        k="${ctx}"$'\1'"${tok}"
        if (( penalty_only )); then
          if (( ${+u_map[$k]} && status_code != 0 )); then
            f_map[$k]=$(( f_map[$k] + 1 ))
          fi
        else
          u_map[$k]=$(( ${u_map[$k]:-0} + 1 ))
          if (( status_code != 0 )); then
            f_map[$k]=$(( ${f_map[$k]:-0} + 1 ))
          else
            f_map[$k]=$(( ${f_map[$k]:-0} ))
          fi
          ts_map[$k]=$now
          c_map[$k]=$ctx
          t_map[$k]=$tok
        fi
      done

      sortable=()
      for k in "${(@k)u_map}"; do
        u_val=${u_map[$k]}
        f_val=${f_map[$k]}
        ts_val=${ts_map[$k]}
        tok=${t_map[$k]}
        ctx=${c_map[$k]}
        days=$(( (now - ts_val) / 86400.0 ))
        (( days < 0.0 )) && days=0.0
        _tern_recall_score $u_val $f_val $days
        sc=$REPLY
        builtin printf -v row_str "%012.6f\t%s\1%s\t%d\t%d\t%d\t%.4f\t%s" \
          $(( 99999.0 - sc )) "$tok" "$tok" "$u_val" "$f_val" "$ts_val" "$sc" "$ctx"
        sortable+=("$row_str")
      done

      sorted=( "${(@o)sortable}" )
      out_lines=()
      for s in "${sorted[@]:0:200}"; do
        out_lines+=("${s#*$'\1'}")
      done
      tmpfile="${file}.tmp.$$"
      if (( ${#out_lines[@]} )); then
        builtin print -rl -- "${out_lines[@]}" >| "$tmpfile" 2>/dev/null &&
          zf_mv -f "$tmpfile" "$file" 2>/dev/null
      fi
    } always {
      [[ -n $lockfd ]] && zsystem flock -u $lockfd 2>/dev/null
    }
  done
  return 0
}

# One-time import of the shell's own history so day one is not empty.
# Usage: _tern_recall_import_history [histfile] [now=$EPOCHSECONDS]
_tern_recall_import_history() {
  emulate -L zsh
  setopt extendedglob
  local histfile=${1:-${HISTFILE:-$HOME/.zsh_history}}
  local -i now=${2:-$EPOCHSECONDS}
  local mark="$TERN_RECALL_DIR/history-imported"
  [[ -d "$TERN_RECALL_DIR/learned" ]] || zf_mkdir -p "$TERN_RECALL_DIR/learned" 2>/dev/null || return 1
  if [[ ! -r $histfile ]]; then
    builtin print -r -- "no .zsh_history" >| "$mark" 2>/dev/null
    return 0
  fi

  local -a lines
  lines=( "${(@f)$(<$histfile)}" )
  local -i count=0 when
  local -i undated=$(( now - 30 * 86400 ))
  local line cmd ts rest item prog ctx tok gk
  local -A u_all=() ts_all=() by_prog=()

  for line in "${lines[@]}"; do
    (( count >= 8000 )) && break
    if [[ $line == ": "<->:<->";"* ]]; then
      rest=${line#": "}
      ts=${rest%%:*}
      cmd=${rest#*;}
      when=$(( ts ))
    else
      cmd=$line
      when=$undated
    fi
    [[ -n $cmd && $cmd != *\\ && ${#cmd} -le 2000 ]] || continue
    [[ $cmd != *$'\203'* && $cmd != *tern-recall* && $cmd != *recall-probe* ]] || continue
    _tern_recall_lessons "$cmd"
    (( ${#reply[@]} )) || continue
    (( count++ ))
    for item in "${reply[@]}"; do
      prog=${item%%$'\t'*}
      rest=${item#*$'\t'}
      ctx=${rest%%$'\t'*}
      tok=${rest#*$'\t'}
      gk="${prog}"$'\1'"${ctx}"$'\1'"${tok}"
      if (( ! ${+u_all[$gk]} )); then
        by_prog[$prog]+="${gk}"$'\n'
      fi
      u_all[$gk]=$(( ${u_all[$gk]:-0} + 1 ))
      if (( when > ${ts_all[$gk]:-0} )); then
        ts_all[$gk]=$when
      fi
    done
  done

  local -a sortable sorted out_lines
  local -F days sc
  local -i u_val ts_val
  local row_str s file tmpfile
  for prog in "${(@k)by_prog}"; do
    sortable=()
    for gk in "${(@f)by_prog[$prog]}"; do
      [[ -n $gk ]] || continue
      rest=${gk#*$'\1'}
      ctx=${rest%%$'\1'*}
      tok=${rest#*$'\1'}
      u_val=${u_all[$gk]}
      ts_val=${ts_all[$gk]}
      days=$(( (now - ts_val) / 86400.0 ))
      (( days < 0.0 )) && days=0.0
      _tern_recall_score $u_val 0 $days
      sc=$REPLY
      builtin printf -v row_str "%012.6f\t%s\1%s\t%d\t0\t%d\t%.4f\t%s" \
        $(( 99999.0 - sc )) "$tok" "$tok" "$u_val" "$ts_val" "$sc" "$ctx"
      sortable+=("$row_str")
    done
    sorted=( "${(@o)sortable}" )
    out_lines=()
    for s in "${sorted[@]:0:200}"; do
      out_lines+=("${s#*$'\1'}")
    done
    if (( ${#out_lines[@]} )); then
      file="$TERN_RECALL_DIR/learned/$prog"
      tmpfile="${file}.tmp.$$"
      builtin print -rl -- "${out_lines[@]}" >| "$tmpfile" 2>/dev/null &&
        zf_mv -f "$tmpfile" "$file" 2>/dev/null
    fi
  done

  builtin print -r -- "$count commands" >| "$mark" 2>/dev/null
  return 0
}

# Remember a command as soon as it starts so long/interactive runs are
# immediately completable in sibling panes; precmd only records a failure mark.
_tern_recall_preexec() {
  local line=${1-}
  [[ -n $line ]] || return 0
  _tern_recall_started=$line
  _tern_recall_learn "$line" 0 0
}

_tern_recall_precmd() {
  local -i ret=$?
  local line=$_tern_recall_started
  _tern_recall_started=''
  if [[ -n $line ]] && (( ret != 0 )); then
    _tern_recall_learn "$line" $ret 1
  fi
}

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

# The subcommand path before the word being completed, in REPLY.
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

# The stored rows of one context, into $_tern_recall_tok, best first. Fails when
# the file has none for this context. A word already on the line is not offered
# again. Rows carry no description: the list shows the words alone.
_tern_recall_rows() {
  _tern_recall_tok=()
  local file=$1 context=$2
  [[ -r $file ]] || return 1
  local -a typed
  local i
  if (( ${+words} )); then
    for (( i = _tern_recall_at + 1; i < CURRENT; i++ )); do
      typed+=$words[i]
    done
  fi
  local row_tok row_uses row_fails row_ts row_score row_ctx
  while IFS=$'\t' read -r row_tok row_uses row_fails row_ts row_score row_ctx; do
    [[ $row_ctx == "$context" && -n $row_tok ]] || continue
    (( ${typed[(Ie)$row_tok]} == 0 )) || continue
    _tern_recall_tok+=$row_tok
  done <$file
  (( ${#_tern_recall_tok[@]} ))
}

# Drops duplicate words that the later completers also added to Tern's list
# (`_tern_cmp_*' in tern-complete), keeping our `常用参数' entry first.
_tern_recall_post() {
  (( ${+_tern_cmp_w} && $#_tern_cmp_w > 1 )) || return 0
  local -A seen
  local -a hit w d g k s c
  local i j word
  for (( i = 1; i <= $#_tern_cmp_w; i++ )); do
    word=${_tern_cmp_w[i]}
    if (( ${+seen[$word]} )); then
      j=${seen[$word]}
      [[ ${k[j]} == other && -n ${_tern_cmp_k[i]} ]] && k[j]=${_tern_cmp_k[i]}
      [[ -z ${s[j]} && -n ${_tern_cmp_s[i]} ]] && s[j]=${_tern_cmp_s[i]}
      continue
    fi
    hit+=("${_tern_cmp_hit[i]}")
    w+=("$word")
    d+=("${_tern_cmp_d[i]}")
    g+=("${_tern_cmp_g[i]}")
    k+=("${_tern_cmp_k[i]}")
    s+=("${_tern_cmp_s[i]}")
    c+=("${_tern_cmp_c[i]}")
    seen[$word]=${#w}
  done
  _tern_cmp_hit=("${hit[@]}")
  _tern_cmp_w=("${w[@]}")
  _tern_cmp_d=("${d[@]}")
  _tern_cmp_g=("${g[@]}")
  _tern_cmp_k=("${k[@]}")
  _tern_cmp_s=("${s[@]}")
  _tern_cmp_c=("${c[@]}")
  if (( $#_tern_cmp_w == 1 )); then
    compstate[list]=''
    compstate[insert]=1
    [[ ${RBUFFER-} == ' '* ]] || compstate[insert]+=' '
  fi
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

  (( ${+comppostfuncs} )) && comppostfuncs+=(_tern_recall_post)

  local heading='常用参数'
  if [[ ${TERN_COMPLETE-} != 1 ]]; then
    heading='%F{6}── 常用参数 ──%f'
  fi
  compadd -V tern-recall -X "$heading" -a _tern_recall_tok
  return 1
}

# Terminal-agnostic inspector & picker (`recall' or `recall <program>').
recall() {
  emulate -L zsh
  setopt extendedglob nullglob
  local dir="$TERN_RECALL_DIR/learned"
  if [[ ${1-} == --import ]]; then
    _tern_recall_import_history "${2:-${HISTFILE:-$HOME/.zsh_history}}"
    return $?
  fi
  if [[ ${1-} == --install ]]; then
    _tern_recall_install_zshrc "${2-}" "${3-}"
    return $?
  fi

  if [[ -n ${1-} && ${1-} != --list ]]; then
    local prog=$1 file="$dir/$1"
    [[ -r $file ]] || {
      builtin print -ru2 -- "recall: 还没有学到 $prog 的参数"
      return 1
    }
    local r_tok r_u r_f r_ts r_score r_ctx line_cmd
    local -i n=0
    while IFS=$'\t' read -r r_tok r_u r_f r_ts r_score r_ctx; do
      [[ -n $r_tok ]] || continue
      if [[ -n $r_ctx ]]; then
        line_cmd="$prog $r_ctx $r_tok"
      else
        line_cmd="$prog $r_tok"
      fi
      builtin print -r -- "$line_cmd"
      (( ++n >= 40 )) && break
    done < "$file"
    return 0
  fi

  local -a files=( "$dir"/*(N.) )
  if (( ${#files[@]} == 0 )); then
    builtin print -r -- "还没有学到命令 — 在终端里敲几条命令，再按 Tab 看看"
    return 0
  fi

  local -a summary=()
  local f name r_tok r_u r_f r_age r_score r_ctx
  local -a top
  for f in "${(@o)files}"; do
    name=${f:t}
    top=()
    while IFS=$'\t' read -r r_tok r_u r_f r_age r_score r_ctx; do
      [[ -n $r_tok ]] || continue
      top+=("$r_tok")
      (( ${#top[@]} >= 3 )) && break
    done < "$f"
    (( ${#top[@]} )) && summary+=("${name}"$'\t'"${(j:  :)top}")
  done

  if [[ ${1-} != --list && -o interactive && -t 0 && -t 1 ]] && command -v fzf >/dev/null 2>&1; then
    local chosen_prog chosen_line
    chosen_prog=$(builtin print -rl -- "${summary[@]}" | fzf --delimiter=$'\t' --with-nth=1,2 --prompt="选一个命令 > ") || return 0
    chosen_prog=${chosen_prog%%$'\t'*}
    [[ -n $chosen_prog ]] || return 0
    chosen_line=$(recall "$chosen_prog" | fzf --prompt="插入这条命令 > ") || return 0
    [[ -n $chosen_line ]] && builtin print -z -- "$chosen_line"
    return 0
  fi

  builtin print -rl -- "${summary[@]}"
}

# Safe, locked `.zshrc' installer with cross-plugin idempotency (recognises
# both the Tern plugin copy and the standalone Shell plugin copy so installing
# both never duplicates or overwrites a valid existing entry).
# Usage: _tern_recall_install_zshrc [zshrc_path] [script_path]
_tern_recall_install_zshrc() {
  emulate -L zsh
  setopt extendedglob
  local raw_zshrc=${1:-${ZDOTDIR:-$HOME}/.zshrc}
  local script_path=${2:-$_tern_recall_self}
  local zshrc=$raw_zshrc
  [[ -L $raw_zshrc ]] && zshrc=${raw_zshrc:A}

  local zdir=${zshrc:h}
  [[ -d $zdir ]] || zf_mkdir -p "$zdir" 2>/dev/null || return 1
  [[ -d $TERN_RECALL_DIR ]] || zf_mkdir -p "$TERN_RECALL_DIR" 2>/dev/null || return 1

  local lockfile="$TERN_RECALL_DIR/zshrc.lock" lockfd=''
  [[ -e $lockfile ]] || : >> "$lockfile" 2>/dev/null
  zsystem flock -t 2 -f lockfd "$lockfile" 2>/dev/null || return 1
  {
    local begin_mark="# >>> Tern command-recall >>>"
    local end_mark="# <<< Tern command-recall <<<"
    local alt_begin="# >>> command-recall >>>"
    local alt_end="# <<< command-recall <<<"
    local source_line="[ -r \"$script_path\" ] && . \"$script_path\""
    local -a block_lines=(
      "$begin_mark"
      "# Tab lists the arguments you actually use across every terminal."
      "# Delete this block to turn the feature off."
      "$source_line"
      "$end_mark"
    )

    if [[ ! -e $zshrc ]]; then
      builtin print -rl -- "${block_lines[@]}" >| "$zshrc" 2>/dev/null || return 1
      builtin print -r -- "$script_path" >| "$TERN_RECALL_DIR/zshrc-configured" 2>/dev/null
      builtin print -r -- "installed"
      return 0
    fi

    local content
    content=$(<"$zshrc")
    local -a lines
    lines=( "${(@f)content}" )

    local -i has_block=0 in_block=0 needs_upgrade=0 has_active_ref=0
    local line quoted_path expanded_path
    for line in "${lines[@]}"; do
      if [[ $line == "$begin_mark" || $line == "$alt_begin" ]]; then
        has_block=1
        in_block=1
        continue
      fi
      if (( in_block )); then
        if [[ $line == "$end_mark" || $line == "$alt_end" ]]; then
          in_block=0
          continue
        fi
        [[ $line == [[:space:]]#\#* || -z ${line//[[:space:]]/} ]] && continue
        if [[ $line == *'$TERN_RECALL_DIR/tern-recall.zsh'* ]]; then
          needs_upgrade=1
        elif [[ $line == *\"*\"* ]]; then
          quoted_path=${${line#*\"}%%\"*}
          expanded_path=${quoted_path/#\$HOME/$HOME}
          expanded_path=${expanded_path/#\$\{HOME\}/$HOME}
          expanded_path=${expanded_path/#\~/$HOME}
          if [[ -r $expanded_path ]]; then
            has_active_ref=1
          else
            needs_upgrade=1
          fi
        fi
        continue
      fi
      [[ $line == [[:space:]]#\#* ]] && continue
      if [[ $line == *(tern-recall\.zsh|command-recall\.zsh|command-recall\.plugin\.zsh|tern-command-recall)* ]]; then
        has_active_ref=1
      fi
    done

    if (( has_active_ref && ! needs_upgrade )); then
      builtin print -r -- "$script_path" >| "$TERN_RECALL_DIR/zshrc-configured" 2>/dev/null
      builtin print -r -- "already-installed"
      return 0
    fi

    if (( has_block && needs_upgrade )); then
      command cp -p "$zshrc" "${zshrc}.bak" 2>/dev/null
      local -a out=()
      local -i replaced=0
      in_block=0
      for line in "${lines[@]}"; do
        if [[ $line == "$begin_mark" || $line == "$alt_begin" ]]; then
          in_block=1
          if (( ! replaced )); then
            out+=( "${block_lines[@]}" )
            replaced=1
          fi
          continue
        fi
        if (( in_block )); then
          [[ $line == "$end_mark" || $line == "$alt_end" ]] && in_block=0
          continue
        fi
        out+=("$line")
      done
      local tmpfile="${zshrc}.tmp.$$"
      command cp -p "$zshrc" "$tmpfile" 2>/dev/null
      builtin print -rl -- "${out[@]}" >| "$tmpfile" 2>/dev/null &&
        zf_mv -f "$tmpfile" "$zshrc" 2>/dev/null || return 1
      builtin print -r -- "$script_path" >| "$TERN_RECALL_DIR/zshrc-configured" 2>/dev/null
      builtin print -r -- "upgraded"
      return 0
    fi

    command cp -p "$zshrc" "${zshrc}.bak" 2>/dev/null
    {
      builtin print -r -- ""
      builtin print -rl -- "${block_lines[@]}"
    } >> "$zshrc" 2>/dev/null || return 1
    builtin print -r -- "$script_path" >| "$TERN_RECALL_DIR/zshrc-configured" 2>/dev/null
    builtin print -r -- "installed"
    return 0
  } always {
    [[ -n $lockfd ]] && zsystem flock -u $lockfd 2>/dev/null
  }
}

if [[ ${ZSH_EVAL_CONTEXT-} == toplevel && ${1-} == --install ]]; then
  _tern_recall_install_zshrc "${2-}" "${3-}" || exit 1
  [[ -e "$TERN_RECALL_DIR/history-imported" ]] || _tern_recall_import_history
  exit 0
fi

# zsh rings its bell whenever it displays a completion list (LIST_BEEP); with a
# visual bell the terminal renders that as a screen flash on the first Tab. This
# plugin adds a group to every completion, so that bell fires constantly. Turn it
# off: the list, the menu and the ranking are untouched, only the bell goes away.
unsetopt listbeep

# Register hooks once.
typeset -ga preexec_functions precmd_functions
if (( ${preexec_functions[(Ie)_tern_recall_preexec]} == 0 )); then
  preexec_functions+=(_tern_recall_preexec)
fi
if (( ${precmd_functions[(Ie)_tern_recall_precmd]} == 0 )); then
  precmd_functions=(_tern_recall_precmd "${precmd_functions[@]}")
fi

# Register completer once, ahead of whatever completers are in play.
zstyle -a ':completion:*' completer _tern_recall_completers ||
  _tern_recall_completers=(_complete _ignored)
if [[ ${_tern_recall_completers[(Ie)_tern_recall]} -eq 0 ]]; then
  zstyle ':completion:*' completer _tern_recall $_tern_recall_completers
fi

# Default grouping and interactive menu styling for standard terminals (Ghostty,
# iTerm2, Alacritty, tty7/Otty shell Tab) when not inside Tern's popup and when
# the user has not set their own.
if [[ ${TERN_COMPLETE-} != 1 ]]; then
  typeset -g _tern_recall_style
  zstyle -s ':completion:*' group-name _tern_recall_style ||
    zstyle ':completion:*' group-name ''
  zstyle -s ':completion:*:descriptions' format _tern_recall_style ||
    zstyle ':completion:*:descriptions' format '%F{8}── %d ──%f'
  zstyle -s ':completion:*' menu _tern_recall_style ||
    zstyle ':completion:*' menu select
  # Past LISTMAX (100 by default) zsh draws nothing on the first Tab and only asks
  # `do you wish to see all N possibilities (M lines)?' — one wasted keypress, and this
  # plugin's own group only makes long lists longer. LISTMAX is "how many matches to list
  # without asking first", so raising it above any real list makes one Tab render every
  # match. Measured with 141 matches in a 24-line window: 0 asks (it only stays quiet
  # while the listing fits the screen), -1 happens not to ask although zshparam documents
  # a negative value as "the list will be shown if it spans at most as many lines as given
  # by the absolute value", i.e. -1 should ask — that docs/code gap is why this raises the
  # number instead. zsh pre-sets LISTMAX to 100, so "is it set" proves nothing: only a
  # value the user moved off that default counts as theirs. `list-prompt' stays untouched —
  # any value there, the empty string included, switches zsh back to its paging list.
  [[ ${LISTMAX} == 100 ]] && LISTMAX=100000
  unset _tern_recall_style
fi
if [[ -o interactive && ! -e "$TERN_RECALL_DIR/history-imported" ]]; then
  _tern_recall_import_history
fi

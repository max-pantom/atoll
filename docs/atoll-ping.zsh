# Atoll: ping the island when a command runs longer than ATOLL_PING_MIN seconds.
# Add to ~/.zshrc:   source /path/to/atoll-ping.zsh
# Needs the `atoll` command on PATH, e.g.
#   ln -s /Applications/Atoll.app/Contents/Resources/atoll /usr/local/bin/atoll

: ${ATOLL_PING_MIN:=10}
zmodload zsh/datetime 2>/dev/null

_atoll_preexec() {
  _atoll_cmd="$1"
  _atoll_start=$EPOCHSECONDS
}

_atoll_precmd() {
  local code=$?
  [[ -z "$_atoll_start" ]] && return
  local took=$(( EPOCHSECONDS - _atoll_start ))
  _atoll_start=
  (( took < ATOLL_PING_MIN )) && return
  local st=ok
  (( code != 0 )) && st=fail
  command -v atoll >/dev/null || return
  atoll notify "${_atoll_cmd[(w)1]}" "${took}s, exit ${code}" "$st" &>/dev/null &!
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _atoll_preexec
add-zsh-hook precmd _atoll_precmd

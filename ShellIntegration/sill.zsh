# Sill shell integration — streams the ZLE edit buffer to Sill.app over a
# unix socket so it can show completions, and applies the insertions Sill
# sends back. Installed by the app as one `source` line in ~/.zshrc.
#
# Protocol (newline-delimited JSON, one connection per shell session):
#   → {"t":"hello","v":1,"sid":…,"pid":…,"tty":…,"term":…,"dark":…,"path":…}
#     ("path" — $PATH, so the app can find a command's executable when it
#     learns an unknown command from its --help; the app never runs a shell)
#     ("dark" — whether the terminal's background is dark, from an OSC 11
#     query answered by Terminal.app and iTerm2; absent when unanswered, and
#     the popup then follows the system appearance)
#   → {"t":"buf","sid":…,"buf":…,"cur":…,"pwd":…,"cols":…,"rows":…}
#     (caret coordinates come from Accessibility on the app side — reading
#     the terminal's CPR reply inside a ZLE widget corrupts ZLE's terminal
#     state and kills every later hook, so the shell sends no cell anchor…)
#     …except for Ghostty and cmux, whose accessibility tree has no caret:
#     there the message also carries "row","col" (the cell where the buffer
#     starts) and "cellw","cellh","tw","th" (cell and text-area size in
#     pixels), measured in precmd — OUTSIDE ZLE, where a raw read is safe —
#     with CPR and XTWINOPS 16/14. Keys typed ahead of the prompt that the
#     read swallows are handed back to ZLE at line-init.
#   → {"t":"key","sid":…,"key":…}                (steering key while popup up)
#   → {"t":"end","sid":…}                       (line accepted/aborted — hide)
#   ← {"t":"insert","del":N,"text":…}            (replace the partial token)
#   ← {"t":"popup","visible":…,"nav":…}          (bind/unbind steering keys)
#
# Steering keys (Tab, arrows, Return, Esc) are consumed HERE, as ZLE
# widgets bound only while the popup is visible: the shell receives keys
# regardless of Secure Keyboard Entry, so — like Fig's figterm — Sill
# never needs to observe the keyboard at the window-server level.

# Only interactive local shells in the terminals Sill positions against.
[[ -o interactive ]] || return 0
[[ -n "$SSH_TTY" || -n "$SSH_CONNECTION" ]] && return 0  # generators would run locally and lie
[[ -n "$TMUX" ]] && return 0                             # pane-relative rows break positioning
case "$TERM_PROGRAM" in
    Apple_Terminal|iTerm.app|vscode) ;;
    ghostty|cmux) ;;
    *) return 0 ;;
esac

zmodload zsh/net/socket 2>/dev/null || return 0
autoload -Uz add-zle-hook-widget add-zsh-hook

typeset -g _sill_fd=-1
typeset -g _sill_sid="$$-${RANDOM}${RANDOM}"
typeset -g _sill_dead=0        # connect failed this prompt; retry next precmd
typeset -g _sill_last=""       # last sent buffer+cursor, for dedup
typeset -g _sill_popup=0       # the app's popup is on screen
typeset -g _sill_nav=0         # user has arrow-navigated (gates Return)
typeset -g _sill_bound=0
typeset -gA _sill_saved_bindings
typeset -g _sill_saved_keytimeout=""
typeset -g _sill_registered=0  # zle -F registration needs a live ZLE

_sill_sock="$HOME/Library/Application Support/Sill/sill.sock"

# Grid terminals (no accessibility caret): geometry the app needs, refreshed
# every prompt by _sill_measure_grid.
typeset -g _sill_grid=0
[[ "$TERM_PROGRAM" == (ghostty|cmux) ]] && _sill_grid=1
typeset -g _sill_row=0 _sill_col=0 _sill_cellw=0 _sill_cellh=0 _sill_tw=0 _sill_th=0
typeset -g _sill_grid_misses=0  # give up only after a few silent prompts
typeset -g _sill_typeahead=""

# Asks the terminal for its background color (OSC 11), the cell size (CSI 16
# t), the text-area size (CSI 14 t) and the cursor position (CSI 6 n) in one
# round trip — replies come back in order, so the CPR that ends the read
# proves the others were consumed — then works out
# where the buffer will start once the prompt is drawn: the CPR cell moved
# right by the prompt's last line (display width, escapes stripped) and down
# by the lines it spans. Anything read that isn't one of the replies was
# typed ahead of the prompt and is kept for ZLE. A terminal that doesn't
# answer within 300ms is not asked again this session.
_sill_measure_grid() {
    (( _sill_grid )) || return 0
    setopt localoptions extendedglob
    _sill_ask_tty $'\e]11;?\a\e[16t\e[14t\e[6n' "*$'\e['[0-9]##\;[0-9]##R"
    local reply=$_sill_reply
    if [[ "$reply" != *R ]]; then
        # A terminal busy with its own startup can miss the first prompt;
        # only one that never answers is written off.
        (( ++_sill_grid_misses >= 3 )) && _sill_grid=0
        _sill_parse_background "$reply"
        _sill_typeahead+=$(_sill_strip_replies "$reply")
        _sill_grid_debug "no CPR reply"
        return 0
    fi
    _sill_grid_misses=0
    _sill_parse_background "$reply"
    local -a m
    if [[ "$reply" == (#b)*$'\e[6;'([0-9]##)\;([0-9]##)t* ]]; then
        _sill_cellh=$match[1] _sill_cellw=$match[2]
    fi
    if [[ "$reply" == (#b)*$'\e[4;'([0-9]##)\;([0-9]##)t* ]]; then
        _sill_th=$match[1] _sill_tw=$match[2]
    fi
    if [[ "$reply" == (#b)*$'\e['([0-9]##)\;([0-9]##)R* ]]; then
        _sill_row=$match[1] _sill_col=$match[2]
    fi
    _sill_typeahead+=$(_sill_strip_replies "$reply")

    # The prompt as it will render: escapes out, then width of its last line.
    local p=${(%%)PROMPT}
    p=${p//$'\e'\[[0-9\;?]#[[:alpha:]]/}
    p=${p//$'\e'\][^$'\a']#$'\a'/}
    local newlines=${#${p//[^$'\n']/}}
    local last=${p##*$'\n'}
    if (( newlines > 0 )); then
        _sill_col=$(( 1 + ${(m)#last} ))
    else
        _sill_col=$(( _sill_col + ${(m)#last} ))
    fi
    _sill_row=$(( _sill_row + newlines ))
    (( _sill_row > LINES )) && _sill_row=$LINES
    _sill_grid_debug "prompt=[$last]"
}

# Diagnosing a new terminal means seeing what it answered, in a shell that
# terminal itself started (no env var can reach it) — so: create
# ~/.sill-grid-debug and every measurement lands in /tmp/sill-grid.log.
_sill_grid_debug() {
    [[ -f "$HOME/.sill-grid-debug" ]] || return 0
    print -r -- "$(date +%T) $TERM_PROGRAM $1 reply=[${reply//$'\e'/^[}]" \
        "row=$_sill_row col=$_sill_col cell=${_sill_cellw}x${_sill_cellh}" \
        "text=${_sill_tw}x${_sill_th} grid=${COLUMNS}x${LINES} dark=$_sill_dark" \
        >> /tmp/sill-grid.log
}

# Ask the terminal for its background color (OSC 11) so the popup can match
# a dark terminal on a light system and vice versa. Done ONCE here, at load,
# before ZLE exists: reading the tty inside a widget corrupts ZLE, and
# reading it in precmd could swallow keys typed ahead of the prompt. The
# reply is "\e]11;rgb:RRRR/GGGG/BBBB" ended by BEL or ESC-\; anything else
# (no reply within 200ms) leaves the appearance to the system.
typeset -g _sill_dark=""
_sill_query_background() {
    _sill_ask_tty $'\e]11;?\a' "*($'\a'|$'\e'\\\\)" || return 0
    _sill_parse_background "$_sill_reply"
}

# Asks the terminal something and reads its answer with the tty held in
# raw, no-echo mode for the WHOLE exchange. Reading a character at a time
# is not enough: between two `read -k` calls the line discipline is back in
# canonical mode with echo on, so a reply arriving in that window is printed
# on screen (the stray "^[]11;rgb:…" line) even though we do go on to read
# it. Terminals answer a few milliseconds late, which lands squarely in that
# window. Sets _sill_reply; fails when the tty can't be queried.
typeset -g _sill_reply=""
_sill_ask_tty() {
    setopt localoptions extendedglob
    local query=$1 terminator=$2 saved ch
    _sill_reply=""
    [[ -t 0 && -t 1 ]] || return 1
    saved=$(stty -g 2>/dev/null) || return 1
    # min 0 time 3: a read with nothing to take returns empty after 0.3s
    # instead of blocking, so an unanswering terminal costs one timeout.
    stty -echo -icanon min 0 time 3 2>/dev/null
    print -n -- "$query"
    while read -rs -t 0.3 -k 1 ch; do
        _sill_reply+=$ch
        [[ "$_sill_reply" == ${~terminator} ]] && break
    done
    stty "$saved" 2>/dev/null
    [[ -n "$_sill_reply" ]]
}

# What is left of a read once the terminal's own answers (the OSC 11 colour,
# terminated by BEL or ST, and the CSI window/cursor reports) are taken out:
# bytes the user typed ahead of the prompt, which belong to ZLE.
_sill_strip_replies() {
    setopt localoptions extendedglob
    local rest=$1
    rest=${rest//$'\e'\]11\;[^$'\a']#$'\a'/}
    rest=${rest//$'\e'\]11\;*$'\e\\'/}
    print -rn -- ${rest//$'\e'\[[0-9\;]#[tR]/}
}

# Sets _sill_dark from an OSC 11 reply ("…rgb:RRRR/GGGG/BBBB" + terminator).
_sill_parse_background() {
    local reply=$1
    local rgb="${reply##*rgb:}"
    [[ "$rgb" == "$reply" ]] && return 0
    rgb="${rgb%%[$'\a'$'\e']*}"
    local r="${rgb%%/*}" rest="${rgb#*/}"
    local g="${rest%%/*}" b="${rest#*/}"
    b="${b%%[^0-9A-Fa-f]*}"
    [[ -n "$r" && -n "$g" && -n "$b" ]] || return 0
    # Components are 1–4 hex digits; scale each to 0–255 by its own width.
    local -i R=$(( 16#$r * 255 / (16 ** ${#r} - 1) ))
    local -i G=$(( 16#$g * 255 / (16 ** ${#g} - 1) ))
    local -i B=$(( 16#$b * 255 / (16 ** ${#b} - 1) ))
    local -i luma=$(( (2126 * R + 7152 * G + 722 * B) / 10000 ))
    (( luma < 128 )) && _sill_dark=true || _sill_dark=false
}
# Grid terminals fold this query into their precmd round trip instead (one
# read, and the CPR reply that ends it proves this one was consumed too —
# Ghostty answers late enough at startup that a separate query here times
# out and the reply is left to be echoed at the first prompt).
(( _sill_grid )) || _sill_query_background

# JSON string escaping in plain zsh: backslash first, then quote, then the
# whitespace controls; any remaining C0 bytes are stripped.
_sill_esc() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//[[:cntrl:]]/}
    print -rn -- "$s"
}

_sill_connect() {
    (( _sill_fd >= 0 )) && return 0
    (( _sill_dead )) && return 1
    if ! zsocket "$_sill_sock" 2>/dev/null; then
        _sill_dead=1
        return 1
    fi
    _sill_fd=$REPLY
    print -u $_sill_fd -r -- \
        "{\"t\":\"hello\",\"v\":1,\"sid\":\"$_sill_sid\",\"pid\":$$,\"tty\":\"$(_sill_esc "$TTY")\",\"term\":\"$(_sill_esc "$TERM_PROGRAM")\"${_sill_dark:+,\"dark\":$_sill_dark},\"path\":\"$(_sill_esc "$PATH")\"}" \
        2>/dev/null || _sill_disconnect
}

_sill_disconnect() {
    (( _sill_fd >= 0 )) || return 0
    (( _sill_registered )) && zle -F $_sill_fd 2>/dev/null
    exec {_sill_fd}>&- 2>/dev/null
    _sill_fd=-1
    _sill_registered=0
    _sill_dead=1
}

_sill_send() {
    (( _sill_fd >= 0 )) || return 0
    print -u $_sill_fd -r -- "$1" 2>/dev/null || _sill_disconnect
}

_sill_send_buf() {
    (( _sill_fd >= 0 )) || return 0
    local state="$BUFFER"$'\x1f'"$CURSOR"
    [[ "$state" == "$_sill_last" ]] && return 0
    _sill_last=$state
    local grid=""
    (( _sill_grid )) && grid=",\"row\":$_sill_row,\"col\":$_sill_col,\"cellw\":$_sill_cellw,\"cellh\":$_sill_cellh,\"tw\":$_sill_tw,\"th\":$_sill_th"
    _sill_send "{\"t\":\"buf\",\"sid\":\"$_sill_sid\",\"buf\":\"$(_sill_esc "$BUFFER")\",\"cur\":$CURSOR,\"pwd\":\"$(_sill_esc "$PWD")\",\"cols\":$COLUMNS,\"rows\":$LINES$grid}"
}

_sill_reply_handler() {
    setopt localoptions extendedglob  # for the (#b) backreferences below
    local line
    if ! read -r line <&$1; then
        _sill_disconnect
        return 0
    fi
    if [[ "$line" == *'"t":"popup"'* ]]; then
        [[ "$line" == *'"visible":true'* ]] && _sill_popup=1 || _sill_popup=0
        [[ "$line" == *'"nav":true'* ]] && _sill_nav=1 || _sill_nav=0
        if (( _sill_popup )); then _sill_bind_keys; else _sill_unbind_keys; fi
        return 0
    fi
    # Otherwise "insert"; parse the two fields without a JSON parser.
    # text is JSON-escaped by Swift's JSONEncoder — unescape the subset it
    # emits for our payloads (\\ \" \n \t \r; no unicode escapes expected
    # for completion text, which is ASCII command vocabulary).
    if [[ "$line" == (#b)*'"del":'(<->)*'"text":"'(*)'"}' ]]; then
        typeset -g _sill_pending_del=$match[1]
        local text=$match[2]
        text=${text//\\n/$'\n'}
        text=${text//\\t/$'\t'}
        text=${text//\\r/$'\r'}
        text=${text//\\\"/\"}
        text=${text//\\\\/\\}
        typeset -g _sill_pending_text=$text
        zle _sill_apply 2>/dev/null
    fi
}

_sill_apply() {
    (( _sill_pending_del > 0 )) && LBUFFER=${LBUFFER[1,-($_sill_pending_del+1)]}
    LBUFFER+="$_sill_pending_text"
    # Buffer edits made from a `zle -F` handler are NOT repainted until the
    # next keystroke — force the refresh, or the insertion stays invisible.
    zle -R
    # A `zle -F`-initiated redraw doesn't run the pre-redraw hook either, so
    # report the applied buffer explicitly to keep the app's view consistent.
    _sill_send_buf
}
zle -N _sill_apply

# --- Steering keys -----------------------------------------------------
# Bound only while the popup is visible; each key falls back to whatever
# it was bound to before (the user's own bindings included) the moment the
# popup is gone. While the popup is up, Return always inserts the selected
# item (Esc dismisses it first if you want Return to run the command); with
# no popup, Return is Return.

_sill_key_sequences=('^I' '^M' '^[[A' '^[OA' '^[[B' '^[OB' '^[')

_sill_bind_keys() {
    (( _sill_bound )) && return 0
    _sill_bound=1
    local seq entry
    for seq in $_sill_key_sequences; do
        entry=$(bindkey "$seq")
        _sill_saved_bindings[$seq]="${entry##* }"
    done

    bindkey '^I' _sill_key_tab
    bindkey '^M' _sill_key_ret
    bindkey '^[[A' _sill_key_up
    bindkey '^[OA' _sill_key_up
    bindkey '^[[B' _sill_key_down
    bindkey '^[OB' _sill_key_down
    bindkey '^[' _sill_key_esc
}

_sill_unbind_keys() {
    (( _sill_bound )) || return 0
    _sill_bound=0
    local seq widget
    for seq in $_sill_key_sequences; do
        widget=$_sill_saved_bindings[$seq]
        if [[ -z "$widget" || "$widget" == "undefined-key" ]]; then
            bindkey -r "$seq" 2>/dev/null
        else
            bindkey "$seq" "$widget"
        fi
    done
}

_sill_send_key() {
    _sill_send "{\"t\":\"key\",\"sid\":\"$_sill_sid\",\"key\":\"$1\"}"
}

# Falls back for the (near-impossible) window where a key is still bound
# but the popup flag has dropped: restore the original bindings and re-feed
# the typed sequence — it then resolves through the user's own binding,
# completion widgets included (which `zle <name>` cannot re-enter).
_sill_fallback() {
    _sill_unbind_keys
    zle -U -- "$KEYS"
}

_sill_key_tab()  { (( _sill_popup )) && _sill_send_key tab  || _sill_fallback }
_sill_key_up()   { (( _sill_popup )) && _sill_send_key up   || _sill_fallback }
_sill_key_down() { (( _sill_popup )) && _sill_send_key down || _sill_fallback }
_sill_key_esc()  { (( _sill_popup )) && _sill_send_key esc  || _sill_fallback }
_sill_key_ret() {
    if (( _sill_popup )); then
        _sill_send_key ret
        return 0
    fi
    # No popup (brief window before the unbind lands): plain Return.
    # accept-line is a plain widget, so the saved binding is callable
    # directly; the dot-widget is the last resort.
    local widget=${_sill_saved_bindings['^M']}
    if [[ -n "$widget" && "$widget" != "undefined-key" ]]; then
        zle "$widget" 2>/dev/null && return 0
    fi
    zle .accept-line
}
zle -N _sill_key_tab
zle -N _sill_key_ret
zle -N _sill_key_up
zle -N _sill_key_down
zle -N _sill_key_esc

# With a bare Esc bound while the popup is up, zsh waits KEYTIMEOUT (default
# 0.4s) after ESC to tell a lone Esc from the start of an arrow sequence.
# zsh reads KEYTIMEOUT when it enters the line editor — before zle-line-init
# runs — so it must be lowered in precmd (measured: set mid-line or in
# line-init → 400ms; set before the editor starts → 14ms). It is restored
# when the line ends. Terminals send escape sequences in one burst, so 10ms
# is plenty; a KEYTIMEOUT the user already set at or below that is left
# alone. Only a variable assignment happens here; the one precmd step that
# does read the tty (_sill_measure_grid, grid terminals only) hands any
# swallowed keys back to ZLE.
_sill_lower_keytimeout() {
    (( _sill_fd >= 0 )) || (( ! _sill_dead )) || return 0
    [[ -n "$_sill_saved_keytimeout" ]] && return 0   # already lowered this line
    (( ${KEYTIMEOUT:-40} > 1 )) || return 0
    _sill_saved_keytimeout=${KEYTIMEOUT:-unset}
    KEYTIMEOUT=1
}

_sill_restore_keytimeout() {
    [[ -n "$_sill_saved_keytimeout" ]] || return 0
    if [[ "$_sill_saved_keytimeout" == unset ]]; then
        unset KEYTIMEOUT
    else
        KEYTIMEOUT=$_sill_saved_keytimeout
    fi
    _sill_saved_keytimeout=""
}

_sill_line_init() {
    if [[ -n "$_sill_typeahead" ]]; then
        zle -U -- "$_sill_typeahead"   # keys the grid measurement swallowed
        _sill_typeahead=""
    fi
    _sill_connect
    if (( _sill_fd >= 0 && ! _sill_registered )); then
        zle -F $_sill_fd _sill_reply_handler
        _sill_registered=1
    fi
    _sill_last=""
    _sill_send_buf
}

_sill_line_finish() {
    _sill_popup=0
    _sill_unbind_keys
    _sill_restore_keytimeout
    _sill_send "{\"t\":\"end\",\"sid\":\"$_sill_sid\"}"
}

_sill_precmd() {
    _sill_dead=0   # the app may have (re)started; allow one reconnect attempt
    _sill_lower_keytimeout
    _sill_measure_grid
}

add-zle-hook-widget zle-line-init _sill_line_init
add-zle-hook-widget zle-line-pre-redraw _sill_send_buf
add-zle-hook-widget zle-line-finish _sill_line_finish
add-zsh-hook precmd _sill_precmd

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
#   ← {"t":"popup","visible":…,"nav":…,"exact":…} (bind/unbind steering keys;
#     "exact": the highlighted item is exactly what was typed, so Return runs)
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
typeset -g _sill_exact=0       # highlighted item == what was typed (Return runs)
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
typeset -g _sill_nogrid=0       # this terminal answers nothing; place by window
typeset -g _sill_cols=0 _sill_rows=0   # grid size the measurement was taken at
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
    # A terminal still starting up (a cold-launched app, a freshly split
    # pane) can take most of a second to answer its first query. Waiting
    # 0.3s there loses the whole first line to the window fallback, so the
    # first measurement gets a full second; later ones stay snappy.
    local tenths=3
    (( _sill_cellw == 0 )) && tenths=10
    _sill_ask_tty $'\e]11;?\a\e[16t\e[14t\e[6n' cpr $tenths
    local reply=$_sill_reply
    _sill_parse_background "$reply"
    _sill_typeahead+=$(_sill_strip_replies "$reply")

    # Whatever else came along (a late reply to the previous prompt's query,
    # a keystroke), the LAST cursor report in the reply is the answer to the
    # query just sent — the greedy prefix makes each match take it.
    if [[ "$reply" != (#b)*$'\e['([0-9]##)\;([0-9]##)R* ]]; then
        # A terminal busy with its own startup can miss the first prompt;
        # only one that never answers is written off — and then it says so,
        # so the app places by window instead of waiting for a grid that
        # will never come.
        if (( ++_sill_grid_misses >= 5 )); then
            _sill_grid=0
            _sill_nogrid=1
        fi
        _sill_grid_debug "no cursor report"
        return 0
    fi
    _sill_row=$match[1] _sill_col=$match[2]
    _sill_grid_misses=0
    if [[ "$reply" == (#b)*$'\e[6;'([0-9]##)\;([0-9]##)t* ]]; then
        _sill_cellh=$match[1] _sill_cellw=$match[2]
    fi
    if [[ "$reply" == (#b)*$'\e[4;'([0-9]##)\;([0-9]##)t* ]]; then
        _sill_th=$match[1] _sill_tw=$match[2]
    fi
    # Without a cell size there is nothing the app can place against.
    (( _sill_cellw > 0 && _sill_cellh > 0 )) || { _sill_grid_debug "no cell size"; return 0 }
    _sill_cols=$COLUMNS _sill_rows=$LINES

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
    print -r -- "$(date +%T) ${TTY##*/} $1 reply=[${reply//$'\e'/^[}]" \
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
    _sill_ask_tty $'\e]11;?\a' osc 2 || return 0
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
    # The terminator patterns are written out per kind rather than passed in:
    # a pattern handed over as a quoted argument arrives with its $'\e'
    # unexpanded and never matches, which costs the full timeout at every
    # single prompt.
    local query=$1 kind=$2 tenths=${3:-3} saved ch
    local seconds=$(( tenths / 10.0 ))
    _sill_reply=""
    [[ -t 0 && -t 1 ]] || return 1
    saved=$(stty -g 2>/dev/null) || return 1
    # min 0 time N: a read with nothing to take returns empty after N tenths
    # instead of blocking, so an unanswering terminal costs one timeout.
    stty -echo -icanon min 0 time $tenths 2>/dev/null
    print -n -- "$query"
    while read -rs -t $seconds -k 1 ch; do
        _sill_reply+=$ch
        case $kind in
            # Our report is the one right after our text-area reply (replies
            # come in the order asked); a lone report first is a straggler
            # from an earlier in-line question, and reading must go on.
            cpr) [[ "$_sill_reply" == *$'\e[4;'[0-9]##\;[0-9]##t$'\e['[0-9]##\;[0-9]##R ]] && break ;;
            osc) [[ "$ch" == $'\a' || "$_sill_reply" == *$'\e\\' ]] && break ;;
        esac
    done
    # Whatever trails the terminator (a straggler behind it) must not be
    # left in the tty for ZLE: a short drain takes it along.
    while read -rs -t 0.01 -k 1 ch; do _sill_reply+=$ch; done
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
    rest=${rest//$'\e'\[[0-9\;]#[tR]/}
    # Anything escape-like that is still here is a reply Sill doesn't know,
    # not typing; and a stray BEL would be send-break.
    rest=${rest//$'\e'\[[0-9\;?]#[[:alpha:]~]/}
    rest=${rest//$'\e'\][^$'\a']#$'\a'/}
    print -rn -- ${rest//[$'\e'$'\a']/}
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
    # The terminal was resized (a pane split, a window drag). The pane's new
    # size follows from the grid, and the cell size still holds — the font
    # didn't change. The anchor is the doubtful part: a reflow can move the
    # prompt to another row, and re-measuring needs a raw tty read, which is
    # only safe outside ZLE. It is kept rather than dropped, because for a
    # terminal that shows Sill its screen (Ghostty) the app reads the caret's
    # row from there and never looks at it, and for one that doesn't (cmux)
    # an anchor that may be a row out still beats no completions at all until
    # the next prompt measures again.
    if (( _sill_cellw > 0 && (_sill_cols != COLUMNS || _sill_rows != LINES) )); then
        _sill_cols=$COLUMNS _sill_rows=$LINES
        _sill_tw=$(( COLUMNS * _sill_cellw ))
        _sill_th=$(( LINES * _sill_cellh ))
        _sill_request_cpr   # and take a fresh anchor, through ZLE (below)
    elif [[ "$LASTWIDGET" == *clear-screen* && "$WIDGET" != _sill_csi_sink ]]; then
        # ⌘K in Ghostty and cmux (and ^L anywhere) clears the screen and has
        # the shell redraw the prompt at the top — same prompt, new row.
        _sill_request_cpr
    fi
    local state="$BUFFER"$'\x1f'"$CURSOR"
    [[ "$state" == "$_sill_last" ]] && return 0
    _sill_last=$state
    # Only once there is a measurement to send: zeros would read as a grid
    # the app can't use, and it needs to tell "not yet" from "never".
    local grid=""
    if (( _sill_cellw > 0 )); then
        grid=",\"row\":$_sill_row,\"col\":$_sill_col,\"cellw\":$_sill_cellw,\"cellh\":$_sill_cellh,\"tw\":$_sill_tw,\"th\":$_sill_th"
    elif (( _sill_nogrid )); then
        grid=",\"nogrid\":true"
    fi
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
        [[ "$line" == *'"exact":true'* ]] && _sill_exact=1 || _sill_exact=0
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
    # Highlighters (zsh-syntax-highlighting, fast-syntax-highlighting) recolour
    # from the pre-redraw hook, which the redraw below doesn't run — left
    # alone they'd keep the colours of the text as it was before the edit,
    # so the completed word shows half-painted. Ask them directly.
    (( $+functions[_zsh_highlight] )) && _zsh_highlight
    # Buffer edits made from a `zle -F` handler are NOT repainted until the
    # next keystroke — force the refresh, or the insertion stays invisible.
    zle -R
    # A `zle -F`-initiated redraw doesn't run the pre-redraw hook either, so
    # report the applied buffer explicitly to keep the app's view consistent.
    _sill_send_buf
}
zle -N _sill_apply

# --- Terminal replies that reach ZLE ------------------------------------
# Two kinds of escape sequence can arrive as INPUT while a line is being
# edited: the cursor report Sill asks for below, and stragglers — a reply
# to the prompt-time round trip that came late, or one left in the tty by a
# query cut short. Left to ZLE they turn into garbage text, and the BEL that
# ends a colour reply is `send-break`: a new prompt, a new query, another
# straggler — a runaway that repeats until ^C (seen in the wild, 18 prompts
# in three seconds). So the CSI and OSC prefixes stay bound, permanently, to
# widgets that read the rest of the sequence from ZLE's own queue and keep
# it out of the buffer. Bound keys that are longer (the arrow keys, Home,
# bracketed paste) still win over the prefix, so nothing the user types
# changes; an unbound CSI key, which ZLE would have mangled anyway, is
# dropped instead.
#
# A resize or a screen clear moves the prompt under an open line, and the
# anchor measured at the last prompt is stale. Re-measuring can't read the
# tty raw here — that corrupts ZLE — but it can ASK, and the report comes
# back through the CSI sink. The report is the caret's cell; the anchor,
# where the buffer starts, follows from the cursor that was drawn when the
# question was asked, and COLUMNS.
typeset -g _sill_cpr_pending=0 _sill_cpr_cursor=0

_sill_request_cpr() {
    (( _sill_cpr_pending )) && return 0
    (( _sill_fd >= 0 )) || return 0
    # Not when the line is ending: the reply would arrive at the next prompt
    # and confuse its own measurement.
    [[ "$LASTWIDGET" == (*accept*|*send-break*|_sill_key_ret) ]] && return 0
    _sill_cpr_pending=1
    # This runs from the pre-redraw hook — BEFORE ZLE has drawn the current
    # buffer, so the terminal's cursor still shows the previous state while
    # CURSOR is already the new value. Draw first, then ask.
    zle -R
    _sill_cpr_cursor=$CURSOR
    print -n -- $'\e[6n'
    [[ -f "$HOME/.sill-grid-debug" ]] && print -r -- \
        "$(date +%T) ${TTY##*/} in-line query sent cursor=$CURSOR cols=$COLUMNS anchor=$_sill_row,$_sill_col after=$LASTWIDGET" >> /tmp/sill-grid.log
}

_sill_end_cpr() { _sill_cpr_pending=0 }

# CSI sink: "^[[" arrived and no longer binding claimed the sequence.
_sill_csi_sink() {
    setopt localoptions extendedglob
    local seq="" ch
    while read -k 1 -t 0.2 ch; do
        seq+=$ch
        [[ "$ch" == [A-Za-z~] ]] && break
    done
    if [[ "$seq" == (#b)([0-9]##)\;([0-9]##)R ]]; then
        if (( _sill_cpr_pending )); then
            _sill_cpr_pending=0
            local idx=$(( (match[1] - 1) * COLUMNS + (match[2] - 1) - _sill_cpr_cursor ))
            (( idx < 0 )) && idx=0
            _sill_row=$(( idx / COLUMNS + 1 ))
            _sill_col=$(( idx % COLUMNS + 1 ))
            [[ -f "$HOME/.sill-grid-debug" ]] && print -r -- \
                "$(date +%T) ${TTY##*/} in-line report [$seq] cursor=$_sill_cpr_cursor cols=$COLUMNS buf=[$BUFFER] → anchor=$_sill_row,$_sill_col" >> /tmp/sill-grid.log
            _sill_last=""
            _sill_send_buf
        fi
        return 0   # a report nobody asked for: a straggler, swallowed
    fi
    [[ -f "$HOME/.sill-grid-debug" ]] && print -r -- \
        "$(date +%T) ${TTY##*/} CSI dropped [${seq//$'\e'/^[}]" >> /tmp/sill-grid.log
}
zle -N _sill_csi_sink
bindkey '^[[' _sill_csi_sink

# OSC sink: "^[]" arrived — a colour reply (or any other OSC); read to its
# terminator (BEL, or ESC \) and keep it out of the line.
_sill_osc_sink() {
    local seq="" ch
    while read -k 1 -t 0.2 ch; do
        seq+=$ch
        [[ "$ch" == $'\a' || "$seq" == *$'\e\\' ]] && break
    done
    [[ -f "$HOME/.sill-grid-debug" ]] && print -r -- \
        "$(date +%T) ${TTY##*/} OSC dropped [${seq//$'\e'/^[}]" >> /tmp/sill-grid.log
}
zle -N _sill_osc_sink
bindkey '^[]' _sill_osc_sink

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
    if (( _sill_popup && _sill_exact )); then
        # The highlighted item is exactly what was typed: nothing to insert,
        # so Return does what Return does — decided here, synchronously.
        _sill_popup=0
        _sill_unbind_keys
        zle .accept-line
        return 0
    fi
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
    _sill_end_cpr      # a report that never came is a straggler for the sink
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

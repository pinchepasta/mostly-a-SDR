#!/bin/bash

# ==========================================================================
#  mostly-a-SDR :: neon green / neon pink on black
#  --------------------------------------------------------------------------
#  Boot sequence, glitch banner, live backtitle, TX alert dialogs, outro.
#  MAS_QUICK=1 ./script.sh   -> skip boot log / animation / key-wait
#  Everything cosmetic is terminal-only and degrades to plain output when not
#  attached to a UTF-8 tty, so piped / logged runs stay clean.
# ==========================================================================

# newt palette: "magenta" stands in for neon pink, "green" for neon green.
export NEWT_COLORS='
root=green,black
border=magenta,black
window=green,black
shadow=black,black
title=magenta,black
button=black,magenta
actbutton=black,green
checkbox=green,black
actcheckbox=black,green
entry=green,black
label=green,black
listbox=green,black
actlistbox=black,green
textbox=green,black
acttextbox=black,green
helpline=magenta,black
roottext=magenta,black
emptyscale=black,green
fullscale=black,magenta
disabledentry=magenta,black
compactbutton=black,green
'

# Inverted "red alert" palette, used only for the live-TX dialog:
# pink window, reverse-video pink title bar, green frame.
MAS_TX_COLORS='
root=green,black
border=green,black
window=magenta,black
shadow=black,black
title=black,magenta
button=black,green
actbutton=black,magenta
textbox=magenta,black
acttextbox=black,magenta
label=magenta,black
helpline=magenta,black
roottext=magenta,black
'

MAS_TX_STATE="STANDBY"      # STANDBY | LIVE | REC  (shown in the backtitle)

# --- raw ANSI 256-colour building blocks -----------------------------------
MAS_PINK=$'\033[0;38;5;198m'
MAS_GREEN=$'\033[0;38;5;84m'
MAS_G35=$'\033[0;38;5;35m'
MAS_DIM=$'\033[0;38;5;240m'
MAS_DARK=$'\033[0;38;5;236m'
MAS_OKC=$'\033[1;38;5;47m'
MAS_RST=$'\033[0m'
MAS_GRAD=(157 121 84 47 41 35 157 121 84 47 41 35)      # per logo row
MAS_LVL=(35 35 41 41 47 47 84 84 121 198 198 198)       # per equaliser level
MAS_TARGET=(1 2 2 3 4 6 9 12 8 5 3 2 2 1)               # "locked signal" shape
MAS_H=(2 2 2 2 2 2 2 2 2 2 2 2 2 2)
MAS_SP=$'        '
MAS_OUT=""
MAS_BUF=""
MAS_ANIM=1
MAS_BAD=()
MAS_TOTAL=0

# ---------------------------------------------------------------------------
# Live backtitle: state, UTC clock (FT8 slots care), site. Re-evaluated on
# every dialog, so the clock and TX state are always current.
# ---------------------------------------------------------------------------
mas_backtitle()
{
	local clk state
	clk=$(date -u +%H:%M:%S)
	case "$MAS_TX_STATE" in
		LIVE) state="● TX LIVE" ;;
		REC)  state="● REC" ;;
		*)    state="○ standby" ;;
	esac
	printf '░▒▓ mostly-a-SDR ▓▒░ %s ░ %s UTC ░ Made for mostlyawesome.de' "$state" "$clk"
}

whiptail()
{
	command whiptail --backtitle "$(mas_backtitle)" "$@"
}

# ---------------------------------------------------------------------------
# small helpers (results go through globals - no subshell forks in hot loops)
# ---------------------------------------------------------------------------
mas_utf8()
{
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
		*[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
	esac
	return 1
}

mas_rep()       # mas_rep <string> <count>  -> MAS_OUT
{
	local s
	printf -v s '%*s' "$2" ''
	MAS_OUT=${s// /$1}
}

mas_glitch()    # mas_glitch <string> <hits>  -> MAS_OUT (same length)
{
	local s=$1 n=$2 len=${#1} i p g
	local gl='░▒▓█▌▐▀▄╳#%@$&0123456789ABCDEF'
	for ((i = 0; i < n && len > 0; i++)); do
		p=$((RANDOM % len))
		g=${gl:RANDOM % ${#gl}:1}
		s=${s:0:p}${g}${s:p+1}
	done
	MAS_OUT=$s
}

mas_strip()     # mas_strip <width> <max-height 0-7> <settled 0|1>  -> MAS_OUT
{
	local w=$1 maxh=$2 last=$3 i h=3 col cur="" s=""
	local blocks='▁▂▃▄▅▆▇█'
	local mid=$((w / 2))
	for ((i = 0; i < w; i++)); do
		if (( last )); then
			h=$((RANDOM % 2))
			(( i == mid - 2 || i == mid + 2 )) && h=2
			(( i == mid - 1 || i == mid + 1 )) && h=4
			(( i == mid )) && h=7
		else
			h=$((h + RANDOM % 3 - 1))
			(( h < 0 )) && h=0
			(( h > maxh )) && h=$maxh
		fi
		if   (( h >= 6 )); then col=$MAS_PINK
		elif (( h >= 3 )); then col=$MAS_GREEN
		else                    col=$MAS_G35
		fi
		[ "$col" != "$cur" ] && { s+=$col; cur=$col; }
		s+=${blocks:h:1}
	done
	MAS_OUT=$s
}

mas_hexrow()    # mas_hexrow <locked-bytes> <settled 0|1>  -> MAS_OUT (74 cols)
{
	local n=$1 last=$2 i b addr s
	if (( last )); then addr=C0FFEE00; else printf -v addr '%04X%04X' "$RANDOM" "$RANDOM"; fi
	s="${MAS_DIM}0x${addr}  "
	for ((i = 0; i < 18; i++)); do
		if (( i < n )); then
			s+="${MAS_GREEN}${MAS_HEX[i]} "
		else
			printf -v b '%02X' $((RANDOM % 256))
			s+="${MAS_DIM}${b} "
		fi
	done
	MAS_OUT="${s}        "
}

mas_row()       # append a boxed row; $1 must be exactly 74 visible columns
{
	MAS_BUF+="${MAS_PINK}│ ${1}${MAS_RST}${MAS_PINK} │${MAS_RST}"$'\n'
}

mas_textrow()   # mas_textrow <text> <colour>
{
	local t=${1:0:70}
	mas_rep ' ' $((70 - ${#t}))
	MAS_BUF+="${MAS_PINK}│ ${MAS_DIM}[${MAS_PINK}+${MAS_DIM}]${2} ${t}${MAS_OUT}${MAS_PINK} │${MAS_RST}"$'\n'
}

# ---------------------------------------------------------------------------
# one-time banner data: logo rows padded to 58 cols, two-tone neon colouring
# (solid blocks = green gradient, shadow strokes = pink), frame rules, sys info
# ---------------------------------------------------------------------------
mas_init()
{
	local i j c out cur want row head t
	mapfile -t MAS_LOGO <<'MAS_LOGO_EOF'
███╗   ███╗ ██████╗ ███████╗████████╗██╗  ██╗   ██╗
████╗ ████║██╔═══██╗██╔════╝╚══██╔══╝██║  ╚██╗ ██╔╝
██╔████╔██║██║   ██║███████╗   ██║   ██║   ╚████╔╝█████╗
██║╚██╔╝██║██║   ██║╚════██║   ██║   ██║    ╚██╔╝ ╚════╝
██║ ╚═╝ ██║╚██████╔╝███████║   ██║   ███████╗██║
╚═╝     ╚═╝ ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝╚═╝
       █████╗       ███████╗██████╗ ██████╗
      ██╔══██╗      ██╔════╝██╔══██╗██╔══██╗
      ███████║█████╗███████╗██║  ██║██████╔╝
      ██╔══██║╚════╝╚════██║██║  ██║██╔══██╗
      ██║  ██║      ███████║██████╔╝██║  ██║
      ╚═╝  ╚═╝      ╚══════╝╚═════╝ ╚═╝  ╚═╝
MAS_LOGO_EOF

	MAS_CLOGO=()
	for ((i = 0; i < 12; i++)); do
		row=${MAS_LOGO[i]}
		while (( ${#row} < 58 )); do row+=' '; done
		MAS_LOGO[i]=$row
		out=""; cur=""
		for ((j = 0; j < ${#row}; j++)); do
			c=${row:j:1}
			case "$c" in
				' ') want="" ;;
				█)   want=$'\033[1;38;5;'"${MAS_GRAD[i]}"m ;;
				*)   want=$MAS_PINK ;;
			esac
			if [ -n "$want" ] && [ "$want" != "$cur" ]; then out+=$want; cur=$want; fi
			out+=$c
		done
		MAS_CLOGO[i]=$out
	done

	MAS_LC=()
	for ((i = 0; i < 12; i++)); do MAS_LC[i]=$'\033[0;38;5;'"${MAS_LVL[i]}"m; done

	MAS_NOISE=""
	for ((i = 0; i < 180; i++)); do c='░▒▓'; MAS_NOISE+=${c:RANDOM % 3:1}; done

	MAS_HEX=()
	t="MOSTLY-A-SDR ARMED"
	for ((i = 0; i < 18; i++)); do printf -v c '%02X' "'${t:i:1}"; MAS_HEX[i]=$c; done

	head="[ root@mostly-a-sdr:~# ${MAS_CMD:-./transmit} ]"
	mas_rep '─' $((67 - ${#head}));  MAS_TOP="┌─${head}${MAS_OUT}░▒▓█▓▒░─┐"
	mas_rep '─' 60;                  MAS_DIV="├─[ sys ]${MAS_OUT}░▒▓█▓▒░─┤"
	                                 MAS_BOT="└─░▒▓█▓▒░${MAS_OUT}░▒▓█▓▒░─┘"

	MAS_HOST=$(hostname 2>/dev/null); [ -n "$MAS_HOST" ] || MAS_HOST=unknown
	MAS_MODEL=$(tr -d '\0' 2>/dev/null </proc/device-tree/model)
	[ -n "$MAS_MODEL" ] || MAS_MODEL=$(uname -m 2>/dev/null)
	MAS_SYS="node ${MAS_HOST} :: ${MAS_MODEL}"
	t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
	if [[ "$t" =~ ^[0-9]+$ ]]; then
		MAS_SYS+=" :: $((t / 1000)).$((t % 1000 / 100))C"
	fi
}

# ---------------------------------------------------------------------------
# one banner frame. f = 0..F-1; the last frame is the settled, clean logo.
#   phase 1: rows scan in out of static      phase 2: glitch decays
#   equaliser + top strip + hex dump "lock" onto the signal as f -> F-1
# ---------------------------------------------------------------------------
mas_frame()
{
	local f=$1 F=$2 last=0 i j reveal gp maxh row body panel lvl off src lock
	(( f == F - 1 )) && last=1
	reveal=$((f * 2)); gp=$((60 - f * 3)); maxh=$((7 - f * 5 / (F - 1)))
	(( last )) && { reveal=99; gp=0; }
	(( gp < 0 )) && gp=0
	(( maxh < 2 )) && maxh=2
	MAS_BUF=""

	MAS_BUF+="${MAS_PINK}${MAS_TOP}${MAS_RST}"$'\n'
	mas_strip 74 "$maxh" "$last"; mas_row "$MAS_OUT"

	for ((j = 0; j < 14; j++)); do
		if (( last )); then
			MAS_H[j]=${MAS_TARGET[j]}
		else
			MAS_H[j]=$((MAS_H[j] + RANDOM % 7 - 3))
			(( f > 9 )) && MAS_H[j]=$(( (MAS_H[j] + MAS_TARGET[j]) / 2 + RANDOM % 3 - 1 ))
			(( MAS_H[j] < 0 ))  && MAS_H[j]=0
			(( MAS_H[j] > 12 )) && MAS_H[j]=12
		fi
	done

	for ((i = 0; i < 12; i++)); do
		if (( i >= reveal )); then
			body="${MAS_DARK}${MAS_NOISE:RANDOM % 120:58}"
		elif (( i == reveal - 1 && ! last && f < 7 )); then
			body="${MAS_PINK}${MAS_LOGO[i]}"
		elif (( gp > 0 && RANDOM % 100 < gp )); then
			src=$i; (( RANDOM % 3 == 0 )) && src=$((RANDOM % 12))
			off=$((RANDOM % 5))
			row="${MAS_SP:0:off}${MAS_LOGO[src]:0:58-off}"
			mas_glitch "$row" $((1 + RANDOM % 4))
			if (( RANDOM % 2 )); then body="${MAS_PINK}${MAS_OUT}"
			else body=$'\033[1;38;5;'"${MAS_GRAD[i]}m${MAS_OUT}"; fi
		else
			body=${MAS_CLOGO[i]}
		fi
		lvl=$((11 - i)); panel=""
		for ((j = 0; j < 14; j++)); do
			if (( MAS_H[j] > lvl )); then panel+="${MAS_LC[lvl]}█"
			else panel+="${MAS_DARK}·"; fi
		done
		mas_row "${body}${MAS_RST}  ${panel}"
	done

	lock=$((f * 18 / (F - 1))); (( last )) && lock=18
	mas_hexrow "$lock" "$last"; mas_row "$MAS_OUT"

	MAS_BUF+="${MAS_PINK}${MAS_DIV}${MAS_RST}"$'\n'
	mas_textrow "$MAS_SYS" "$MAS_GREEN"
	mas_textrow "${MAS_TAG:-rf toolkit :: raspberry pi}" "$MAS_GREEN"
	if (( ${#MAS_BAD[@]} )); then
		mas_textrow "pre-flight :: MISSING ${MAS_BAD[*]}" "$MAS_PINK"
	else
		mas_textrow "pre-flight :: ${MAS_TOTAL}/${MAS_TOTAL} checks passed :: all systems nominal" "$MAS_GREEN"
	fi
	mas_textrow "tx armed. know your local laws. transmit responsibly." "$MAS_PINK"
	MAS_BUF+="${MAS_PINK}${MAS_BOT}${MAS_RST}"$'\n'
}

# ---------------------------------------------------------------------------
# pre-flight: real checks, cinematic delivery. Never blocks - missing pieces
# are flagged so you know before a transmit silently does nothing.
#   mas_check <label> <shell snippet whose stdout is the detail, exit 0 = ok>
# ---------------------------------------------------------------------------
mas_check()
{
	local label=$1 detail
	MAS_TOTAL=$((MAS_TOTAL + 1))
	(( MAS_SHOWBOOT )) && printf '  %s[ .. ]%s %-16s' "$MAS_DIM" "$MAS_RST" "$label"
	(( MAS_SHOWBOOT && MAS_ANIM )) && sleep 0.05
	if detail=$(eval "$2" 2>/dev/null); then
		detail=${detail%%$'\n'*}
		(( MAS_SHOWBOOT )) && printf '\r  %s[ OK ]%s %-16s %s%s%s\n' "$MAS_OKC" "$MAS_RST" "$label" "$MAS_DIM" "${detail:0:44}" "$MAS_RST"
	else
		MAS_BAD+=("$label")
		(( MAS_SHOWBOOT )) && printf '\r  %s[FAIL]%s %-16s %snot found%s\n' "$MAS_PINK" "$MAS_RST" "$label" "$MAS_DIM" "$MAS_RST"
	fi
	return 0
}

# Blinking "press any key" hold - whiptail grabs the screen the instant it
# starts, so without this the banner would never actually be seen.
mas_prompt()
{
	local i k
	for ((i = 0; i < 14; i++)); do
		if (( i % 2 )); then printf '\r\033[K %s▸ press any key to jack in%s' "$MAS_DIM" "$MAS_RST"
		else                 printf '\r\033[K %s▸ press any key to jack in%s █' "$MAS_PINK" "$MAS_RST"; fi
		if read -rsn1 -t 0.35 k; then break; fi
	done
	printf '\r\033[K'
}

show_banner()
{
	[ -t 1 ] || return 0
	if ! mas_utf8; then
		printf 'mostly-a-SDR :: %s\n' "${MAS_TAG:-rf toolkit}"
		printf 'tx armed. know your local laws. transmit responsibly.\n'
		return 0
	fi

	local F=20 f rows quick=0
	[ "${MAS_QUICK:-0}" = 1 ] && quick=1
	rows=$(tput lines 2>/dev/null); rows=${rows:-24}
	MAS_ANIM=1; (( quick || rows < 24 )) && MAS_ANIM=0
	MAS_SHOWBOOT=$MAS_ANIM
	MAS_BAD=(); MAS_TOTAL=0

	trap 'printf "\033[?25h\033[0m\n"; exit 130' INT
	(( MAS_ANIM )) && printf '\033[2J\033[H'
	(( MAS_SHOWBOOT )) && {
		printf '%s  mostly-a-SDR boot :: %s%s\n\n' "$MAS_PINK" "$(date '+%F %T')" "$MAS_RST"
	}
	if declare -F mas_preflight >/dev/null; then mas_preflight; fi
	mas_init

	if (( MAS_ANIM )); then
		sleep 0.5
		printf '\033[2J\033[H\033[?25l'
		for ((f = 0; f < F; f++)); do
			mas_frame "$f" "$F"
			(( f > 0 )) && printf '\033[21A'
			printf '%s' "$MAS_BUF"
			sleep 0.045
		done
		printf '\033[?25h'
		[ -t 0 ] && mas_prompt
	else
		mas_frame 1 2
		printf '%s' "$MAS_BUF"
	fi
	trap - INT
}

# Short glitch-out when the session ends.
mas_outro()
{
	[ -t 1 ] || return 0
	local msg="[-] carrier dropped :: session closed :: 73 de mostly-a-SDR" n
	if ! mas_utf8 || [ "${MAS_QUICK:-0}" = 1 ]; then
		printf '%s\n' "$msg"; return 0
	fi
	for n in 18 12 6 3; do
		mas_glitch "$msg" "$n"
		printf '\r\033[K%s%s%s' "$MAS_PINK" "$MAS_OUT" "$MAS_RST"
		sleep 0.07
	done
	printf '\r\033[K%s%s%s\n' "$MAS_PINK" "$msg" "$MAS_RST"
}

MAS_CMD='./ft8 --pift8'
MAS_TAG='ft8 qso helper :: raspberry pi :: pift8'

mas_preflight()
{
	mas_check "whiptail" 'type -P whiptail'
	mas_check "sudo"     'type -P sudo'
	mas_check "pift8"    'type -P pift8'
	mas_check "/dev/mem" '[ -c /dev/mem ] && echo /dev/mem'
}

# Terminal-side TX log: the menu has released the screen while pift8 runs,
# so print what is actually going out and on which frequency / slot.
mas_tx_begin()      # mas_tx_begin <message> <details>
{
	MAS_TX_STATE=LIVE
	[ -t 1 ] || return 0
	printf '\n%s▓▒░ TX ░▒▓%s %s%s MHz%s  %s\n' "$MAS_PINK" "$MAS_RST" "$MAS_GREEN" "$OUTPUT_FREQ" "$MAS_DIM" "$2"
	if mas_utf8; then
		mas_strip 64 6 0
		printf '%s%s\n' "$MAS_OUT" "$MAS_RST"
	fi
	printf '%s ▸ %s%s\n' "$MAS_PINK" "$1" "$MAS_RST"
}

mas_tx_end()
{
	MAS_TX_STATE=STANDBY
	[ -t 1 ] || return 0
	printf '%s ▸ tx complete%s\n' "$MAS_DIM" "$MAS_RST"
	[ "${MAS_QUICK:-0}" = 1 ] || sleep 1
}

status="0"
OUTPUT_FREQ=14.074
LAST_ITEM="0 CQ"
OUTPUT_CALL=""
OUTPUT_GRID="JN06"

OM_CALL=""
OM_LEVEL="10"
FREETEXT="RPITX FT8 PI"

OUTPUT_OFFSET="1240"
TIMESLOT="1"

do_offset_frequency()
{
    if OFFSET=$(whiptail --inputbox "Choose FT8 offset (10-2600Hz) Default is 1240Hz" 8 78 "$OUTPUT_OFFSET" --title "░▒▓ Offset Frequency ▓▒░" 3>&1 1>&2 2>&3); then
        OUTPUT_OFFSET=$OFFSET
    fi
}

do_slot_choice()
{
    if (whiptail --title "░▒▓ Time slot ▓▒░" --yesno --yes-button 0 --no-button 1 "Which timeslot (current) $TIMESLOT ?" 8 78 3>&1 1>&2 2>&3); then
        TIMESLOT="0"
    else 
        TIMESLOT="1"
    fi    
}

do_freq_setup()
{

    if FREQ=$(whiptail --inputbox "Choose FT8 output Frequency (in MHz). Default is 14.074 MHz" 8 78 "$OUTPUT_FREQ" --title "░▒▓ mostly-a-SDR transmit frequency ▓▒░" 3>&1 1>&2 2>&3); then
        OUTPUT_FREQ=$FREQ
    fi

    if CALL=$(whiptail --inputbox "Type your call" 8 78 "$OUTPUT_CALL" --title "░▒▓ Hamradio call ▓▒░" 3>&1 1>&2 2>&3); then
        OUTPUT_CALL=$CALL
    fi

    if GRID=$(whiptail --inputbox "Type your grid on 4 char:ex JN06" 8 78 "$OUTPUT_GRID" --title "░▒▓ Hamradio grid ▓▒░" 3>&1 1>&2 2>&3); then
        OUTPUT_GRID=$GRID
    fi
    do_offset_frequency
    do_slot_choice
}

do_status()
{
	LAST_ITEM="$menuchoice"
	MAS_TX_STATE=LIVE
	NEWT_COLORS="$MAS_TX_COLORS" whiptail --title "░▒▓ TX LIVE :: $LAST_ITEM @ $OUTPUT_FREQ MHz ▓▒░" --ok-button "STOP TX" --msgbox "● TRANSMITTING ●\n\n  mode : $LAST_ITEM\n  freq : $OUTPUT_FREQ MHz\n\nPress STOP TX to end." 12 78
	MAS_TX_STATE=STANDBY
}

# One FT8 transmission on the current freq / offset / slot.
do_tx()
{
	mas_tx_begin "$1" "+${OUTPUT_OFFSET} Hz  slot ${TIMESLOT}"
	sudo pift8 -f "$OUTPUT_FREQ"e6 -m "$1" -o "$OUTPUT_OFFSET" -s "$TIMESLOT"
	mas_tx_end
}

do_om_call()
{
    

    if CALL=$(whiptail --inputbox "Input new OM" 8 78 "$OM_CALL" --title "░▒▓ OM Call ▓▒░" 3>&1 1>&2 2>&3); then
        OM_CALL=$CALL
    fi

    #init level could not be a "-", remove the init
    if LEVEL=$(whiptail --inputbox "Received level" 8 78 "0" --title "░▒▓ Received level ▓▒░" 3>&1 1>&2 2>&3); then
        OM_LEVEL=$LEVEL
    fi
    
}

do_freetext()
{
    

    if TEXT=$(whiptail --inputbox "Type free text(13 chars)" 8 78 "$FREETEXT" --title "░▒▓ FreeText ▓▒░" 3>&1 1>&2 2>&3); then
        FREETEXT=$TEXT
        
    fi

    if (whiptail --title "░▒▓ FreeText ▓▒░" --yesno "Transmit now ?" 8 78 3>&1 1>&2 2>&3); then
        mas_tx_begin "$FREETEXT" "free text"
        sudo pift8 -f "$OUTPUT_FREQ"e6 "-m $FREETEXT"
        mas_tx_end
    fi    
    
}

show_banner
do_freq_setup

 while [ "$status" -eq 0 ]
    do

 menuchoice=$(whiptail --default-item "$LAST_ITEM" --ok-button "ENGAGE" --cancel-button "EXIT" --title "░▒▓ mostly-a-SDR :: FT8 @ $OUTPUT_FREQ MHz :: slot $TIMESLOT :: +$OUTPUT_OFFSET Hz ▓▒░" --menu "root@mostly-a-sdr:~# ./qso --interactive   (choose your item)" 20 82 12 \
	"0 CQ" "Calling CQ on $OUTPUT_FREQ MHz" \
	"1 ENTER OM" "Input OM call" \
    "2 dB" "Answer Db" \
	"3 RRR" "Answer RRR" \
	"4 Grid" "Answer with grid" \
	"5 R+dB" "Answer with R+level" \
    "6 73" "Answer with 73" \
    "7 Text" "Free text" \
    "8 Refine" "Adjust offset/slot" \
	3>&2 2>&1 1>&3)

        case "$menuchoice" in
		0\ *) do_tx "CQ $OUTPUT_CALL $OUTPUT_GRID"
        LAST_ITEM="1 ENTER OM" ;;
        1\ *) do_om_call 
        LAST_ITEM="2 dB" ;;
		2\ *) do_tx "$OM_CALL $OUTPUT_CALL $OM_LEVEL"
        LAST_ITEM="3 RRR" ;;
		3\ *) do_tx "$OM_CALL $OUTPUT_CALL RR73"
        LAST_ITEM="0 CQ" ;;
		4\ *) do_tx "$OM_CALL $OUTPUT_CALL $OUTPUT_GRID"
        LAST_ITEM="5 R+dB" ;;
		5\ *) do_tx "$OM_CALL $OUTPUT_CALL R$OM_LEVEL"
        LAST_ITEM="6 73" ;;
		6\ *) do_tx "$OM_CALL $OUTPUT_CALL 73"
        do_om_call
        LAST_ITEM="4 Grid" ;;
        7\ *) do_freetext ;;
        8\ *) do_offset_frequency
        do_slot_choice 
         LAST_ITEM="0 CQ" ;;
    	*)	 status=1
		whiptail --title "░▒▓ session closed ▓▒░" --msgbox "Carrier dropped.\n\nThanks for using mostly-a-SDR!" 10 78
		;;
        esac
    done

mas_outro

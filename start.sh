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

MAS_CMD='./transmit --unsafe'
MAS_TAG='rf transmitter toolkit :: raspberry pi :: 50kHz-1GHz'

mas_preflight()
{
	mas_check "whiptail"    'type -P whiptail'
	mas_check "sudo"        'type -P sudo'
	mas_check "rpitx tools" 'type -P testvfo.sh'
	mas_check "sendiq"      'type -P sendiq'
	mas_check "/dev/mem"    '[ -c /dev/mem ] && echo /dev/mem'
	mas_check "resources"   '[ -d "$RESOURCES_LOCATION" ] && echo "$RESOURCES_LOCATION"'
	mas_check "sub captures" '[ -d "$SUB_FILES_LOCATION" ] && echo "$SUB_FILES_LOCATION"'
}

abort_action=0

OUTPUT_FREQ=434.0
RESOURCES_LOCATION="${RPITX_RESOURCES_LOCATION:-/usr/share/rpitx-ui}"
# Flipper Zero .sub captures are the user's own files, not something bundled
# with the project, so - unlike RESOURCES_LOCATION - this is a writable
# directory under $HOME, created on startup if it doesn't exist yet. Copy
# your .sub files here (or point RPITX_SUB_LOCATION at wherever you keep them).
SUB_FILES_LOCATION="${RPITX_SUB_LOCATION:-$HOME/rpitx-ui-sub-captures}"
mkdir -p "$SUB_FILES_LOCATION" 2>/dev/null
DEFAULT_POCSAG_MESSAGE="1:YOURCALL\n2: Hello world"
DEFAULT_OPERA_CALLSIGN="F5OEO"
DEFAULT_RTTY_MESSAGE="HELLO WORLD FROM RPITX"
DEFAULT_CW_MESSAGE="CQ CQ DE RPITX"
DEFAULT_CW_WPM=5
DEFAULT_RFGEN_SAMPLE_RATE=500000
DEFAULT_RFGEN_BANDWIDTH=200000
DEFAULT_MULTITONE_TONES=8
DEFAULT_NFM_MODE="Wide"
DEFAULT_PLAYBACK="loop"
DEFAULT_SUB_REPEAT=3
DEFAULT_SSB_SIDEBAND="USB"
DEFAULT_RDS_PI="0x1234"
DEFAULT_RDS_PS="rpitx-ui"
DEFAULT_RDS_RT="rpitx-ui Broadcast WFM with RDS"
DEFAULT_RDS_PE="50"
LAST_ITEM="0 Tune"
AUDIO_FILE_PATTERN='\.(aif|aiff|caf|flac|mp3|wav)$'

do_check_file_existance() 
{

	if ! readlink -e "$1" > /dev/null; then
    	whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "The file does not exist!" 8 78
		return 1
	fi
	return 0

}

do_freq_setup()
{

if FREQ=$(whiptail --inputbox "Enter output frequency (in MHz). Current is $OUTPUT_FREQ MHz" 8 78 $OUTPUT_FREQ --title "░▒▓ mostly-a-SDR transmit frequency ▓▒░" 3>&1 1>&2 2>&3); then
	OUTPUT_FREQ=$FREQ
fi

}

# Reads the "Frequency:" line out of a Flipper Zero .sub RAW file and prints
# it in MHz (e.g. "440.170000"). Prints nothing if the field is missing or
# not a plain integer Hz value, so callers can fall back gracefully.
do_sub_file_frequency_mhz()
{
	local file="$1" hz
	hz=$(tr -d '\r' < "$file" | awk -F: '/^Frequency:/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
	if [[ "$hz" =~ ^[0-9]+$ ]]; then
		awk -v hz="$hz" 'BEGIN{printf "%.6f", hz / 1000000}'
	fi
}

do_file_choose() {
	local file_type_info="$1"
	local directory="$2"
	local file_pattern="${3,,}"
	local path file displayed_info selected_file
	local file_list=()

	for path in "$directory"/*; do
		[[ -f "$path" ]] || continue

		file=${path##*/}
		if [[ "${file,,}" =~ $file_pattern ]]; then
			file_list+=("$file" "")
		fi
	done

	if (( ${#file_list[@]} == 0 )); then
		whiptail --title "No Files Found" --msgbox "No $file_type_info files were found in $directory" 8 78
		abort_action=1
		return
	fi

	displayed_info="Choose $file_type_info file \nlocated in $directory:"
	if selected_file=$(whiptail --noitem --title "Select a file to transmit" --menu "$displayed_info" 21 82 12 "${file_list[@]}" 3>&1 1>&2 2>&3); then
		FILE_LOC="${directory%/}/$selected_file"
		abort_action=0
	else
		abort_action=1
	fi
}

do_enter_message()
{

LAST_ITEM="$menuchoice"
if MESSAGE=$(whiptail --inputbox "Type custom $1 message:" 8 78 "$2" --title "Enter message to transmit" 3>&1 1>&2 2>&3);  then
	abort_action=0
	if [ -z "$MESSAGE" ]; then
    	whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Empty message!" 8 78
		abort_action=1
	fi
else
	abort_action=1
fi

}

do_enter_repeat_count()
{

LAST_ITEM="$menuchoice"
if REPEAT_COUNT=$(whiptail --inputbox "Enter number of times to resend the capture:" 8 78 $DEFAULT_SUB_REPEAT --title "Repeat count" 3>&1 1>&2 2>&3); then
	abort_action=0
	if [ -z "$REPEAT_COUNT" ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Empty repeat count!" 8 78
		abort_action=1
	elif ! [[ "$REPEAT_COUNT" =~ ^[0-9]+$ ]] || [ "$REPEAT_COUNT" = "0" ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Repeat count must be a positive integer!" 8 78
		abort_action=1
	fi
else
	abort_action=1
fi

}

do_enter_wpm()
{

if CW_WPM=$(whiptail --inputbox "Enter CW speed (WPM):" 8 78 $DEFAULT_CW_WPM --title "CW speed" 3>&1 1>&2 2>&3); then
	abort_action=0
	if [ -z "$CW_WPM" ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Empty WPM value!" 8 78
		abort_action=1
	elif ! [[ "$CW_WPM" =~ ^[0-9]+$ ]]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "WPM must be a positive integer!" 8 78
		abort_action=1
	fi
else
	abort_action=1
fi

}

do_enter_rfgen_params()
{

LAST_ITEM="$menuchoice"

# Mode selection
if RFGEN_MODE=$(whiptail --title "RF generator mode" --menu "Select RF generator mode:" 15 78 3 \
	"Noise" "Uniform pseudo-random noise across the bandwidth" \
	"Sweep" "Fast sawtooth sweep across the bandwidth" \
	"Multitone" "Random fast-hopping across equidistant tones" \
	3>&1 1>&2 2>&3); then
	abort_action=0
else
	abort_action=1
	return
fi

# Bandwidth
if RFGEN_BW=$(whiptail --inputbox "Enter RF generator bandwidth (Hz, must be below $DEFAULT_RFGEN_SAMPLE_RATE):" 8 78 "$DEFAULT_RFGEN_BANDWIDTH" --title "RF generator bandwidth" 3>&1 1>&2 2>&3); then
	if [ -z "$RFGEN_BW" ] || ! [[ "$RFGEN_BW" =~ ^[0-9]+$ ]] || [ "$RFGEN_BW" = "0" ] || [ "$RFGEN_BW" -ge "$DEFAULT_RFGEN_SAMPLE_RATE" ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Bandwidth must be a positive integer below $DEFAULT_RFGEN_SAMPLE_RATE Hz!" 8 78
		abort_action=1
		return
	fi
else
	abort_action=1
	return
fi

# Tone count is asked only for multitone mode; left empty for other modes.
MULTITONE_TONES=""
if [ "$RFGEN_MODE" = "Multitone" ]; then
	if MULTITONE_TONES=$(whiptail --inputbox "Enter tone count:" 8 78 "$DEFAULT_MULTITONE_TONES" --title "Multitone tone count" 3>&1 1>&2 2>&3); then
		if [ -z "$MULTITONE_TONES" ] || ! [[ "$MULTITONE_TONES" =~ ^[0-9]+$ ]] || [ "$MULTITONE_TONES" -lt 2 ] || [ "$MULTITONE_TONES" -gt 1024 ]; then
			whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Tone count must be an integer in [2, 1024]!" 8 78
			abort_action=1
			return
		fi
	else
		abort_action=1
		return
	fi
fi

abort_action=0

}

do_enter_nfm_mode()
{

LAST_ITEM="$menuchoice"
if NFM_MODE=$(whiptail --default-item "$DEFAULT_NFM_MODE" --title "NFM deviation mode" --menu "Select NFM deviation mode:" 15 78 2 \
	"Wide" "+-5 kHz deviation for 25 kHz channels (amateur VHF/UHF)" \
	"Narrow" "+-2.5 kHz deviation for 12.5 kHz channels (PMR/DMR)" \
	3>&1 1>&2 2>&3); then
	abort_action=0
else
	abort_action=1
fi

}

do_enter_ssb_sideband()
{

LAST_ITEM="$menuchoice"
if SSB_SIDEBAND=$(whiptail --default-item "$DEFAULT_SSB_SIDEBAND" --title "SSB sideband" --menu "Select SSB sideband:" 15 78 2 \
	"USB" "Upper Side Band modulation" \
	"LSB" "Lower Side Band modulation" \
	3>&1 1>&2 2>&3); then
	abort_action=0
else
	abort_action=1
fi

}

do_enter_playback_mode()
{

LAST_ITEM="$menuchoice"
if PLAYBACK_MODE=$(whiptail --default-item "$DEFAULT_PLAYBACK" --title "Playback mode" --menu "Select playback mode:" 15 78 2 \
	"loop" "Replay the audio file continuously" \
	"once" "Play once and stop at end of file" \
	3>&1 1>&2 2>&3); then
	abort_action=0
else
	abort_action=1
fi

}

do_enter_rds_params()
{

LAST_ITEM="$menuchoice"

# PI code (Programme Identification): 1-4 hex digits, optional 0x prefix
if RDS_PI=$(whiptail --inputbox "Enter RDS Programme Identification (1-4 hex digits, optional 0x prefix):" 8 78 "$DEFAULT_RDS_PI" --title "RDS Programme Identification (PI)" 3>&1 1>&2 2>&3); then
	abort_action=0
	if [ -z "$RDS_PI" ] || ! [[ "$RDS_PI" =~ ^(0[xX])?[0-9a-fA-F]{1,4}$ ]]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "PI must be 1-4 hex digits, optionally prefixed with 0x/0X!" 8 78
		abort_action=1
		return
	fi
else
	abort_action=1
	return
fi

# PS name (Programme Service): 1-8 ASCII chars (RDS does not carry non-ASCII text)
if RDS_PS=$(whiptail --inputbox "Enter RDS Programme Service name (1-8 ASCII chars):" 8 78 "$DEFAULT_RDS_PS" --title "RDS Programme Service (PS)" 3>&1 1>&2 2>&3); then
	abort_action=0
	if [ -z "$RDS_PS" ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "PS cannot be empty!" 8 78
		abort_action=1
		return
	elif printf '%s' "$RDS_PS" | LC_ALL=C grep -q '[^ -~]'; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "PS must contain only printable ASCII (0x20-0x7E); RDS does not carry non-ASCII text!" 8 78
		abort_action=1
		return
	elif [ "${#RDS_PS}" -gt 8 ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "PS must not exceed 8 characters!" 8 78
		abort_action=1
		return
	fi
else
	abort_action=1
	return
fi

# RT (RadioText): 1-64 ASCII chars (RDS does not carry non-ASCII text)
if RDS_RT=$(whiptail --inputbox "Enter RDS RadioText (1-64 ASCII chars):" 8 78 "$DEFAULT_RDS_RT" --title "RDS RadioText (RT)" 3>&1 1>&2 2>&3); then
	abort_action=0
	if [ -z "$RDS_RT" ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "RT cannot be empty!" 8 78
		abort_action=1
		return
	elif printf '%s' "$RDS_RT" | LC_ALL=C grep -q '[^ -~]'; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "RT must contain only printable ASCII (0x20-0x7E); RDS does not carry non-ASCII text!" 8 78
		abort_action=1
		return
	elif [ "${#RDS_RT}" -gt 64 ]; then
		whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "RT must not exceed 64 characters!" 8 78
		abort_action=1
		return
	fi
else
	abort_action=1
	return
fi

# Pre-emphasis time constant: 50 us (Eu) or 75 us (Us)
if RDS_PE=$(whiptail --default-item "$DEFAULT_RDS_PE" --title "FM pre-emphasis" --menu "Select pre-emphasis time constant:" 15 78 2 \
	"50" "50 us - Europe, Africa, Asia, Oceania (ITU regions 1/3)" \
	"75" "75 us - Americas, Japan (ITU region 2)" \
	3>&1 1>&2 2>&3); then
	abort_action=0
else
	abort_action=1
fi

}

do_enter_callsign()
{

LAST_ITEM="$menuchoice"
if CALLSIGN=$(whiptail --inputbox "Type callsign:" 8 78 "$DEFAULT_OPERA_CALLSIGN" --title "Enter callsign to transmit" 3>&1 1>&2 2>&3);  then
	abort_action=0
	if [ -z "$CALLSIGN" ]; then
    	whiptail --title "░▒▓ ERROR ▓▒░" --msgbox "Empty callsign!" 8 78
		abort_action=1
	fi
else
	abort_action=1
fi

}

do_stop_transmit()
{
	sudo killall csdr 2>/dev/null
	sudo killall freedv 2>/dev/null
	sudo killall piam 2>/dev/null
	sudo killall pichirp 2>/dev/null
	sudo killall pifmrds 2>/dev/null
	sudo killall pimorse 2>/dev/null
	sudo killall pinfm 2>/dev/null
	sudo killall piopera 2>/dev/null
	sudo killall pirfgen 2>/dev/null
	sudo killall pirtty 2>/dev/null
	sudo killall pisub 2>/dev/null
	sudo killall pissb 2>/dev/null
	sudo killall pisstv 2>/dev/null
	sudo killall pocsag 2>/dev/null
	sudo killall rpitx 2>/dev/null
	sudo killall sendiq 2>/dev/null
	sudo killall spectrumpaint 2>/dev/null
	sudo killall tune 2>/dev/null

	case "$menuchoice" in
			
			0\ *) sudo killall testvfo.sh >/dev/null 2>/dev/null ;;
			1\ *) sudo killall testchirp.sh >/dev/null 2>/dev/null ;;
			2\ *) sudo killall testspectrum.sh >/dev/null 2>/dev/null ;; 
			3\ *) sudo killall snap2spectrum.sh >/dev/null 2>/dev/null ;;
			4\ *) sudo killall testfmrds.sh >/dev/null 2>/dev/null ;;
			5\ *) sudo killall testnfm.sh >/dev/null 2>/dev/null ;;
			6\ *) sudo killall testssb.sh >/dev/null 2>/dev/null ;;
			7\ *) sudo killall testam.sh >/dev/null 2>/dev/null ;;
			8\ *) sudo killall testfreedv.sh >/dev/null 2>/dev/null ;;
			9\ *) sudo killall testsstv.sh >/dev/null 2>/dev/null ;;
			10\ *) sudo killall testpocsag.sh >/dev/null 2>/dev/null ;;
			11\ *) sudo killall testopera.sh >/dev/null 2>/dev/null ;;
			12\ *) sudo killall testrtty.sh >/dev/null 2>/dev/null ;;
			13\ *) sudo killall testmorse.sh >/dev/null 2>/dev/null ;;
			14\ *) sudo killall testrfgen.sh >/dev/null 2>/dev/null ;;
			15\ *) sudo killall testsub.sh >/dev/null 2>/dev/null ;;

	esac
}

do_status()
{
	local freq_display="${1:-$OUTPUT_FREQ}"
	LAST_ITEM="$menuchoice"
	MAS_TX_STATE=LIVE
	NEWT_COLORS="$MAS_TX_COLORS" whiptail --title "░▒▓ TX LIVE :: $LAST_ITEM @ $freq_display MHz ▓▒░" --ok-button "STOP TX" --msgbox "● TRANSMITTING ●\n\n  mode : $LAST_ITEM\n  freq : $freq_display MHz\n\nPress STOP TX to kill the carrier." 12 78
	MAS_TX_STATE=STANDBY
	do_stop_transmit
}

#********************************
# User interface initialization *
#********************************

show_banner
do_freq_setup

 while [ true ]
    do

	menuchoice=$(whiptail --default-item "$LAST_ITEM" --ok-button "ENGAGE" --cancel-button "EXIT" --title "░▒▓ mostly-a-SDR :: $OUTPUT_FREQ MHz ▓▒░" --menu "root@mostly-a-sdr:~# ./transmit --range 50kHz-1GHz   (choose your test)" 21 82 13 \
 	"F Set frequency" "Modify frequency (actual $OUTPUT_FREQ MHz)" \
	"0 Tune" "Carrier" \
    "1 Chirp" "Moving carrier" \
	"2 Spectrum" "Spectrum painting" \
	"3 RfMyFace" "Snap with Raspicam and RF paint" \
	"4 WFM" "Wideband Frequency Modulation with RDS" \
	"5 NFM" "Narrowband Frequency Modulation" \
	"6 SSB" "Single Sideband modulation" \
	"7 AM" "Amplitude Modulation" \
	"8 FreeDV" "Digital voice mode 800XA" \
	"9 SSTV" "Pattern picture" \
	"10 Pocsag" "Pager message" \
    "11 Opera" "Like morse but need Opera decoder" \
    "12 RTTY" "Radioteletype" \
    "13 CW" "Continuous Wave (Morse code)" \
    "14 RFgen" "Wideband RF generator" \
    "15 Sub-GHz" "Replay a Flipper Zero .sub RAW capture" \
 	3>&2 2>&1 1>&3)
		RET=$?
		if [ $RET -eq 1 ]; then
			whiptail --title "░▒▓ session closed ▓▒░" --msgbox "Carrier dropped.\n\nThanks for using mostly-a-SDR!" 10 78
			mas_outro
    		exit 0
		elif [ $RET -eq 0 ]; then
			case "$menuchoice" in
			
			F\ *) do_freq_setup 
			;;
			
			0\ *) testvfo.sh "$OUTPUT_FREQ""e6" >/dev/null 2>/dev/null &
			do_status
			;;
			
			1\ *) testchirp.sh "$OUTPUT_FREQ""e6" >/dev/null 2>/dev/null &
			do_status
			;;
			
			2\ *) do_file_choose "320x256 .jpg" "$RESOURCES_LOCATION" '\.jpg$'
			if [ $abort_action -eq 0 ]; then
				testspectrum.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" >/dev/null 2>/dev/null &
				do_status
			fi
			;;
			
			3\ *) snap2spectrum.sh "$OUTPUT_FREQ""e6" >/dev/null 2>/dev/null &
			do_status
			;;
			
			4\ *) do_file_choose "audio (.aif, .aiff, .caf, .flac, .mp3, .wav)" "$RESOURCES_LOCATION" "$AUDIO_FILE_PATTERN"
			if [ $abort_action -eq 0 ]; then
				do_enter_rds_params
				if [ $abort_action -eq 0 ]; then
					do_enter_playback_mode
					if [ $abort_action -eq 0 ]; then
						testfmrds.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" "$PLAYBACK_MODE" "$RDS_PI" "$RDS_PS" "$RDS_RT" "$RDS_PE" >/dev/null 2>/dev/null &
						do_status
					fi
				fi
			fi
			;;

			5\ *) do_file_choose "audio (.aif, .aiff, .caf, .flac, .mp3, .wav)" "$RESOURCES_LOCATION" "$AUDIO_FILE_PATTERN"
			if [ $abort_action -eq 0 ]; then
				do_enter_nfm_mode
				if [ $abort_action -eq 0 ]; then
					do_enter_playback_mode
					if [ $abort_action -eq 0 ]; then
						testnfm.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" "$PLAYBACK_MODE" "${NFM_MODE,,}" >/dev/null 2>/dev/null &
						do_status
					fi
				fi
			fi
			;;
			
			6\ *) do_file_choose "audio (.aif, .aiff, .caf, .flac, .mp3, .wav)" "$RESOURCES_LOCATION" "$AUDIO_FILE_PATTERN"
			if [ $abort_action -eq 0 ]; then
				do_enter_ssb_sideband
				if [ $abort_action -eq 0 ]; then
					do_enter_playback_mode
					if [ $abort_action -eq 0 ]; then
						testssb.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" "$PLAYBACK_MODE" "${SSB_SIDEBAND,,}" >/dev/null 2>/dev/null &
						do_status
					fi
				fi
			fi
			;;
			
			7\ *) do_file_choose "audio (.aif, .aiff, .caf, .flac, .mp3, .wav)" "$RESOURCES_LOCATION" "$AUDIO_FILE_PATTERN"
			if [ $abort_action -eq 0 ]; then
				do_enter_playback_mode
				if [ $abort_action -eq 0 ]; then
					testam.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" "$PLAYBACK_MODE" >/dev/null 2>/dev/null &
					do_status
				fi
			fi
			;;
			
			8\ *) do_file_choose "FreeDV .rf" "$RESOURCES_LOCATION" '\.rf$'
			if [ $abort_action -eq 0 ]; then
				testfreedv.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" >/dev/null 2>/dev/null &
				do_status
			fi
			;;
			
			9\ *) do_file_choose "320x256 .jpg" "$RESOURCES_LOCATION" '\.jpg$'
			if [ $abort_action -eq 0 ]; then
				testsstv.sh "$OUTPUT_FREQ""e6" "$FILE_LOC" >/dev/null 2>/dev/null &
				do_status
			fi
			;;
			
			10\ *) do_enter_message "POCSAG (ADDR:MESSAGE_BODY)" "$DEFAULT_POCSAG_MESSAGE"
			if [ $abort_action -eq 0 ]; then
				testpocsag.sh "$OUTPUT_FREQ""e6" "$MESSAGE" >/dev/null 2>/dev/null &
				do_status
			fi
			;;

			11\ *) do_enter_callsign
			if [ $abort_action -eq 0 ]; then
				testopera.sh "$OUTPUT_FREQ""e6" "$CALLSIGN" >/dev/null 2>/dev/null &
				do_status
			fi
			;;

			12\ *) do_enter_message "RTTY" "$DEFAULT_RTTY_MESSAGE"
			if [ $abort_action -eq 0 ]; then
				testrtty.sh "$OUTPUT_FREQ""e6" "$MESSAGE" >/dev/null 2>/dev/null &
				do_status
			fi
			;;

			13\ *) do_enter_message "CW" "$DEFAULT_CW_MESSAGE"
			if [ $abort_action -eq 0 ]; then
				do_enter_wpm
				if [ $abort_action -eq 0 ]; then
					testmorse.sh "$OUTPUT_FREQ""e6" "$CW_WPM" "$MESSAGE" >/dev/null 2>/dev/null &
					do_status
				fi
			fi
			;;

			14\ *) do_enter_rfgen_params
			if [ $abort_action -eq 0 ]; then
				testrfgen.sh "$OUTPUT_FREQ""e6" "$RFGEN_BW" "$DEFAULT_RFGEN_SAMPLE_RATE" "${RFGEN_MODE,,}" "$MULTITONE_TONES" >/dev/null 2>/dev/null &
				do_status
			fi
			;;

			15\ *) do_file_choose "Flipper Zero .sub RAW capture" "$SUB_FILES_LOCATION" '\.sub$'
			if [ $abort_action -eq 0 ]; then
				SUB_FREQ_MHZ=$(do_sub_file_frequency_mhz "$FILE_LOC")
				do_enter_playback_mode
				if [ $abort_action -eq 0 ]; then
					REPEAT_COUNT=1
					if [ "$PLAYBACK_MODE" = "once" ]; then
						do_enter_repeat_count
					fi
					if [ $abort_action -eq 0 ]; then
						if [ -n "$SUB_FREQ_MHZ" ]; then
							whiptail --title "Sub-GHz replay" --msgbox "This capture will transmit on ${SUB_FREQ_MHZ} MHz - the frequency stored in the file itself, not the ${OUTPUT_FREQ} MHz set above.\n\nOnly transmit captures you own or are authorized to send." 11 78
						else
							whiptail --title "Sub-GHz replay" --msgbox "Couldn't find a Frequency: field in this file, so the actual transmit frequency depends entirely on testsub.sh/pisub - not the ${OUTPUT_FREQ} MHz set above.\n\nOnly transmit captures you own or are authorized to send." 11 78
						fi
						testsub.sh "$FILE_LOC" "$PLAYBACK_MODE" "$REPEAT_COUNT" >/dev/null 2>/dev/null &
						do_status "${SUB_FREQ_MHZ:-$OUTPUT_FREQ}"
					fi
				fi
			fi
			;;

			esac
		else
			exit 1
		fi
    done
	exit 0

#!/bin/bash

# ----------------------------------------------------------
# mostly-a-SDR theme: neon green / neon pink on black
# (same palette, banner and backtitle as start.sh)
# ----------------------------------------------------------
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

# Every whiptail dialog below gets the same "mostly-a-SDR" backtitle as start.sh.
whiptail()
{
	command whiptail --backtitle "mostly-a-SDR - Made for mostlyawesome.de" "$@"
}

# Green-gradient block logo inside a neon-pink "terminal" frame (ANSI 256-color).
# Only emitted to an interactive terminal so piped / logged output stays clean.
show_banner()
{
	[ -t 1 ] || return 0

	local pink=$'\033[38;5;198m'
	local dim=$'\033[38;5;240m'
	local reset=$'\033[0m'
	local grad=(157 121 84 47 41 35 157 121 84 47 41 35)
	local line i=0

	printf '%s' "$pink"
	printf '┌─[ root@mostly-a-sdr:~# ./rtl-sdr --transponder ]───────────────────░▒▓█▓▒░─┐\n'
	printf '%s│%s\n' "$pink" "$reset"
	while IFS= read -r line; do
		printf '%s│ %s\033[1;38;5;%sm%s%s\n' "$pink" "$reset" "${grad[i]}" "$line" "$reset"
		i=$((i + 1))
	done <<'BANNER'
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
BANNER
	printf '%s│%s\n' "$pink" "$reset"
	printf '%s│ %s[%s+%s]%s rtl-sdr bridge :: raspberry pi :: record / replay / transpond / decode\n' "$pink" "$dim" "$pink" "$dim" "$reset"
	printf '%s│ %s[%s+%s]%s tx armed. know your local laws. transmit responsibly.\n' "$pink" "$dim" "$pink" "$dim" "$reset"
	printf '%s└─░▒▓█▓▒░────────────────────────────────────────────────────────────░▒▓█▓▒░─┘%s\n' "$pink" "$reset"
}

status="0"
INPUT_RTLSDR=434.0
INPUT_GAIN=35
OUTPUT_FREQ=434.0
LAST_ITEM="0 Record"

# --- rtl_433 decoder / signal library -------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDRTOOL="$SCRIPT_DIR/sdrtool.py"
SIGNAL_DIR="$SCRIPT_DIR/signals"          # captured I/Q (.cu8), notes, packet models
SUB_DIR="$SIGNAL_DIR/sub"                 # exported Flipper Zero .sub files
DECODE_FREQ=433.92
TOOL_OUT=""

do_freq_setup()
{

if FREQ=$(whiptail --inputbox "Choose input Frequency (in MHz). Default is 434 MHz" 8 78 $INPUT_RTLSDR --title "RTL-SDR receive frequency" 3>&1 1>&2 2>&3); then
    INPUT_RTLSDR=$FREQ
fi

if GAIN=$(whiptail --inputbox "Choose input Gain (0(AGC) or 1-45)" 8 78 $INPUT_GAIN --title "RTL-SDR receive gain" 3>&1 1>&2 2>&3); then
    INPUT_GAIN=$GAIN
fi

if FREQ=$(whiptail --inputbox "Choose output Frequency (in MHz). Default is 434 MHz" 8 78 $OUTPUT_FREQ --title "mostly-a-SDR transmit frequency" 3>&1 1>&2 2>&3); then
    OUTPUT_FREQ=$FREQ
fi

}

do_stop()
{
	sudo killall rtl_sdr 2>/dev/null
	sudo killall sendiq 2>/dev/null
	sudo killall rtl_fm 2>/dev/null
	sudo killall rtl_433 2>/dev/null
}
do_status()
{
	 LAST_ITEM="$menuchoice"
	whiptail --title "Transmit ""$LAST_ITEM"" on ""$OUTPUT_FREQ"" MHz" --msgbox "Transmitting" 8 78
	do_stop
}

# ----------------------------------------------------------
# helpers
# ----------------------------------------------------------
need_tool()
{
	command -v "$1" >/dev/null 2>&1 && return 0
	whiptail --title "Missing: $1" --msgbox "$2" 12 78
	return 1
}

# Run sdrtool.py; output lands in $TOOL_OUT, errors are shown in a message box.
tool_try()
{
	if ! TOOL_OUT=$(python3 "$SDRTOOL" "$@" 2>&1); then
		whiptail --title "sdrtool" --msgbox "$TOOL_OUT" 14 78
		return 1
	fi
	return 0
}

# Cached one-line rtl_433 summary of a capture ("Nexus-TH id=90 ch=1 21.3C 45%").
signal_summary()
{
	local f="$1" c="${1%.cu8}.info" s
	if [ ! -s "$c" ]; then
		s=$(python3 "$SDRTOOL" info "$f" 2>/dev/null)
		case "$s" in
			"("*) printf '%s' "$s"; return;;   # don't cache "not decoded" / "not installed"
		esac
		printf '%s\n' "$s" > "$c"
	fi
	cat "$c"
}

# Replay an I/Q capture (.cu8 = u8 I/Q, 250 kS/s) with sendiq, like "1 Play".
tx_iq()
{
	local f="$1" mhz loop=()
	mhz=$(python3 "$SDRTOOL" freq "$f" 2>/dev/null)
	mhz=$(whiptail --inputbox "Transmit frequency (in MHz)" 8 78 "${mhz:-$OUTPUT_FREQ}" --title "Replay $(basename "$f")" 3>&1 1>&2 2>&3) || return
	if whiptail --title "Repeat?" --yesno "Repeat the signal until you stop it?" 8 60; then
		loop=(-l)
	fi
	do_stop
	sudo sendiq -s 250000 -f "$mhz"e6 -t u8 "${loop[@]}" -i "$f" >/dev/null 2>/dev/null &
	whiptail --title "Transmit $(basename "$f") on $mhz MHz" --msgbox "Transmitting - press OK to stop" 8 78
	do_stop
}

# ----------------------------------------------------------
# 5 Decode: rtl_433 in the foreground (Ctrl+C to stop)
# ----------------------------------------------------------
do_decode()
{
	need_tool rtl_433 "rtl_433 is not installed.\n\nInstall it with:\n  sudo apt install rtl-433\n\nor build it from https://github.com/merbanan/rtl_433" || return

	local mhz save before after saveopt=()
	mhz=$(whiptail --inputbox "Frequency to decode (in MHz).\n433.92 is the usual ISM band for weather stations, remotes, doorbells ...\n(868.3 / 915 also work for many devices)" 11 78 "$DECODE_FREQ" --title "rtl_433 decoder" 3>&1 1>&2 2>&3) || return
	DECODE_FREQ="$mhz"

	save=$(whiptail --title "Save received signals" --radiolist "Save received bursts as I/Q files? Saved signals can be exported as Flipper .sub, edited and replayed." 14 78 3 \
		"known" "Only signals rtl_433 could decode" ON \
		"all" "Every burst (unknown devices too, can get noisy)" OFF \
		"none" "Don't save, just decode" OFF 3>&1 1>&2 2>&3) || return
	[ "$save" != "none" ] && saveopt=(-S "$save")

	mkdir -p "$SIGNAL_DIR"
	before=$(ls "$SIGNAL_DIR"/*.cu8 2>/dev/null | wc -l)
	do_stop
	clear
	printf '\033[38;5;198m[+]\033[0m rtl_433 listening on \033[1;38;5;47m%s MHz\033[0m (gain %s) - press \033[1;38;5;198mCtrl+C\033[0m to stop\n\n' "$DECODE_FREQ" "$INPUT_GAIN"

	# Ctrl+C must only stop rtl_433, not this menu.
	trap ':' INT
	( cd "$SIGNAL_DIR" && exec stdbuf -oL rtl_433 -f "${DECODE_FREQ}M" -s 250k -g "$INPUT_GAIN" -M level -C si "${saveopt[@]}" -F kv 2>&1 ) | tee "$SIGNAL_DIR/live.log"
	trap - INT
	do_stop

	after=$(ls "$SIGNAL_DIR"/*.cu8 2>/dev/null | wc -l)
	whiptail --title "Decoder stopped" --msgbox "Saved $((after - before)) new signal(s) in:\n$SIGNAL_DIR\n\nOpen '6 Signals' to export them as .sub, edit values or replay." 12 78
}

# ----------------------------------------------------------
# 6 Signals: library of captured signals
# ----------------------------------------------------------
do_signals()
{
	need_tool python3 "python3 is required for the signal tools.\n\n  sudo apt install python3" || return
	local items f sel
	while true; do
		items=()
		for f in "$SIGNAL_DIR"/*.cu8; do
			[ -e "$f" ] || continue
			items+=("$(basename "$f")" "$(signal_summary "$f")")
		done
		if [ ${#items[@]} -eq 0 ]; then
			whiptail --title "Signals" --msgbox "No captured signals yet.\n\nUse '5 Decode' and let rtl_433 save the signals it receives." 10 78
			return
		fi
		sel=$(whiptail --title "Captured signals" --menu "Choose a signal ($SIGNAL_DIR)" 22 96 14 "${items[@]}" 3>&1 1>&2 2>&3) || return
		signal_actions "$SIGNAL_DIR/$sel"
	done
}

signal_actions()
{
	local f="$1" base="${1%.cu8}" act mode out tmp
	while true; do
		[ -e "$f" ] || return
		act=$(whiptail --title "$(basename "$f")" --menu "$(signal_summary "$f")" 18 82 6 \
			"1 Details" "Full rtl_433 decode of this signal" \
			"2 Export .sub" "Save as Flipper Zero SubGHz RAW file" \
			"3 Edit values" "Change temperature, humidity, id ... and re-encode" \
			"4 Transmit" "Replay this capture unchanged" \
			"5 Delete" "Remove this signal" \
			3>&1 1>&2 2>&3) || return

		case "$act" in
			1\ *)
				tmp=$(mktemp)
				if command -v rtl_433 >/dev/null 2>&1; then
					rtl_433 -r "$f" -s 250k -F kv 2>/dev/null > "$tmp"
				fi
				[ -s "$tmp" ] || echo "rtl_433 could not decode this signal (or is not installed)." > "$tmp"
				whiptail --title "Details" --scrolltext --textbox "$tmp" 22 82
				rm -f "$tmp";;
			2\ *)
				mode=$(whiptail --title "Modulation" --radiolist "Modulation of the signal (sets the Flipper preset)" 11 78 2 \
					"ook" "OOK / ASK - most 433 MHz weather stations" ON \
					"fsk" "2-FSK" OFF 3>&1 1>&2 2>&3) || continue
				out="$SUB_DIR/$(basename "$base").sub"
				tool_try sub "$f" "$out" --mode "$mode" && whiptail --title "Export .sub" --msgbox "$TOOL_OUT" 14 78;;
			3\ *)
				edit_signal "$f";;
			4\ *)
				tx_iq "$f";;
			5\ *)
				if whiptail --title "Delete" --yesno "Delete $(basename "$f") ?" 8 60; then
					rm -f "$f" "$base.info" "$base.pkt.json"
					return
				fi;;
		esac
	done
}

# ----------------------------------------------------------
# Value editor: slice the capture into bits, change fields, re-encode
# ----------------------------------------------------------
edit_signal()
{
	local f="$1" base="${1%.cu8}"
	local pkt="${1%.cu8}.pkt.json" edited="${1%.cu8}_edited.cu8"
	local sub="$SUB_DIR/$(basename "${1%.cu8}")_edited.sub"
	local items name val sel new crc hex tmp
	declare -A cur

	if [ ! -s "$pkt" ]; then
		tool_try analyze "$f" "$pkt" || { rm -f "$pkt"; return; }
		whiptail --title "Edit values" --msgbox "$TOOL_OUT" 14 78
	fi

	while true; do
		items=()
		cur=()
		while IFS='|' read -r name val; do
			items+=("$name" "$val")
			cur[$name]="$val"
		done < <(python3 "$SDRTOOL" fields "$pkt" 2>/dev/null)
		crc=$(python3 "$SDRTOOL" checksum "$pkt" 2>/dev/null)
		hex=$(python3 "$SDRTOOL" hex "$pkt" 2>/dev/null)
		items+=("#hex" "Raw data bits: $hex" \
			"#field" "Define / add a custom field" \
			"#crc" "Checksum rule: $crc" \
			"#keeloq" "Decode as KeeLoq (rolling-code remote)" \
			"#render" "Render edited signal (.cu8 + .sub) and check it with rtl_433" \
			"#send" "Transmit the edited signal")

		sel=$(whiptail --title "Edit $(basename "$f")" --menu "Pick a value to change. All repeats of the packet get the new data." 22 96 12 "${items[@]}" 3>&1 1>&2 2>&3) || return

		case "$sel" in
			"#hex")
				new=$(whiptail --inputbox "Raw data bits as hex (same number of digits)" 9 78 "$hex" --title "Raw data" 3>&1 1>&2 2>&3) || continue
				tool_try sethex "$pkt" "$new";;
			"#field")
				new=$(whiptail --inputbox "name offset length signed(0/1) divisor bias\n\nvalue = (raw - bias) / divisor. Example (Nexus temperature):\ntemperature_C 12 12 1 10 0" 13 78 "" --title "Custom field" 3>&1 1>&2 2>&3) || continue
				tool_try addfield "$pkt" "$new";;
			"#crc")
				new=$(whiptail --inputbox "KIND FIRST_BYTE END_BYTE TARGET_BYTE\nKIND: sum8 | xor8 | crc8:POLY:INIT (hex), e.g.  crc8:31:00 0 4 4\nType none to disable." 11 78 "$crc" --title "Checksum" 3>&1 1>&2 2>&3) || continue
				tool_try checksum "$pkt" "$new";;
			"#keeloq")
				new=$(whiptail --inputbox "64-bit manufacturer key in hex (leave empty to just show\nthe plaintext serial + encrypted hop code, no decrypt)." 10 78 "" --title "KeeLoq decode" 3>&1 1>&2 2>&3) || continue
				tmp=$(mktemp)
				if [ -n "$new" ]; then
					python3 "$SDRTOOL" keeloq "$pkt" --key "$new" > "$tmp" 2>&1
				else
					python3 "$SDRTOOL" keeloq "$pkt" > "$tmp" 2>&1
				fi
				whiptail --title "KeeLoq" --scrolltext --textbox "$tmp" 22 82
				rm -f "$tmp";;
			"#render")
				tool_try render "$pkt" "$edited" --sub "$sub" || continue
				tmp=$(mktemp)
				{
					echo "$TOOL_OUT"
					echo
					echo "--- rtl_433 decode of the edited signal ---"
					rtl_433 -r "$edited" -s 250k -F kv 2>/dev/null || echo "(rtl_433 not available)"
				} > "$tmp"
				whiptail --title "Edited signal" --scrolltext --textbox "$tmp" 22 82
				rm -f "$tmp";;
			"#send")
				tool_try render "$pkt" "$edited" --sub "$sub" || continue
				tx_iq "$edited";;
			*)
				new=$(whiptail --inputbox "New value for $sel" 8 78 "${cur[$sel]}" --title "Edit $sel" 3>&1 1>&2 2>&3) || continue
				tool_try set "$pkt" "$sel" "$new";;
		esac
	done
}

show_banner
do_freq_setup

 while [ "$status" -eq 0 ]
    do

 menuchoice=$(whiptail --default-item "$LAST_ITEM" --title "mostly-a-SDR with RTL-SDR" --menu "Record, replay, transpond, decode. Choose your test:" 20 82 12 \
	"0 Record" "Record spectrum on $INPUT_RTLSDR MHz" \
	"1 Play" "Replay spectrum" \
	"2 Transponder" "Transmit $INPUT_RTLSDR MHz to ""$OUTPUT_FREQ"" MHz" \
	"3 Fm->SSB" "Transcode FM $INPUT_RTLSDR MHz to ""$OUTPUT_FREQ"" MHz" \
	"4 Set frequency" "Modify frequency (actual $INPUT_RTLSDR MHz)" \
	"5 Decode" "rtl_433: weather stations & 433 MHz devices" \
	"6 Signals" "Saved signals: export .sub, edit values, replay" \
	3>&2 2>&1 1>&3)

        case "$menuchoice" in
		0\ *) rtl_sdr -s 250000 -g "$INPUT_GAIN" -f "$INPUT_RTLSDR"e6 record.iq >/dev/null 2>/dev/null &
		do_status;;
		1\ *) sudo sendiq -s 250000 -f "$OUTPUT_FREQ"e6 -t u8 -i record.iq >/dev/null 2>/dev/null &
		do_status;;
		2\ *) FREQ_IN="$INPUT_RTLSDR"M GAIN="$INPUT_GAIN" FREQ_OUT="$OUTPUT_FREQ"e6 . transponder.sh >/dev/null 2>/dev/null &
		do_status;;
		3\ *) FREQ_IN="$INPUT_RTLSDR"M GAIN="$INPUT_GAIN" FREQ_OUT="$OUTPUT_FREQ"e6 . fm2ssb.sh >/dev/null 2>/dev/null &
		do_status;;
		4\ *)
		do_freq_setup;;
		5\ *) LAST_ITEM="$menuchoice"
		do_decode;;
		6\ *) LAST_ITEM="$menuchoice"
		do_signals;;
		*)	 status=1
		whiptail --title "Bye bye" --msgbox "Thanks for using mostly-a-SDR!" 8 78
		;;
        esac
    done

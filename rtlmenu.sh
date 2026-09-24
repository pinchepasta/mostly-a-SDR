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
	printf '%s│ %s[%s+%s]%s rtl-sdr bridge :: raspberry pi :: record / replay / transpond\n' "$pink" "$dim" "$pink" "$dim" "$reset"
	printf '%s│ %s[%s+%s]%s tx armed. know your local laws. transmit responsibly.\n' "$pink" "$dim" "$pink" "$dim" "$reset"
	printf '%s└─░▒▓█▓▒░────────────────────────────────────────────────────────────░▒▓█▓▒░─┘%s\n' "$pink" "$reset"
}

status="0"
INPUT_RTLSDR=434.0
INPUT_GAIN=35
OUTPUT_FREQ=434.0
LAST_ITEM="0 Record"

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
}
do_status()
{
	 LAST_ITEM="$menuchoice"
	whiptail --title "Transmit ""$LAST_ITEM"" on ""$OUTPUT_FREQ"" MHz" --msgbox "Transmitting" 8 78
	do_stop
}

show_banner
do_freq_setup

 while [ "$status" -eq 0 ]
    do

 menuchoice=$(whiptail --default-item "$LAST_ITEM" --title "mostly-a-SDR with RTL-SDR" --menu "Record, replay, transpond. Choose your test:" 20 82 12 \
	"0 Record" "Record spectrum on $INPUT_RTLSDR MHz" \
	"1 Play" "Replay spectrum" \
	"2 Transponder" "Transmit $INPUT_RTLSDR MHz to ""$OUTPUT_FREQ"" MHz" \
	"3 Fm->SSB" "Transcode FM $INPUT_RTLSDR MHz to ""$OUTPUT_FREQ"" MHz" \
	"4 Set frequency" "Modify frequency (actual $INPUT_RTLSDR MHz)" \
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
		*)	 status=1
		whiptail --title "Bye bye" --msgbox "Thanks for using mostly-a-SDR!" 8 78
		;;
        esac
    done

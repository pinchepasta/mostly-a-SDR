#!/bin/bash

# Author: Ihar Yatsevich <igor.nikolaevich.96@gmail.com>
# Date: 20.09.2026
# License: GPL-3.0
# Fork: https://github.com/IgrikXD/rpitx-ui
# RF transmitter for Raspberry Pi with improved UI functionality, built with CMake.

# Usage: testsub.sh <file.sub> <playback_mode> [repeat]
#   <playback_mode>  once | loop
#   [repeat]         Bursts to send in "once" mode (default: 1)
#
# The carrier frequency is read from the file's own "Frequency:" field, not
# passed in here, since a Sub-GHz capture only reproduces the original
# signal when replayed on the frequency it was recorded on.
FILE_LOC="$1"
PLAYBACK_MODE="$2"
REPEAT="${3:-1}"

sudo pisub --file "$FILE_LOC" --playback "$PLAYBACK_MODE" --repeat "$REPEAT"

/**
 * @file pisub.h
 * @brief Parameters for the .sub (Flipper Zero SubGHz RAW) file transmitter.
 *
 * @author Ihar Yatsevich <igor.nikolaevich.96@gmail.com>
 * @date 20.09.2026
 * @copyright GPL-3.0
 * @see https://github.com/IgrikXD/rpitx-ui
 * @note RF transmitter for Raspberry Pi with improved UI functionality, built with CMake.
 */

#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace pisub {
    /// Minimum pulse/gap duration (in microseconds) supported by librpitx's ookbursttiming.
    inline constexpr int MIN_DURATION_US{10};

    /// Playback mode requested on the command line.
    enum class PlaybackMode {
        Once,  ///< Send the captured timing once (repeated --repeat times) and exit.
        Loop   ///< Resend the captured timing continuously until SIGINT / SIGTERM.
    };

    /// Fully parsed command-line + file parameters for a single pisub run.
    struct SubFileParameters {
        std::string filePath;                    ///< Path to the .sub file to transmit.
        std::optional<std::uint64_t> freqOverride;  ///< Optional --freq override in Hz.
        PlaybackMode playback{PlaybackMode::Once};  ///< once | loop.
        int repeat{1};                            ///< Number of times to resend in "once" mode.
        int pauseMs{100};                         ///< Pause between repeats, in milliseconds.
    };
}  // namespace pisub

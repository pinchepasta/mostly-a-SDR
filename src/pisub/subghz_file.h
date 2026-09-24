/**
 * @file subghz_file.h
 * @brief Parser for the Flipper Zero "SubGHz RAW File" (.sub) text format.
 *
 * The .sub format is a plain-text key/value file. The fields pisub cares
 * about are:
 *
 *   Filetype: Flipper SubGhz RAW File
 *   Version: 1
 *   Frequency: 433920000
 *   Preset: FuriHalSubGhzPresetOok650Async
 *   Protocol: RAW
 *   RAW_Data: 100 -200 300 -450 ...
 *
 * RAW_Data holds one or more lines of whitespace-separated signed integers,
 * each a duration in microseconds: a positive value is carrier ON for that
 * long, a negative value is carrier OFF (silence) for abs(value) long. A
 * file may contain several RAW_Data lines; they are concatenated in file
 * order into a single timing sequence. This parser only understands the
 * RAW protocol - it does not decode higher-level Flipper protocols (the
 * many vendor-specific key-fob/remote encodings), it only replays the raw
 * pulse/gap timing exactly as captured.
 *
 * This parser is deliberately independent of librpitx so it can be
 * exercised without any RF hardware; pisub.cpp converts its output into
 * the ookbursttiming::SampleOOKTiming sequence actually sent over the air.
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
#include <vector>

namespace pisub {
    /// Result of parsing a .sub file.
    struct SubFileData {
        std::uint64_t frequencyHz{0};  ///< From the "Frequency:" line (0 if missing).
        std::string preset;            ///< From the "Preset:" line, informational only.
        std::vector<std::int32_t> rawDurations;  ///< Concatenated RAW_Data values, in microseconds.
    };

    /**
     * @brief Parse a Flipper Zero .sub file from disk.
     *
     * @param path Path to the .sub file.
     * @param error Set to a human-readable message on failure.
     * @return Parsed data on success, std::nullopt on failure (file missing,
     *         unreadable, no RAW_Data found, or RAW_Data contains a token
     *         that is not a valid signed integer).
     */
    [[nodiscard]] std::optional<SubFileData> parseSubFile(const std::string& path, std::string& error);
}  // namespace pisub

/**
 * @file subghz_file.cpp
 * @brief Implementation of the Flipper Zero .sub file parser.
 *
 * @author Ihar Yatsevich <igor.nikolaevich.96@gmail.com>
 * @date 20.09.2026
 * @copyright GPL-3.0
 * @see https://github.com/IgrikXD/rpitx-ui
 * @note RF transmitter for Raspberry Pi with improved UI functionality, built with CMake.
 */

#include "subghz_file.h"

#include <charconv>
#include <fstream>
#include <sstream>

namespace pisub {
    namespace {
        std::string trim(const std::string& s) {
            const auto begin{s.find_first_not_of(" \t\r\n")};
            if (begin == std::string::npos) {
                return "";
            }
            const auto end{s.find_last_not_of(" \t\r\n")};
            return s.substr(begin, end - begin + 1);
        }

        bool startsWith(const std::string& s, const std::string& prefix) {
            return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
        }
    }  // namespace

    std::optional<SubFileData> parseSubFile(const std::string& path, std::string& error) {
        std::ifstream in(path);
        if (!in.is_open()) {
            error = "could not open '" + path + "'";
            return std::nullopt;
        }

        SubFileData data;
        bool sawRawData{false};
        std::string line;
        std::size_t lineNo{0};

        while (std::getline(in, line)) {
            ++lineNo;
            const std::string trimmed{trim(line)};
            if (trimmed.empty()) {
                continue;
            }

            if (startsWith(trimmed, "Frequency:")) {
                const std::string valueText{trim(trimmed.substr(std::string("Frequency:").size()))};
                std::uint64_t freq{0};
                const auto [ptr, ec]{std::from_chars(valueText.data(), valueText.data() + valueText.size(), freq)};
                if (ec != std::errc{}) {
                    error = "line " + std::to_string(lineNo) + ": invalid Frequency value '" + valueText + "'";
                    return std::nullopt;
                }
                data.frequencyHz = freq;
                continue;
            }

            if (startsWith(trimmed, "Preset:")) {
                data.preset = trim(trimmed.substr(std::string("Preset:").size()));
                continue;
            }

            if (startsWith(trimmed, "RAW_Data:")) {
                sawRawData = true;
                std::istringstream tokens(trimmed.substr(std::string("RAW_Data:").size()));
                std::string token;
                while (tokens >> token) {
                    std::int32_t value{0};
                    const auto [ptr, ec]{std::from_chars(token.data(), token.data() + token.size(), value)};
                    if (ec != std::errc{} || ptr != token.data() + token.size()) {
                        error = "line " + std::to_string(lineNo) + ": invalid RAW_Data token '" + token + "'";
                        return std::nullopt;
                    }
                    data.rawDurations.push_back(value);
                }
                continue;
            }

            // Filetype / Version / Protocol / any other key are informational
            // only - accepted and ignored so future format additions don't
            // break existing captures.
        }

        if (!sawRawData || data.rawDurations.empty()) {
            error = "no RAW_Data found in '" + path + "' - only the Flipper Zero RAW protocol is supported";
            return std::nullopt;
        }

        if (data.frequencyHz == 0) {
            error = "no valid Frequency found in '" + path + "'";
            return std::nullopt;
        }

        return data;
    }
}  // namespace pisub

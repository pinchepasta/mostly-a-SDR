/**
 * @file pisub.cpp
 * @brief Flipper Zero .sub (SubGHz RAW File) transmitter implementation.
 *
 * Parses the RAW_Data pulse/gap timing embedded in a .sub file and replays
 * it as On-Off-Keying (OOK) via librpitx's ookbursttiming, the same
 * mechanism the upstream "sendook" tool uses for its hand-typed bit
 * strings - pisub simply sources the timing from a captured file instead.
 * Only the RAW protocol is understood: higher-level Flipper protocols
 * (vendor-specific decodings) are not parsed, so pisub can only ever
 * replay exactly the timing that was captured, nothing more.
 *
 * Transmission runs until SIGTERM / SIGINT (the rpitx-ui launcher stops
 * the process centrally via killall when the user dismisses the dialog),
 * or until the requested number of repeats has been sent in "once" mode.
 *
 * @note Usage: pisub --file <path.sub> [--freq <Hz>] [--playback once|loop]
 *                     [--repeat <n>] [--pause-ms <ms>] [-h | --help]
 *   - --file        Path to a Flipper Zero .sub RAW capture file
 *   - --freq        Override the carrier frequency in Hz (default: taken
 *                    from the file's "Frequency:" field)
 *   - --playback     "once" sends --repeat bursts and exits, "loop" resends
 *                    continuously until stopped (default: once)
 *   - --repeat       Number of bursts to send in "once" mode (default: 1)
 *   - --pause-ms     Pause between bursts, in milliseconds (default: 100)
 *   - -h, --help     Print this help message and exit
 *
 * @warning This mode retransmits arbitrary pre-recorded RF timing. Only
 *   transmit signals you own or are otherwise authorized to send - for
 *   example your own garage door, gate, or remote-controlled device, or
 *   signals captured as part of authorized security testing. Retransmitting
 *   captures of equipment you do not own or control without authorization
 *   may be illegal in your jurisdiction.
 *
 * @author Ihar Yatsevich <igor.nikolaevich.96@gmail.com>
 * @date 20.09.2026
 * @copyright GPL-3.0
 * @see https://github.com/IgrikXD/rpitx-ui
 * @note RF transmitter for Raspberry Pi with improved UI functionality, built with CMake.
 */

#include "pisub.h"
#include "subghz_file.h"

#include <librpitx/librpitx.h>

#include <CLI/CLI.hpp>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "cli_common.h"
#include "cli_validators.h"

namespace pisub {
    namespace {
        /// @see pichirp.cpp for why int (not bool) is used here.
        std::atomic<int> running{1};
        static_assert(std::atomic<int>::is_always_lock_free,
                      "std::atomic<int> must be lock-free for signal-handler access");
    }  // namespace

    void handleSignal([[maybe_unused]] int sig) {
        running.store(0, std::memory_order_relaxed);
    }

    rpitx::cli::ParseResult parseArgs(int argc, char* argv[], SubFileParameters& params) {
        CLI::App app{"Flipper Zero .sub (SubGHz RAW File) transmitter"};

        app.add_option("--file", params.filePath, ".sub file to transmit")->required()->check(CLI::ExistingFile);

        std::string freqText;
        app.add_option("--freq", freqText, "Override carrier frequency in Hz (default: from the file)")
            ->check(rpitx::cli::validators::FrequencyHz);

        std::string playbackText{"once"};
        app.add_option("--playback", playbackText, "once | loop")
            ->check(CLI::IsMember({"once", "loop"}));

        app.add_option("--repeat", params.repeat, "Bursts to send in \"once\" mode")
            ->check(CLI::PositiveNumber);

        app.add_option("--pause-ms", params.pauseMs, "Pause between bursts, in milliseconds")
            ->check(CLI::NonNegativeNumber);

        if (const auto result{rpitx::cli::parseCliApp(app, argc, argv)}; result != rpitx::cli::ParseResult::Ok) {
            return result;
        }

        if (!freqText.empty()) {
            std::uint64_t freq{0};
            if (const auto result{rpitx::cli::assignFrequencyHz(freqText, freq)};
                result != rpitx::cli::ParseResult::Ok) {
                return result;
            }
            params.freqOverride = freq;
        }

        params.playback = (playbackText == "loop") ? PlaybackMode::Loop : PlaybackMode::Once;

        return rpitx::cli::ParseResult::Ok;
    }

    int run(int argc, char* argv[]) {
        SubFileParameters params;
        switch (parseArgs(argc, argv, params)) {
            case rpitx::cli::ParseResult::Ok:
                break;
            case rpitx::cli::ParseResult::Help:
                return 0;
            case rpitx::cli::ParseResult::Error:
                return 1;
        }

        std::string parseError;
        const auto fileData{parseSubFile(params.filePath, parseError)};
        if (!fileData) {
            std::cerr << "[ERROR] pisub: " << parseError << std::endl;
            return 1;
        }

        const std::uint64_t frequencyHz{params.freqOverride.value_or(fileData->frequencyHz)};

        // Convert the file's signed microsecond durations into OOK timing
        // samples. ookbursttiming has a hard floor of MIN_DURATION_US; real
        // captures can contain shorter glitches than that, so they are
        // clamped up rather than rejecting the whole file. Zero-length
        // entries (which carry no information) are dropped.
        std::vector<ookbursttiming::SampleOOKTiming> message;
        message.reserve(fileData->rawDurations.size());
        std::uint64_t totalDurationUs{0};
        for (const std::int32_t raw: fileData->rawDurations) {
            if (raw == 0) {
                continue;
            }
            ookbursttiming::SampleOOKTiming sample{};
            sample.value = (raw > 0) ? 1 : 0;
            const int magnitude{raw > 0 ? raw : -raw};
            sample.duration = (magnitude < MIN_DURATION_US) ? MIN_DURATION_US : magnitude;
            totalDurationUs += static_cast<std::uint64_t>(sample.duration);
            message.push_back(sample);
        }

        if (message.empty()) {
            std::cerr << "[ERROR] pisub: RAW_Data in '" << params.filePath << "' contained no usable samples"
                       << std::endl;
            return 1;
        }

        std::cout << "pisub: file=" << params.filePath << " freq=" << frequencyHz << " Hz"
                   << (fileData->preset.empty() ? "" : (" preset=" + fileData->preset)) << " samples="
                   << message.size() << " playback=" << (params.playback == PlaybackMode::Loop ? "loop" : "once")
                   << std::endl;
        std::cout << "pisub: only transmit captures you own or are otherwise authorized to send - "
                     "retransmitting signals for equipment you do not control may be illegal in your "
                     "jurisdiction."
                   << std::endl;

        std::signal(SIGTERM, handleSignal);
        std::signal(SIGINT, handleSignal);

        try {
            ookbursttiming sender(frequencyHz, totalDurationUs);

            int sentCount{0};
            while (running.load(std::memory_order_relaxed)) {
                sender.SendMessage(message.data(), static_cast<int>(message.size()));
                ++sentCount;

                const bool doneOnce{params.playback == PlaybackMode::Once && sentCount >= params.repeat};
                if (doneOnce || !running.load(std::memory_order_relaxed)) {
                    break;
                }
                if (params.pauseMs > 0) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(params.pauseMs));
                }
            }
        } catch (const std::exception& e) {
            std::cerr << "[ERROR] pisub: " << e.what() << std::endl;
            return 1;
        }

        std::cout << "pisub: transmission stopped." << std::endl;
        return 0;
    }
}  // namespace pisub

int main(int argc, char* argv[]) {
    return pisub::run(argc, argv);
}

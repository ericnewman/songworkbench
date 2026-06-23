#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "signalsmith-stretch.h"

struct Audio {
  uint32_t sampleRate = 0;
  uint16_t channels = 0;
  std::vector<std::vector<float>> samples;
};

static uint32_t readU32(std::istream &stream) {
  uint32_t value;
  stream.read(reinterpret_cast<char *>(&value), sizeof(value));
  return value;
}

static uint16_t readU16(std::istream &stream) {
  uint16_t value;
  stream.read(reinterpret_cast<char *>(&value), sizeof(value));
  return value;
}

static Audio readFloatWAV(const std::string &path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Could not open input WAV");

  char id[4];
  file.read(id, 4);
  if (std::memcmp(id, "RIFF", 4) != 0) throw std::runtime_error("Not RIFF");
  readU32(file);
  file.read(id, 4);
  if (std::memcmp(id, "WAVE", 4) != 0) throw std::runtime_error("Not WAVE");

  uint16_t format = 0, channels = 0, bits = 0;
  uint32_t sampleRate = 0;
  std::vector<char> data;
  while (file && (format == 0 || data.empty())) {
    file.read(id, 4);
    if (!file) break;
    uint32_t size = readU32(file);
    if (std::memcmp(id, "fmt ", 4) == 0) {
      format = readU16(file);
      channels = readU16(file);
      sampleRate = readU32(file);
      readU32(file);
      readU16(file);
      bits = readU16(file);
      file.seekg(size - 16, std::ios::cur);
    } else if (std::memcmp(id, "data", 4) == 0) {
      data.resize(size);
      file.read(data.data(), size);
    } else {
      file.seekg(size, std::ios::cur);
    }
    if (size & 1) file.seekg(1, std::ios::cur);
  }

  if (format != 3 || bits != 32 || channels == 0 || data.empty()) {
    throw std::runtime_error("Expected 32-bit IEEE Float WAV");
  }
  const size_t frames = data.size() / (channels * sizeof(float));
  Audio audio{sampleRate, channels, std::vector<std::vector<float>>(
      channels, std::vector<float>(frames))};
  const float *interleaved = reinterpret_cast<const float *>(data.data());
  for (size_t frame = 0; frame < frames; ++frame) {
    for (uint16_t channel = 0; channel < channels; ++channel) {
      audio.samples[channel][frame] = interleaved[frame * channels + channel];
    }
  }
  return audio;
}

static void writeU32(std::ostream &stream, uint32_t value) {
  stream.write(reinterpret_cast<const char *>(&value), sizeof(value));
}

static void writeU16(std::ostream &stream, uint16_t value) {
  stream.write(reinterpret_cast<const char *>(&value), sizeof(value));
}

static void writeFloatWAV(const std::string &path, const Audio &audio) {
  const uint32_t frames = static_cast<uint32_t>(audio.samples[0].size());
  const uint32_t dataSize = frames * audio.channels * sizeof(float);
  std::ofstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Could not open output WAV");

  file.write("RIFF", 4);
  writeU32(file, 36 + dataSize);
  file.write("WAVEfmt ", 8);
  writeU32(file, 16);
  writeU16(file, 3);
  writeU16(file, audio.channels);
  writeU32(file, audio.sampleRate);
  writeU32(file, audio.sampleRate * audio.channels * sizeof(float));
  writeU16(file, audio.channels * sizeof(float));
  writeU16(file, 32);
  file.write("data", 4);
  writeU32(file, dataSize);
  for (uint32_t frame = 0; frame < frames; ++frame) {
    for (uint16_t channel = 0; channel < audio.channels; ++channel) {
      const float sample = audio.samples[channel][frame];
      file.write(reinterpret_cast<const char *>(&sample), sizeof(sample));
    }
  }
}

int main(int argc, char **argv) {
  if (argc < 5) {
    std::cerr << "usage: signalsmith_benchmark input.wav output.wav semitones tempo [formants]\n";
    return 2;
  }
  try {
    Audio input = readFloatWAV(argv[1]);
    const float semitones = std::stof(argv[3]);
    const double tempo = std::stod(argv[4]);
    const bool preserveFormants = argc > 5 && std::string(argv[5]) == "formants";
    const int inputFrames = static_cast<int>(input.samples[0].size());
    const int outputFrames = std::max(static_cast<int>(inputFrames / tempo), 1);
    Audio output{input.sampleRate, input.channels,
                 std::vector<std::vector<float>>(
                     input.channels, std::vector<float>(outputFrames))};

    signalsmith::stretch::SignalsmithStretch<float> stretch;
    stretch.presetDefault(input.channels, input.sampleRate);
    stretch.setTransposeSemitones(semitones);
    if (preserveFormants) stretch.setFormantFactor(1, true);

    std::vector<float *> inputPointers, outputPointers;
    for (auto &channel : input.samples) inputPointers.push_back(channel.data());
    for (auto &channel : output.samples) outputPointers.push_back(channel.data());

    const auto start = std::chrono::steady_clock::now();
    const bool succeeded = stretch.exact(
        inputPointers.data(), inputFrames, outputPointers.data(), outputFrames);
    const auto end = std::chrono::steady_clock::now();
    if (!succeeded) throw std::runtime_error("Signalsmith exact() rejected input");
    writeFloatWAV(argv[2], output);

    const double elapsed = std::chrono::duration<double>(end - start).count();
    std::cout << "elapsed_seconds=" << elapsed << "\n"
              << "input_frames=" << inputFrames << "\n"
              << "output_frames=" << outputFrames << "\n"
              << "input_latency=" << stretch.inputLatency() << "\n"
              << "output_latency=" << stretch.outputLatency() << "\n"
              << "block_samples=" << stretch.blockSamples() << "\n"
              << "interval_samples=" << stretch.intervalSamples() << "\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}

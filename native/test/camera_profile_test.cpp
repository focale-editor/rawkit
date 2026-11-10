#include "../src/camera_profile.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>

// Independent colour invariants using the fixtures from check_dcp_web.dart.
int main(int argc, char **argv) {
  assert(argc == 2);
  using namespace rawkit_dcp;
  for (int index = 0; index < 4; ++index) {
    const std::string path = std::string(argv[1]) + "/profile" + std::to_string(index) + ".dcp";
    std::ifstream stream(path, std::ios::binary);
    const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(stream)), {});
    Profile profile(bytes.data(), bytes.size());
    uint16_t pixels[] = {26214, 26214, 26214, 20000, 10000, 5000};
    profile.apply(pixels, 2, Color{{.5, 1, .7}}, 2);
    const double expected = index == 1 ? 26214 * std::pow(2, .7) : index == 2 ? 32767.5 : 26214;
    for (int channel = 0; channel < 3; ++channel) assert(std::abs(pixels[channel] - expected) <= 2);
    if (index == 0) {
      // The declared forward matrix is ProPhoto -> XYZ D50: net identity.
      assert(std::abs(int(pixels[3])-20000) <= 1);
      assert(std::abs(int(pixels[4])-10000) <= 1);
      assert(std::abs(int(pixels[5])-5000) <= 1);
    }
  }
  Table table;
  table.hue = 1; table.saturation = 2; table.value = 1;
  table.data = {120,1,1,120,1,1};
  const Color green = apply_table(Color{{.6,0,0}},table,nullptr,1);
  assert(std::abs(green[0]) < 1e-9 && std::abs(green[1]-.6) < 1e-9 && green[2] == 0);
  table.value = 2; table.encoded = true; table.data = {0,1,1,0,1,.5,0,1,1,0,1,.5};
  const Color scaled = apply_table(Color{{.6,0,0}},table,nullptr,1);
  assert(std::abs(scaled[0]-decode_srgb(encode_srgb(.6)*.5)) < 1e-9);
  std::cout << "DCP matrix, neutral white, exposure, curve, hue and encoded-value checks passed.\n";
}

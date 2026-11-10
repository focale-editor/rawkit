/* Bounded DCP colour processing shared by native and WebAssembly decoders.
 * This product includes DNG technology under license by Adobe.
 * The implementation follows DNG 1.7.1, chapters 4 and 6; no SDK code is used.
 */
#ifndef RAWKIT_CAMERA_PROFILE_H
#define RAWKIT_CAMERA_PROFILE_H
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace rawkit_dcp {
using Color = std::array<double, 3>;
using Matrix = std::array<double, 9>;
static const Color d50 = {{0.96422, 1.0, 0.82521}};
static const Matrix xyz_to_prophoto = {{1.3459433, -0.2556075, -0.0511118, -0.5445989, 1.5081673, 0.0205351, 0.0, 0.0, 1.2118128}};
static const Matrix prophoto_to_xyz = {{0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857, 0.0, 0.0, 0.8252100}};

/// Rejects unsupported colour semantics as well as malformed binary data.
inline void require(bool valid) { if (!valid) throw std::invalid_argument("Invalid or unsupported DCP camera profile"); }
inline double clamp(double x, double lo = 0.0, double hi = 1.0) { return std::max(lo, std::min(hi, x)); }
inline Color multiply(const Matrix &m, const Color &c) {
  Color out = {{0, 0, 0}};
  for (int r = 0; r < 3; ++r) for (int k = 0; k < 3; ++k) out[r] += m[r * 3 + k] * c[k];
  return out;
}
inline Matrix multiply(const Matrix &a, const Matrix &b) {
  Matrix out = {{0, 0, 0, 0, 0, 0, 0, 0, 0}};
  for (int r = 0; r < 3; ++r) for (int c = 0; c < 3; ++c) for (int k = 0; k < 3; ++k) out[r * 3 + c] += a[r * 3 + k] * b[k * 3 + c];
  return out;
}
inline Matrix inverse(const Matrix &m) {
  const double det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
  require(std::isfinite(det) && std::abs(det) > 1e-12);
  Matrix out = {{m[4]*m[8]-m[5]*m[7], m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4], m[5]*m[6]-m[3]*m[8], m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5], m[3]*m[7]-m[4]*m[6], m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]}};
  for (double &v : out) v /= det;
  return out;
}
inline Matrix mix(const Matrix &a, const Matrix &b, double first) {
  Matrix out;
  for (int i = 0; i < 9; ++i) out[i] = a[i] * first + b[i] * (1 - first);
  return out;
}
/// Bradford chromatic adaptation, normalized to a unit-Y source white.
inline Matrix adaptation(Color white, const Color &target = d50) {
  const Matrix bradford = {{0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296}};
  require(white[1] > 1e-12);
  const double y = white[1];
  for (double &v : white) v /= y;
  const Color from = multiply(bradford, white), to = multiply(bradford, target);
  Matrix scaled = bradford;
  for (int r = 0; r < 3; ++r) {
    require(std::abs(from[r]) > 1e-12);
    for (int c = 0; c < 3; ++c) scaled[r*3+c] *= to[r] / from[r];
  }
  return multiply(inverse(bradford), scaled);
}
/// Correlated temperature approximation used only for dual-illuminant weights.
inline double temperature(const Color &xyz) {
  const double total = xyz[0] + xyz[1] + xyz[2];
  require(total > 0);
  const double x = xyz[0] / total, y = xyz[1] / total;
  const double n = (x - 0.3320) / (y - 0.1858);
  const double kelvin = -449*n*n*n + 3525*n*n - 6823.3*n + 5520.33;
  return std::isfinite(kelvin) ? clamp(kelvin, 1667, 50000) : 6500;
}
inline double illuminant(int value) {
  switch (value) {
    case 1: case 4: case 9: case 20: return 5500;
    case 2: case 14: return 4150;
    case 3: case 17: return 2856;
    case 10: case 21: return 6500;
    case 11: case 22: return 7500;
    case 12: return 6400;
    case 13: case 23: return 5000;
    case 15: return 3450;
    case 18: return 4874;
    case 19: return 6774;
    case 24: return 3200;
    default: return 0;
  }
}

/// Reads one bounded classic TIFF/DCP directory in either byte order.
class Directory {
  struct Entry { uint16_t type; uint32_t count; size_t offset; };
  const uint8_t *bytes;
  size_t size;
  bool little;
  std::map<uint16_t, Entry> entries;
  uint16_t u16(size_t at) const {
    require(at <= size && size - at >= 2);
    return little ? bytes[at] | bytes[at+1] << 8 : bytes[at] << 8 | bytes[at+1];
  }
  uint32_t u32(size_t at) const {
    require(at <= size && size - at >= 4);
    uint32_t out = 0;
    for (int i = 0; i < 4; ++i) out |= uint32_t(bytes[at+i]) << (8 * (little ? i : 3-i));
    return out;
  }
public:
  Directory(const uint8_t *data, size_t length) : bytes(data), size(length), little(false) {
    require(data && length >= 8 && length <= 8 * 1024 * 1024);
    little = data[0] == 'I' && data[1] == 'I';
    require(little || (data[0] == 'M' && data[1] == 'M'));
    require(u16(2) == 0x4352 || u16(2) == 42);
    const size_t directory = u32(4);
    const uint16_t count = u16(directory);
    require(directory >= 8 && count > 0 && count <= 256 && directory + 2 + size_t(count) * 12 + 4 <= size);
    require(u32(directory + 2 + size_t(count) * 12) == 0);
    for (size_t i = 0; i < count; ++i) {
      const size_t at = directory + 2 + i * 12;
      const uint16_t tag = u16(at), type = u16(at+2);
      const uint32_t values = u32(at+4);
      const size_t stride = type == 1 || type == 2 || type == 7 ? 1 : type == 3 ? 2 : type == 4 || type == 9 || type == 11 ? 4 : type == 5 || type == 10 || type == 12 ? 8 : 0;
      require(stride > 0 && values <= 2 * 1024 * 1024 && entries.count(tag) == 0);
      const size_t length = size_t(values) * stride;
      const size_t offset = length <= 4 ? at + 8 : u32(at+8);
      require(offset <= size && length <= size - offset);
      entries[tag] = Entry{type, values, offset};
    }
  }
  /// Accepts an explicit SDR declaration while rejecting newer HDR semantics.
  bool standard_dynamic_range() const {
    if (!has(52551)) return true;
    const Entry &entry = entries.at(52551);
    return entry.type == 7 && entry.count == 8 && u16(entry.offset) == 1 && u16(entry.offset+2) == 0;
  }
  bool has(uint16_t tag) const { return entries.count(tag) != 0; }
  std::string string(uint16_t tag) const {
    if (!has(tag)) return std::string();
    const Entry &entry = entries.at(tag);
    require((entry.type == 1 || entry.type == 2) && entry.count <= 4096);
    std::string value(reinterpret_cast<const char *>(bytes + entry.offset), entry.count);
    const size_t zero = value.find('\0');
    return zero == std::string::npos ? value : value.substr(0, zero);
  }
  std::vector<double> numbers(uint16_t tag) const {
    if (!has(tag)) return {};
    const Entry &e = entries.at(tag);
    require(e.type == 3 || e.type == 4 || e.type == 5 || e.type == 9 || e.type == 10 || e.type == 11);
    const size_t stride = e.type == 3 ? 2 : e.type == 5 || e.type == 10 ? 8 : 4;
    std::vector<double> out(e.count);
    for (size_t i = 0; i < e.count; ++i) {
      const size_t at = e.offset + i * stride;
      double value;
      if (e.type == 3) value = u16(at);
      else if (e.type == 4) value = u32(at);
      else if (e.type == 9) value = int32_t(u32(at));
      else if (e.type == 11) { const uint32_t bits = u32(at); float sample; std::memcpy(&sample, &bits, 4); value = sample; }
      else {
        const double denominator = e.type == 10 ? double(int32_t(u32(at+4))) : double(u32(at+4));
        require(denominator != 0);
        value = (e.type == 10 ? double(int32_t(u32(at))) : double(u32(at))) / denominator;
      }
      require(std::isfinite(value) && std::abs(value) <= 1e9);
      out[i] = value;
    }
    return out;
  }
  double scalar(uint16_t tag, double fallback) const {
    if (!has(tag)) return fallback;
    const std::vector<double> values = numbers(tag);
    require(values.size() == 1);
    return values[0];
  }
  Matrix matrix(uint16_t tag) const {
    const std::vector<double> values = numbers(tag);
    require(values.size() == 9);
    Matrix out;
    std::copy(values.begin(), values.end(), out.begin());
    inverse(out);
    return out;
  }
};

/// Hue-saturation-value table with the DNG value/hue/saturation storage order.
struct Table {
  int hue = 0, saturation = 0, value = 0;
  bool encoded = false;
  std::vector<double> data;
  Table() {}
  Table(const Directory &dir, uint16_t dimensions, uint16_t samples, uint16_t encoding) {
    if (!dir.has(samples)) { require(!dir.has(dimensions)); return; }
    const std::vector<double> dims = dir.numbers(dimensions);
    require(dims.size() == 3 && dims[0] >= 1 && dims[1] >= 2 && dims[2] >= 1 && dims[0] <= 360 && dims[1] <= 256 && dims[2] <= 256);
    hue = int(dims[0]); saturation = int(dims[1]); value = int(dims[2]);
    require(dims[0] == hue && dims[1] == saturation && dims[2] == value && size_t(hue) * saturation * value <= 262144);
    data = dir.numbers(samples);
    require(data.size() == size_t(hue) * saturation * value * 3);
    const double code = dir.scalar(encoding, 0);
    require(code == 0 || code == 1);
    encoded = code == 1 && value > 1;
    for (size_t i = 0; i < data.size(); i += 3) require(std::abs(data[i]) <= 360 && data[i+1] >= 0 && data[i+1] <= 100 && data[i+2] >= 0 && data[i+2] <= 100);
    for (int v = 0; v < value; ++v) for (int h = 0; h < hue; ++h) require(std::abs(data[(size_t(v)*hue+h)*saturation*3+2]-1) < 1e-6);
  }
  Color sample(double h, double s, double v) const {
    const double hp = h * hue, sp = clamp(s) * (saturation-1), vp = clamp(v) * (value-1);
    const int h0 = int(hp) % hue, h1 = (h0+1) % hue;
    const int s0 = int(sp), s1 = std::min(s0+1, saturation-1), v0 = int(vp), v1 = std::min(v0+1, value-1);
    const double hf = hp - std::floor(hp), sf = sp - s0, vf = vp - v0;
    Color out = {{0, 0, 0}};
    for (int z = 0; z < 2; ++z) for (int y = 0; y < 2; ++y) for (int x = 0; x < 2; ++x) {
      const size_t index = ((size_t(z ? v1 : v0) * hue + (y ? h1 : h0)) * saturation + (x ? s1 : s0)) * 3;
      const double weight = (z ? vf : 1-vf) * (y ? hf : 1-hf) * (x ? sf : 1-sf);
      for (int c = 0; c < 3; ++c) out[c] += data[index+c] * weight;
    }
    return out;
  }
};
inline double encode_srgb(double x) { return x <= 0.0031308 ? x*12.92 : 1.055*std::pow(x, 1.0/2.4)-0.055; }
inline double decode_srgb(double x) { return x <= 0.04045 ? x/12.92 : std::pow((x+0.055)/1.055, 2.4); }
inline Color apply_table(Color rgb, const Table &table, const Table *second, double first) {
  if (table.data.empty()) return rgb;
  for (double &component : rgb) component = std::max(0.0, component);
  double peak = std::max(rgb[0], std::max(rgb[1], rgb[2]));
  const double low = std::min(rgb[0], std::min(rgb[1], rgb[2])), chroma = peak - low;
  double h = 0, s = peak > 0 ? chroma / peak : 0;
  if (chroma > 0) {
    h = (peak == rgb[0] ? (rgb[1]-rgb[2])/chroma : peak == rgb[1] ? 2+(rgb[2]-rgb[0])/chroma : 4+(rgb[0]-rgb[1])/chroma) / 6;
    h -= std::floor(h);
  }
  if (table.encoded) peak = encode_srgb(peak);
  Color change = table.sample(h, s, peak);
  if (second && !second->data.empty()) {
    const Color other = second->sample(h, s, peak);
    for (int c = 0; c < 3; ++c) change[c] = change[c] * first + other[c] * (1-first);
  }
  h += change[0] / 360; h -= std::floor(h);
  s = clamp(s * change[1]); peak = clamp(peak * change[2]);
  if (table.encoded) peak = decode_srgb(peak);
  const double sector = h * 6, f = sector - std::floor(sector);
  const double p = peak*(1-s), q = peak*(1-s*f), t = peak*(1-s*(1-f));
  switch (int(sector) % 6) {
    case 0: return {{peak,t,p}}; case 1: return {{q,peak,p}}; case 2: return {{p,peak,t}};
    case 3: return {{p,q,peak}}; case 4: return {{t,p,peak}}; default: return {{peak,p,q}};
  }
}

/// Validated standard-dynamic-range camera profile and its rendering tables.
class Profile {
  Matrix color1, color2, forward1, forward2;
  bool dual = false, forward = false;
  double firstTemperature = 6500, secondTemperature = 6500;
  Table hue1, hue2, look;
  double exposure = 1;
  std::vector<double> curve, derivatives;
public:
  std::string name, cameraModel;
  Profile(const uint8_t *bytes, size_t size) {
    const Directory dir(bytes, size);
    // Spatial gain maps, triple/custom illuminants and HDR profiles need a
    // different renderer; never silently interpret them as ordinary DCP.
    for (uint16_t tag : {uint16_t(52525), uint16_t(52529), uint16_t(52531), uint16_t(52544), uint16_t(52530), uint16_t(52532), uint16_t(52533), uint16_t(52534), uint16_t(52535), uint16_t(52537), uint16_t(52538), uint16_t(52543)}) require(!dir.has(tag));
    require(dir.standard_dynamic_range());
    name = dir.string(50936); cameraModel = dir.string(50708);
    color1 = dir.matrix(50721); dual = dir.has(50722);
    color2 = dual ? dir.matrix(50722) : color1;
    firstTemperature = illuminant(int(dir.scalar(50778, 0)));
    secondTemperature = illuminant(int(dir.scalar(50779, 0)));
    require(!dual || (firstTemperature > 0 && secondTemperature > 0 && firstTemperature != secondTemperature));
    forward = dir.has(50964);
    require(!dir.has(50965) || (forward && dual));
    if (forward) {
      forward1 = dir.matrix(50964); forward2 = dual ? dir.matrix(50965) : forward1;
      const Color a = multiply(forward1, Color{{1,1,1}}), b = multiply(forward2, Color{{1,1,1}});
      for (int c = 0; c < 3; ++c) require(std::abs(a[c]-d50[c]) < 0.05 && std::abs(b[c]-d50[c]) < 0.05);
    }
    hue1 = Table(dir, 50937, 50938, 51107);
    if (dir.has(50939)) { require(dual && !hue1.data.empty()); hue2 = Table(dir, 50937, 50939, 51107); }
    look = Table(dir, 50981, 50982, 51108);
    const double ev = dir.scalar(51109, 0); require(ev >= -10 && ev <= 10); exposure = std::pow(2.0, ev);
    curve = dir.numbers(50940);
    require(curve.empty() || (curve.size() >= 4 && curve.size() <= 65536 && curve.size() % 2 == 0 && curve[0] == 0 && curve[1] == 0 && curve[curve.size()-2] == 1 && curve.back() == 1));
    for (size_t i = 0; i < curve.size(); i += 2) require(curve[i] >= 0 && curve[i] <= 1 && curve[i+1] >= 0 && curve[i+1] <= 1 && (i == 0 || curve[i] > curve[i-2]));
    // Natural cubic spline, factored once per imported profile.
    const size_t n = curve.size()/2;
    derivatives.assign(n, 0);
    std::vector<double> work(n, 0);
    for (size_t i = 1; i+1 < n; ++i) {
      const double left = curve[2*i]-curve[2*i-2], right = curve[2*i+2]-curve[2*i];
      const double fraction = left/(left+right), pivot = fraction*derivatives[i-1]+2;
      derivatives[i] = (fraction-1)/pivot;
      const double slope = (curve[2*i+3]-curve[2*i+1])/right - (curve[2*i+1]-curve[2*i-1])/left;
      work[i] = (6*slope/(left+right)-fraction*work[i-1])/pivot;
    }
    if (n > 1) for (size_t i = n-1; i-- > 0;) derivatives[i] = derivatives[i]*derivatives[i+1]+work[i];
  }
  double tone(double value) const {
    if (curve.empty()) return value;
    value = clamp(value);
    size_t lo = 0, hi = curve.size()/2-1;
    while (hi-lo > 1) { const size_t mid = (lo+hi)/2; if (curve[2*mid] > value) hi = mid; else lo = mid; }
    const double h = curve[2*hi]-curve[2*lo], a = (curve[2*hi]-value)/h, b = (value-curve[2*lo])/h;
    return clamp(a*curve[2*lo+1]+b*curve[2*hi+1]+((a*a*a-a)*derivatives[lo]+(b*b*b-b)*derivatives[hi])*h*h/6);
  }
  /// Builds the camera-white-balanced to D50 transform and illuminant weight.
  Matrix transform(const Color &neutral, double *weight) const {
    double first = 0.5;
    if (dual) {
      for (int iteration = 0; iteration < 30; ++iteration) {
        const Color white = multiply(inverse(mix(color1, color2, first)), neutral);
        const double temp = temperature(white);
        const double next = clamp((1/temp-1/secondTemperature)/(1/firstTemperature-1/secondTemperature));
        if (std::abs(next-first) < 1e-7) { first = next; break; }
        first = (first+next)/2;
      }
    } else first = 1;
    *weight = first;
    if (forward) return mix(forward1, forward2, first);
    const Matrix toXyz = inverse(mix(color1, color2, first));
    const Color white = multiply(toXyz, neutral);
    require(white[1] > 1e-12);
    Matrix balanced = toXyz;
    for (int r = 0; r < 3; ++r) for (int c = 0; c < 3; ++c) balanced[r*3+c] *= neutral[c]/white[1];
    return multiply(adaptation(white), balanced);
  }
  /// Converts a complete white-balanced sensor RGB buffer into linear output RGB.
  void apply(uint16_t *pixels, size_t pixelCount, const Color &neutral, int outputSpace) const {
    double weight = 1;
    const Matrix cameraToProphoto = multiply(xyz_to_prophoto, transform(neutral, &weight));
    const Color d65 = {{0.95047, 1, 1.08883}};
    const Matrix xyzToSrgb = {{3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252}};
    const Matrix xyzToAdobe = {{2.0413690,-0.5649464,-0.3446944,-0.9692660,1.8760108,0.0415560,0.0134474,-0.1183897,1.0154096}};
    const Matrix output = outputSpace == 2 ? Matrix{{1,0,0,0,1,0,0,0,1}} : multiply(multiply(outputSpace == 1 ? xyzToAdobe : xyzToSrgb, adaptation(d50, d65)), prophoto_to_xyz);
    for (size_t i = 0; i < pixelCount; ++i) {
      Color rgb = {{pixels[i*3]/65535.0, pixels[i*3+1]/65535.0, pixels[i*3+2]/65535.0}};
      rgb = multiply(cameraToProphoto, rgb);
      rgb = apply_table(rgb, hue1, hue2.data.empty() ? nullptr : &hue2, weight);
      for (double &v : rgb) v *= exposure;
      rgb = apply_table(rgb, look, nullptr, 1);
      for (double &v : rgb) v = tone(v);
      rgb = multiply(output, rgb);
      for (int c = 0; c < 3; ++c) pixels[i*3+c] = uint16_t(std::floor(clamp(rgb[c])*65535+0.5));
    }
  }
};
} // namespace rawkit_dcp
#endif

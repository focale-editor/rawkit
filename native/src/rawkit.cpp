/*
 * RawKit stable C shim around the LibRaw C API.
 *
 * RawKit itself is licensed under MIT. The bundled LibRaw sources retain
 * their original copyright and dual LGPL-2.1/CDDL-1.0 license notices.
 */
#include "rawkit.h"

#include <libraw/libraw.h>

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits>
#include <new>
#include <string>
#include <vector>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

enum rawkit_source_type { RAWKIT_SOURCE_FILE, RAWKIT_SOURCE_MEMORY };

struct rawkit_handle {
  rawkit_source_type source_type;
  std::string path;
  uint8_t *memory;
  size_t memory_size;
  libraw_data_t *metadata_context;
  int64_t timestamp;
};

/* Keeps LibRaw's processed image alive behind the public image view. */
struct rawkit_image_storage {
  rawkit_image image;
  libraw_processed_image_t *processed;
};

namespace {

/* The public view points into LibRaw's buffer, which must be 16-bit aligned. */
static_assert(offsetof(libraw_processed_image_t, data) % alignof(uint16_t) == 0,
              "LibRaw processed image data is not 16-bit aligned");

void set_error(int32_t *error, int32_t value) {
  if (error != nullptr) {
    *error = value;
  }
}

#if defined(_WIN32)
std::vector<wchar_t> utf8_to_wide(const std::string &value) {
  if (value.empty()) {
    return std::vector<wchar_t>();
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         value.c_str(), -1, nullptr, 0);
  if (length <= 0) {
    return std::vector<wchar_t>();
  }
  std::vector<wchar_t> result(static_cast<size_t>(length));
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                          result.data(), length) <= 0) {
    return std::vector<wchar_t>();
  }
  return result;
}
#endif

int open_source(libraw_data_t *context, const rawkit_handle *handle) noexcept {
  if (context == nullptr || handle == nullptr) {
    return RAWKIT_ERROR_INVALID_ARGUMENT;
  }
  try {
    if (handle->source_type == RAWKIT_SOURCE_MEMORY) {
      if (handle->memory == nullptr || handle->memory_size == 0) {
        return RAWKIT_ERROR_INVALID_ARGUMENT;
      }
      return libraw_open_buffer(context, handle->memory, handle->memory_size);
    }
#if defined(_WIN32)
    const std::vector<wchar_t> wide_path = utf8_to_wide(handle->path);
    if (wide_path.empty()) {
      return LIBRAW_IO_ERROR;
    }
    return libraw_open_wfile(context, wide_path.data());
#else
    return libraw_open_file(context, handle->path.c_str());
#endif
  } catch (const std::bad_alloc &) {
    return RAWKIT_ERROR_OUT_OF_MEMORY;
  } catch (...) {
    return RAWKIT_ERROR_UNEXPECTED_OUTPUT;
  }
}

rawkit_handle *create_handle(int32_t *error) noexcept {
  rawkit_handle *handle = nullptr;
  try {
    handle = new (std::nothrow) rawkit_handle();
  } catch (...) {
    set_error(error, RAWKIT_ERROR_OUT_OF_MEMORY);
    return nullptr;
  }
  if (handle == nullptr) {
    set_error(error, RAWKIT_ERROR_OUT_OF_MEMORY);
    return nullptr;
  }
  handle->metadata_context = libraw_init(0);
  if (handle->metadata_context == nullptr) {
    delete handle;
    set_error(error, RAWKIT_ERROR_OUT_OF_MEMORY);
    return nullptr;
  }
  return handle;
}

void destroy_handle(rawkit_handle *handle) {
  if (handle == nullptr) {
    return;
  }
  if (handle->metadata_context != nullptr) {
    libraw_close(handle->metadata_context);
    handle->metadata_context = nullptr;
  }
  std::free(handle->memory);
  handle->memory = nullptr;
  delete handle;
}

/*
 * Reports whether LibRaw stores this format's capture time without converting
 * it through mktime(). CRW, Cine and X3F record seconds that are used as-is.
 */
bool has_unconverted_timestamp(const uint8_t *header, size_t size) {
  return (size >= 14 && std::memcmp(header + 6, "HEAPCCDR", 8) == 0) ||
         (size >= 2 && std::memcmp(header, "CI", 2) == 0) ||
         (size >= 4 && std::memcmp(header, "FOVb", 4) == 0);
}

bool read_header(const rawkit_handle *handle, uint8_t *header, size_t *size) {
  if (handle->source_type == RAWKIT_SOURCE_MEMORY) {
    *size = handle->memory_size < 16 ? handle->memory_size : 16;
    std::memcpy(header, handle->memory, *size);
    return true;
  }
#if defined(_WIN32)
  const std::vector<wchar_t> wide_path = utf8_to_wide(handle->path);
  FILE *file = wide_path.empty() ? nullptr : _wfopen(wide_path.data(), L"rb");
#else
  FILE *file = std::fopen(handle->path.c_str(), "rb");
#endif
  if (file == nullptr) {
    return false;
  }
  *size = std::fread(header, 1, 16, file);
  std::fclose(file);
  return true;
}

/*
 * Returns the camera's recorded wall-clock time encoded as seconds since the
 * Unix epoch, as if that wall clock were UTC.
 *
 * RAW containers rarely store a time zone, and LibRaw converts most recorded
 * date strings with mktime(), which applies the host's local time zone. This
 * reverses that conversion so the result does not depend on the machine that
 * opened the file.
 */
int64_t wall_clock_timestamp(const rawkit_handle *handle, time_t timestamp) {
  if (timestamp <= 0) {
    return 0;
  }
  uint8_t header[16];
  size_t header_size = 0;
  if (read_header(handle, header, &header_size) &&
      has_unconverted_timestamp(header, header_size)) {
    return static_cast<int64_t>(timestamp);
  }
  std::tm local = std::tm();
#if defined(_WIN32)
  if (localtime_s(&local, &timestamp) != 0) {
    return 0;
  }
  const time_t result = _mkgmtime(&local);
#else
  if (localtime_r(&timestamp, &local) == nullptr) {
    return 0;
  }
  const time_t result = timegm(&local);
#endif
  return result <= 0 ? 0 : static_cast<int64_t>(result);
}

int32_t exif_orientation(int flip) {
  switch (flip) {
  case 0:
    return 1;
  case 3:
    return 3;
  case 5:
    return 8;
  case 6:
    return 6;
  default:
    return 0;
  }
}

double clamp_value(double value, double minimum, double maximum) {
  return value < minimum ? minimum : (value > maximum ? maximum : value);
}

void kelvin_to_rgb(double temperature, double *red, double *green,
                   double *blue) {
  const double scaled = clamp_value(temperature, 2000.0, 50000.0) / 100.0;
  if (scaled <= 66.0) {
    *red = 255.0;
    *green = 99.4708025861 * std::log(scaled) - 161.1195681661;
    *blue = scaled <= 19.0
                ? 0.0
                : 138.5177312231 * std::log(scaled - 10.0) - 305.0447927307;
  } else {
    *red = 329.698727446 * std::pow(scaled - 60.0, -0.1332047592);
    *green = 288.1221695283 * std::pow(scaled - 60.0, -0.0755148492);
    *blue = 255.0;
  }
  *red = clamp_value(*red, 1.0, 255.0);
  *green = clamp_value(*green, 1.0, 255.0);
  *blue = clamp_value(*blue, 1.0, 255.0);
}

float usable_multiplier(float preferred, float fallback) {
  if (std::isfinite(preferred) && preferred > 0.0f) {
    return preferred;
  }
  if (std::isfinite(fallback) && fallback > 0.0f) {
    return fallback;
  }
  return 1.0f;
}

void apply_custom_white_balance(libraw_data_t *context, double temperature,
                                double tint) {
  double target_red = 0.0;
  double target_green = 0.0;
  double target_blue = 0.0;
  double reference_red = 0.0;
  double reference_green = 0.0;
  double reference_blue = 0.0;
  kelvin_to_rgb(temperature, &target_red, &target_green, &target_blue);
  kelvin_to_rgb(6500.0, &reference_red, &reference_green, &reference_blue);

  const double tint_factor = std::pow(2.0, clamp_value(tint, -150.0, 150.0) /
                                               300.0);
  const float base_red = usable_multiplier(context->color.pre_mul[0],
                                             context->color.cam_mul[0]);
  const float base_green = usable_multiplier(context->color.pre_mul[1],
                                               context->color.cam_mul[1]);
  const float base_blue = usable_multiplier(context->color.pre_mul[2],
                                              context->color.cam_mul[2]);
  const float base_green_two = usable_multiplier(context->color.pre_mul[3],
                                                   base_green);

  context->params.use_camera_wb = 0;
  context->params.use_auto_wb = 0;
  context->params.user_mul[0] = static_cast<float>(
      base_red * (reference_red / target_red) * std::sqrt(tint_factor));
  context->params.user_mul[1] =
      static_cast<float>(base_green / tint_factor);
  context->params.user_mul[2] = static_cast<float>(
      base_blue * (reference_blue / target_blue) * std::sqrt(tint_factor));
  context->params.user_mul[3] =
      static_cast<float>(base_green_two / tint_factor);
}

int libraw_color_space(int32_t color_space) {
  switch (color_space) {
  case 0:
    return 1; // sRGB
  case 1:
    return 2; // Adobe RGB (1998)
  case 2:
    return 4; // ProPhoto RGB
  default:
    return 0;
  }
}

int libraw_demosaic_quality(int32_t quality) {
  switch (quality) {
  case 0:
    return 0; // Bilinear.
  case 1:
    return 3; // AHD.
  case 2:
    return 12; // Modified AHD.
  default:
    return -1;
  }
}

int libraw_highlight_recovery(int32_t recovery) {
  switch (recovery) {
  case 0:
    return 0; // Clip.
  case 1:
    return 2; // Blend.
  case 2:
    return 5; // Reconstruct five color levels.
  default:
    return -1;
  }
}

int configure_context(libraw_data_t *context,
                      const rawkit_decode_options *options) {
  const int output_color = libraw_color_space(options->color_space);
  const int demosaic = libraw_demosaic_quality(options->demosaic_quality);
  const int highlight =
      libraw_highlight_recovery(options->highlight_recovery);
  if (output_color == 0 || demosaic < 0 || highlight < 0 ||
      (options->half_size != 0 && options->half_size != 1) ||
      options->white_balance < 0 || options->white_balance > 2 ||
      !std::isfinite(options->temperature) || !std::isfinite(options->tint)) {
    return RAWKIT_ERROR_INVALID_ARGUMENT;
  }

  context->params.half_size = options->half_size;
  context->params.output_bps = 16;
  context->params.output_color = output_color;
  context->params.user_qual = demosaic;
  context->params.highlight = highlight;
  context->params.no_auto_bright = 1;
  context->params.bright = 1.0f;
  context->params.gamm[0] = 1.0;
  context->params.gamm[1] = 1.0;
  // Monochrome sensors have no channels to balance, and LibRaw reports invalid
  // camera multipliers for them that crush highlight-recovery output to black.
  const bool monochrome = context->idata.colors == 1;
  context->params.use_camera_wb =
      !monochrome && options->white_balance == 0 ? 1 : 0;
  context->params.use_auto_wb =
      !monochrome && options->white_balance == 1 ? 1 : 0;
  if (!monochrome && options->white_balance == 2) {
    apply_custom_white_balance(context, options->temperature, options->tint);
  }
  return RAWKIT_SUCCESS;
}

/*
 * Exposes a LibRaw processed image as a three-channel RawKit image.
 *
 * Three-channel output is borrowed without copying: ownership of [processed]
 * moves into the returned image. Monochrome output is expanded into a new
 * buffer and [processed] is released. On failure the caller keeps ownership.
 */
int wrap_processed_image(libraw_processed_image_t *processed,
                         rawkit_image **result) {
  if (processed == nullptr || result == nullptr ||
      processed->type != LIBRAW_IMAGE_BITMAP || processed->width == 0 ||
      processed->height == 0 || processed->bits != 16 ||
      (processed->colors != 1 && processed->colors != 3)) {
    return RAWKIT_ERROR_UNEXPECTED_OUTPUT;
  }

  const size_t width = static_cast<size_t>(processed->width);
  const size_t height = static_cast<size_t>(processed->height);
  if (height > std::numeric_limits<size_t>::max() / width) {
    return RAWKIT_ERROR_OUT_OF_MEMORY;
  }
  const size_t pixel_count = width * height;
  const size_t source_channels = static_cast<size_t>(processed->colors);
  if (pixel_count > std::numeric_limits<size_t>::max() /
                        (3u * sizeof(uint16_t))) {
    return RAWKIT_ERROR_OUT_OF_MEMORY;
  }
  const size_t source_size =
      pixel_count * source_channels * sizeof(uint16_t);
  if (static_cast<size_t>(processed->data_size) < source_size) {
    return RAWKIT_ERROR_UNEXPECTED_OUTPUT;
  }
  const size_t output_size = pixel_count * 3u * sizeof(uint16_t);
  rawkit_image_storage *storage = static_cast<rawkit_image_storage *>(
      std::calloc(1, sizeof(rawkit_image_storage)));
  if (storage == nullptr) {
    return RAWKIT_ERROR_OUT_OF_MEMORY;
  }

  if (source_channels == 3) {
    storage->image.data = processed->data;
    storage->processed = processed;
  } else {
    storage->image.data = static_cast<uint8_t *>(std::malloc(output_size));
    if (storage->image.data == nullptr) {
      std::free(storage);
      return RAWKIT_ERROR_OUT_OF_MEMORY;
    }
    const uint16_t *source =
        reinterpret_cast<const uint16_t *>(processed->data);
    uint16_t *destination = reinterpret_cast<uint16_t *>(storage->image.data);
    for (size_t index = 0; index < pixel_count; ++index) {
      destination[index * 3] = source[index];
      destination[index * 3 + 1] = source[index];
      destination[index * 3 + 2] = source[index];
    }
    libraw_dcraw_clear_mem(processed);
  }

  storage->image.width = static_cast<uint32_t>(width);
  storage->image.height = static_cast<uint32_t>(height);
  storage->image.channels = 3;
  storage->image.bits_per_sample = 16;
  storage->image.data_size = static_cast<uint64_t>(output_size);
  *result = &storage->image;
  return RAWKIT_SUCCESS;
}

rawkit_handle *open_handle(rawkit_handle *handle, int32_t *error) {
  const int result = open_source(handle->metadata_context, handle);
  if (result != LIBRAW_SUCCESS) {
    destroy_handle(handle);
    set_error(error, result);
    return nullptr;
  }
  handle->timestamp = wall_clock_timestamp(
      handle, handle->metadata_context->other.timestamp);
  set_error(error, RAWKIT_SUCCESS);
  return handle;
}

} // namespace

extern "C" {

RAWKIT_API rawkit_handle *rawkit_open_file(const char *path, int32_t *error) {
  if (path == nullptr || path[0] == '\0') {
    set_error(error, RAWKIT_ERROR_INVALID_ARGUMENT);
    return nullptr;
  }
  rawkit_handle *handle = create_handle(error);
  if (handle == nullptr) {
    return nullptr;
  }
  try {
    handle->source_type = RAWKIT_SOURCE_FILE;
    handle->path.assign(path);
  } catch (const std::bad_alloc &) {
    destroy_handle(handle);
    set_error(error, RAWKIT_ERROR_OUT_OF_MEMORY);
    return nullptr;
  } catch (...) {
    destroy_handle(handle);
    set_error(error, RAWKIT_ERROR_INVALID_ARGUMENT);
    return nullptr;
  }
  return open_handle(handle, error);
}

RAWKIT_API rawkit_handle *rawkit_open_memory(const uint8_t *data, size_t size,
                                             int32_t *error) {
  if (data == nullptr || size == 0) {
    set_error(error, RAWKIT_ERROR_INVALID_ARGUMENT);
    return nullptr;
  }
  uint8_t *copy = rawkit_memory_allocate(size);
  if (copy == nullptr) {
    set_error(error, RAWKIT_ERROR_OUT_OF_MEMORY);
    return nullptr;
  }
  std::memcpy(copy, data, size);
  return rawkit_open_owned_memory(copy, size, error);
}

RAWKIT_API rawkit_handle *rawkit_open_owned_memory(uint8_t *data, size_t size,
                                                   int32_t *error) {
  if (data == nullptr || size == 0) {
    std::free(data);
    set_error(error, RAWKIT_ERROR_INVALID_ARGUMENT);
    return nullptr;
  }
  rawkit_handle *handle = create_handle(error);
  if (handle == nullptr) {
    std::free(data);
    return nullptr;
  }
  handle->source_type = RAWKIT_SOURCE_MEMORY;
  handle->memory = data;
  handle->memory_size = size;
  return open_handle(handle, error);
}

RAWKIT_API uint8_t *rawkit_memory_allocate(size_t size) {
  return size == 0 ? nullptr : static_cast<uint8_t *>(std::malloc(size));
}

RAWKIT_API void rawkit_memory_free(uint8_t *data) { std::free(data); }

RAWKIT_API int32_t rawkit_get_metadata(rawkit_handle *handle,
                                       rawkit_metadata *metadata) {
  if (handle == nullptr || metadata == nullptr) {
    return RAWKIT_ERROR_INVALID_ARGUMENT;
  }
  if (handle->metadata_context == nullptr) {
    return RAWKIT_ERROR_CLOSED;
  }
  libraw_data_t *context = handle->metadata_context;
  std::memset(metadata, 0, sizeof(rawkit_metadata));
  metadata->camera_make = context->idata.make;
  metadata->camera_model = context->idata.model;
  metadata->normalized_camera_make = context->idata.normalized_make;
  metadata->normalized_camera_model = context->idata.normalized_model;
  metadata->lens = context->lens.Lens;
  metadata->lens_make = context->lens.LensMake;
  metadata->iso = context->other.iso_speed;
  metadata->shutter_speed = context->other.shutter;
  metadata->aperture = context->other.aperture;
  metadata->focal_length = context->other.focal_len;
  metadata->timestamp = handle->timestamp;
  metadata->orientation = exif_orientation(context->sizes.flip);
  metadata->width = context->sizes.width;
  metadata->height = context->sizes.height;
  metadata->raw_width = context->sizes.raw_width;
  metadata->raw_height = context->sizes.raw_height;
  return RAWKIT_SUCCESS;
}

RAWKIT_API int32_t rawkit_decode(rawkit_handle *handle,
                                 const rawkit_decode_options *options,
                                 rawkit_image **image) {
  if (handle == nullptr || options == nullptr || image == nullptr) {
    return RAWKIT_ERROR_INVALID_ARGUMENT;
  }
  *image = nullptr;
  libraw_data_t *context = libraw_init(0);
  if (context == nullptr) {
    return RAWKIT_ERROR_OUT_OF_MEMORY;
  }

  int result = RAWKIT_ERROR_UNEXPECTED_OUTPUT;
  try {
    result = open_source(context, handle);
    if (result == LIBRAW_SUCCESS) {
      result = configure_context(context, options);
    }
    if (result == RAWKIT_SUCCESS) {
      result = libraw_unpack(context);
    }
    if (result == LIBRAW_SUCCESS) {
      result = libraw_dcraw_process(context);
    }
    if (result == LIBRAW_SUCCESS) {
      int memory_error = LIBRAW_SUCCESS;
      libraw_processed_image_t *processed =
          libraw_dcraw_make_mem_image(context, &memory_error);
      if (processed == nullptr) {
        result = memory_error == LIBRAW_SUCCESS
                     ? RAWKIT_ERROR_UNEXPECTED_OUTPUT
                     : memory_error;
      } else {
        result = wrap_processed_image(processed, image);
        if (result != RAWKIT_SUCCESS) {
          libraw_dcraw_clear_mem(processed);
        }
      }
    }
  } catch (const std::bad_alloc &) {
    result = RAWKIT_ERROR_OUT_OF_MEMORY;
  } catch (...) {
    result = RAWKIT_ERROR_UNEXPECTED_OUTPUT;
  }
  // Releases LibRaw's working buffers before the caller copies the pixels.
  libraw_close(context);
  return result;
}

RAWKIT_API void rawkit_image_free(rawkit_image *image) {
  if (image == nullptr) {
    return;
  }
  rawkit_image_storage *storage =
      reinterpret_cast<rawkit_image_storage *>(image);
  if (storage->processed != nullptr) {
    libraw_dcraw_clear_mem(storage->processed);
  } else {
    std::free(storage->image.data);
  }
  std::free(storage);
}

RAWKIT_API void rawkit_close(rawkit_handle *handle) { destroy_handle(handle); }

RAWKIT_API const char *rawkit_error_message(int32_t error) {
  switch (error) {
  case RAWKIT_SUCCESS:
    return "Success";
  case RAWKIT_ERROR_INVALID_ARGUMENT:
    return "Invalid RawKit argument";
  case RAWKIT_ERROR_OUT_OF_MEMORY:
    return "RawKit could not allocate memory";
  case RAWKIT_ERROR_UNEXPECTED_OUTPUT:
    return "The decoder returned an unexpected pixel format";
  case RAWKIT_ERROR_CLOSED:
    return "The RAW document is closed";
  default:
    return libraw_strerror(error);
  }
}

RAWKIT_API const char *rawkit_runtime_version(void) {
  return libraw_version();
}

RAWKIT_API const char *rawkit_bundled_version(void) {
  return LIBRAW_VERSION_STR;
}

RAWKIT_API int32_t rawkit_api_version(void) { return 2; }

#if defined(__EMSCRIPTEN__)
RAWKIT_API const char *rawkit_web_metadata_string(rawkit_handle *handle,
                                                  int32_t field) {
  if (handle == nullptr || handle->metadata_context == nullptr) {
    return nullptr;
  }
  const libraw_data_t *context = handle->metadata_context;
  switch (field) {
  case 0:
    return context->idata.make;
  case 1:
    return context->idata.model;
  case 2:
    return context->idata.normalized_make;
  case 3:
    return context->idata.normalized_model;
  case 4:
    return context->lens.Lens;
  case 5:
    return context->lens.LensMake;
  default:
    return nullptr;
  }
}

RAWKIT_API double rawkit_web_metadata_number(rawkit_handle *handle,
                                              int32_t field) {
  if (handle == nullptr || handle->metadata_context == nullptr) {
    return 0.0;
  }
  const libraw_data_t *context = handle->metadata_context;
  switch (field) {
  case 0:
    return context->other.iso_speed;
  case 1:
    return context->other.shutter;
  case 2:
    return context->other.aperture;
  case 3:
    return context->other.focal_len;
  case 4:
    return static_cast<double>(handle->timestamp);
  case 5:
    return static_cast<double>(exif_orientation(context->sizes.flip));
  case 6:
    return static_cast<double>(context->sizes.width);
  case 7:
    return static_cast<double>(context->sizes.height);
  case 8:
    return static_cast<double>(context->sizes.raw_width);
  case 9:
    return static_cast<double>(context->sizes.raw_height);
  default:
    return 0.0;
  }
}

RAWKIT_API int32_t rawkit_web_decode(rawkit_handle *handle, int32_t half_size,
                                     int32_t white_balance,
                                     int32_t demosaic_quality,
                                     int32_t highlight_recovery,
                                     int32_t color_space, double temperature,
                                     double tint, rawkit_image **image) {
  const rawkit_decode_options options = {
      half_size,       white_balance,     demosaic_quality,
      highlight_recovery, color_space,    temperature,
      tint,
  };
  return rawkit_decode(handle, &options, image);
}

RAWKIT_API uint32_t rawkit_web_image_width(const rawkit_image *image) {
  return image == nullptr ? 0 : image->width;
}

RAWKIT_API uint32_t rawkit_web_image_height(const rawkit_image *image) {
  return image == nullptr ? 0 : image->height;
}

RAWKIT_API uint32_t rawkit_web_image_channels(const rawkit_image *image) {
  return image == nullptr ? 0 : image->channels;
}

RAWKIT_API uint32_t rawkit_web_image_bits_per_sample(
    const rawkit_image *image) {
  return image == nullptr ? 0 : image->bits_per_sample;
}

RAWKIT_API uint8_t *rawkit_web_image_data(const rawkit_image *image) {
  return image == nullptr ? nullptr : image->data;
}
#endif

} // extern "C"

/*
 * RawKit stable C shim.
 *
 * This header is part of RawKit and intentionally contains no LibRaw types.
 */
#ifndef RAWKIT_H
#define RAWKIT_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define RAWKIT_API __declspec(dllexport)
#else
#define RAWKIT_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rawkit_handle rawkit_handle;

typedef struct rawkit_metadata {
  const char *camera_make;
  const char *camera_model;
  const char *normalized_camera_make;
  const char *normalized_camera_model;
  const char *lens;
  const char *lens_make;
  double iso;
  double shutter_speed;
  double aperture;
  double focal_length;
  int64_t timestamp;
  int32_t orientation;
  int32_t width;
  int32_t height;
  int32_t raw_width;
  int32_t raw_height;
} rawkit_metadata;

typedef struct rawkit_decode_options {
  int32_t half_size;
  int32_t white_balance;
  int32_t demosaic_quality;
  int32_t highlight_recovery;
  int32_t color_space;
  double temperature;
  double tint;
} rawkit_decode_options;

typedef struct rawkit_image {
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  uint32_t bits_per_sample;
  uint64_t data_size;
  uint8_t *data;
} rawkit_image;

enum rawkit_error_code {
  RAWKIT_SUCCESS = 0,
  RAWKIT_ERROR_INVALID_ARGUMENT = -200001,
  RAWKIT_ERROR_OUT_OF_MEMORY = -200002,
  RAWKIT_ERROR_UNEXPECTED_OUTPUT = -200003,
  RAWKIT_ERROR_CLOSED = -200004
};

RAWKIT_API rawkit_handle *rawkit_open_file(const char *path, int32_t *error);

RAWKIT_API rawkit_handle *rawkit_open_memory(const uint8_t *data,
                                             size_t size,
                                             int32_t *error);

RAWKIT_API int32_t rawkit_get_metadata(rawkit_handle *handle,
                                       rawkit_metadata *metadata);

RAWKIT_API int32_t rawkit_decode(rawkit_handle *handle,
                                 const rawkit_decode_options *options,
                                 rawkit_image **image);

RAWKIT_API void rawkit_image_free(rawkit_image *image);

RAWKIT_API void rawkit_close(rawkit_handle *handle);

RAWKIT_API const char *rawkit_error_message(int32_t error);

RAWKIT_API const char *rawkit_runtime_version(void);

RAWKIT_API const char *rawkit_bundled_version(void);

RAWKIT_API int32_t rawkit_api_version(void);

#ifdef __cplusplus
}
#endif

#endif

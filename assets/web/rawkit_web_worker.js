import createRawKitModule from './rawkit_web.mjs';

const modulePromise = createRawKitModule({
  locateFile: (path) => new URL(path, import.meta.url).href,
});

let module;
let handle = 0;
let previewCache = null;
let fullCache = null;
let previewKey = null;
let fullKey = null;

self.onmessage = (event) => {
  void dispatch(event.data);
};

async function dispatch(command) {
  if (command?.operation === 'open') {
    await openDocument(command.bytes);
    return;
  }
  const id = command?.id;
  try {
    if (!Number.isInteger(id)) {
      return;
    }
    switch (command.operation) {
      case 'render':
        render(id, command);
        break;
      case 'clearCache':
        clearCache();
        respond(id, {});
        break;
      case 'close':
        closeDocument();
        respond(id, {});
        self.close();
        break;
      default:
        throw rawError('backend', `Unknown RAW Worker operation: ${command.operation}.`);
    }
  } catch (error) {
    fail(id, error);
  }
}

async function openDocument(buffer) {
  try {
    if (!(buffer instanceof ArrayBuffer) || buffer.byteLength === 0) {
      throw rawError('io', 'The RAW memory buffer is empty.');
    }
    module = await modulePromise;
    const input = module._malloc(buffer.byteLength);
    const errorPointer = module._malloc(4);
    if (input === 0 || errorPointer === 0) {
      if (input !== 0) module._free(input);
      if (errorPointer !== 0) module._free(errorPointer);
      throw rawError('memory', 'RawKit could not allocate WebAssembly input memory.', -200002);
    }
    try {
      module.HEAPU8.set(new Uint8Array(buffer), input);
      module.HEAP32[errorPointer >> 2] = 0;
      handle = module._rawkit_open_memory(input, buffer.byteLength, errorPointer);
      if (handle === 0) {
        throw nativeError(module.HEAP32[errorPointer >> 2], 'open RAW memory buffer');
      }
    } finally {
      module._free(errorPointer);
      module._free(input);
    }
    self.postMessage({
      type: 'ready',
      metadata: readMetadata(),
      backend: {
        engine: 'LibRaw WebAssembly',
        runtimeVersion: readString(module._rawkit_runtime_version()),
        bundledVersion: readString(module._rawkit_bundled_version()),
        apiVersion: module._rawkit_api_version(),
      },
    });
  } catch (error) {
    closeDocument();
    self.postMessage({type: 'startupError', error: serializeError(error)});
  }
}

function render(id, command) {
  requireDocument();
  const settings = command.settings;
  validateSettings(settings);
  const colorSpace = integer(command.colorSpace, 'colorSpace');
  const preview = command.preview === true;
  const key = decodeKey(settings, colorSpace);
  let linear;
  if (preview) {
    if (previewCache === null || previewKey !== key) {
      previewCache = decode(settings, colorSpace, true);
      previewKey = key;
    }
    linear = previewCache;
  } else {
    if (fullCache === null || fullKey !== key) {
      fullCache = decode(settings, colorSpace, false);
      fullKey = key;
    }
    linear = fullCache;
  }
  const image = develop(
    linear,
    settings,
    integer(command.bitDepth, 'bitDepth'),
    positiveInteger(command.maximumWidth, 'maximumWidth'),
    positiveInteger(command.maximumHeight, 'maximumHeight'),
  );
  respond(id, image, [image.pixels]);
}

function decode(settings, colorSpace, halfSize) {
  const outputPointer = module._malloc(4);
  if (outputPointer === 0) {
    throw rawError('memory', 'RawKit could not allocate WebAssembly output memory.', -200002);
  }
  let image = 0;
  try {
    module.HEAPU32[outputPointer >> 2] = 0;
    const result = module._rawkit_web_decode(
      handle,
      halfSize ? 1 : 0,
      settings.whiteBalance,
      settings.demosaicQuality,
      settings.highlightRecovery,
      colorSpace,
      settings.temperature,
      settings.tint,
      outputPointer,
    );
    if (result !== 0) {
      throw nativeError(result, 'decode RAW pixels');
    }
    image = module.HEAPU32[outputPointer >> 2];
    const width = module._rawkit_web_image_width(image);
    const height = module._rawkit_web_image_height(image);
    const channels = module._rawkit_web_image_channels(image);
    const bitsPerSample = module._rawkit_web_image_bits_per_sample(image);
    const data = module._rawkit_web_image_data(image);
    const sampleCount = width * height * channels;
    if (
      image === 0 ||
      width <= 0 ||
      height <= 0 ||
      channels !== 3 ||
      bitsPerSample !== 16 ||
      data === 0 ||
      !Number.isSafeInteger(sampleCount)
    ) {
      throw rawError('decode', 'The WebAssembly decoder returned an invalid RGB buffer.');
    }
    const pixels = new Uint16Array(module.HEAPU8.buffer, data, sampleCount).slice();
    return {width, height, colorSpace, pixels};
  } finally {
    if (image !== 0) module._rawkit_image_free(image);
    module._free(outputPointer);
  }
}

function develop(source, settings, bitDepth, maximumWidth, maximumHeight) {
  if (bitDepth !== 0 && bitDepth !== 1) {
    throw rawError('settings', 'Unsupported output bit depth.');
  }
  const dimensions = fitDimensions(source.width, source.height, maximumWidth, maximumHeight);
  const sampleCount = dimensions.width * dimensions.height * 3;
  let pixels;
  try {
    pixels = bitDepth === 0 ? new Uint8Array(sampleCount) : new Uint16Array(sampleCount);
  } catch (error) {
    throw rawError('memory', 'The browser could not allocate the developed image buffer.', -200002);
  }
  const luminance = luminanceCoefficients(source.colorSpace);
  const exposureMultiplier = 2 ** settings.exposure;
  const maximum = bitDepth === 0 ? 255 : 65535;
  let outputIndex = 0;
  for (let y = 0; y < dimensions.height; y += 1) {
    const sourceY = dimensions.height === 1 ? 0 : (y * (source.height - 1)) / (dimensions.height - 1);
    for (let x = 0; x < dimensions.width; x += 1) {
      const sourceX = dimensions.width === 1 ? 0 : (x * (source.width - 1)) / (dimensions.width - 1);
      const sampled = sampleBilinear(source, sourceX, sourceY);
      const developed = developPixel(
        sampled.red * exposureMultiplier,
        sampled.green * exposureMultiplier,
        sampled.blue * exposureMultiplier,
        luminance,
        settings,
      );
      pixels[outputIndex++] = quantize(encode(developed.red, source.colorSpace), maximum);
      pixels[outputIndex++] = quantize(encode(developed.green, source.colorSpace), maximum);
      pixels[outputIndex++] = quantize(encode(developed.blue, source.colorSpace), maximum);
    }
  }
  return {
    width: dimensions.width,
    height: dimensions.height,
    channels: 3,
    bitDepth,
    colorSpace: source.colorSpace,
    pixels: pixels.buffer,
  };
}

function fitDimensions(width, height, maximumWidth, maximumHeight) {
  const scale = Math.min(1, maximumWidth / width, maximumHeight / height);
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

function sampleBilinear(source, x, y) {
  const left = Math.floor(x);
  const top = Math.floor(y);
  const right = Math.min(left + 1, source.width - 1);
  const bottom = Math.min(top + 1, source.height - 1);
  const horizontal = x - left;
  const vertical = y - top;
  const topLeft = (top * source.width + left) * 3;
  const topRight = (top * source.width + right) * 3;
  const bottomLeft = (bottom * source.width + left) * 3;
  const bottomRight = (bottom * source.width + right) * 3;
  const channel = (offset) => {
    const upper = mix(source.pixels[topLeft + offset], source.pixels[topRight + offset], horizontal);
    const lower = mix(source.pixels[bottomLeft + offset], source.pixels[bottomRight + offset], horizontal);
    return mix(upper, lower, vertical) / 65535;
  };
  return {red: channel(0), green: channel(1), blue: channel(2)};
}

function developPixel(red, green, blue, luminance, settings) {
  let currentRed = red;
  let currentGreen = green;
  let currentBlue = blue;
  let currentLuminance = currentRed * luminance.red + currentGreen * luminance.green + currentBlue * luminance.blue;
  let targetLuminance = currentLuminance;
  targetLuminance = adjustRegion(targetLuminance, settings.shadows / 100, 1 - smoothStep(0.05, 0.72, targetLuminance), 0.42);
  targetLuminance = adjustRegion(targetLuminance, settings.highlights / 100, smoothStep(0.28, 0.95, targetLuminance), 0.38);
  targetLuminance = adjustRegion(targetLuminance, settings.whites / 100, smoothStep(0.62, 1, targetLuminance), 0.3);
  targetLuminance = adjustRegion(targetLuminance, settings.blacks / 100, 1 - smoothStep(0, 0.38, targetLuminance), 0.28);
  targetLuminance = applyContrast(targetLuminance, settings.contrast);

  if (currentLuminance > 0.000001) {
    const ratio = targetLuminance / currentLuminance;
    currentRed *= ratio;
    currentGreen *= ratio;
    currentBlue *= ratio;
  } else {
    currentRed = targetLuminance;
    currentGreen = targetLuminance;
    currentBlue = targetLuminance;
  }

  currentLuminance = currentRed * luminance.red + currentGreen * luminance.green + currentBlue * luminance.blue;
  const maximum = Math.max(currentRed, currentGreen, currentBlue);
  const minimum = Math.min(currentRed, currentGreen, currentBlue);
  const normalizedChroma = (maximum - minimum) / Math.max(maximum, 0.000001);
  const vibrance = settings.vibrance / 100;
  let saturationMultiplier = 1 + settings.saturation / 100;
  saturationMultiplier += vibrance >= 0 ? vibrance * (1 - normalizedChroma) * 0.85 : vibrance * 0.85;
  saturationMultiplier = Math.max(0, saturationMultiplier);
  return {
    red: clamp01(currentLuminance + (currentRed - currentLuminance) * saturationMultiplier),
    green: clamp01(currentLuminance + (currentGreen - currentLuminance) * saturationMultiplier),
    blue: clamp01(currentLuminance + (currentBlue - currentLuminance) * saturationMultiplier),
  };
}

function adjustRegion(luminance, amount, weight, strength) {
  const scaledAmount = amount * weight * strength;
  return scaledAmount >= 0
    ? luminance + (1 - luminance) * scaledAmount
    : luminance + luminance * scaledAmount;
}

function applyContrast(luminance, contrast) {
  const value = clamp01(luminance);
  if (contrast === 0) return value;
  const pivot = 0.18;
  const exponent = contrast >= 0 ? 1 + contrast / 50 : 1 / (1 - contrast / 50);
  return value <= pivot
    ? pivot * (value / pivot) ** exponent
    : 1 - (1 - pivot) * ((1 - value) / (1 - pivot)) ** exponent;
}

function encode(linear, colorSpace) {
  const value = clamp01(linear);
  switch (colorSpace) {
    case 0:
      return value <= 0.0031308 ? 12.92 * value : 1.055 * value ** (1 / 2.4) - 0.055;
    case 1:
      return value ** (1 / 2.19921875);
    case 2:
      return value <= 1 / 512 ? value * 16 : value ** (1 / 1.8);
    default:
      throw rawError('settings', 'Unsupported output color space.');
  }
}

function luminanceCoefficients(colorSpace) {
  switch (colorSpace) {
    case 0:
      return {red: 0.2126, green: 0.7152, blue: 0.0722};
    case 1:
      return {red: 0.2974, green: 0.6273, blue: 0.0753};
    case 2:
      return {red: 0.288, green: 0.7119, blue: 0.0001};
    default:
      throw rawError('settings', 'Unsupported output color space.');
  }
}

function validateSettings(settings) {
  const ranges = {
    temperature: [2000, 50000],
    tint: [-150, 150],
    exposure: [-10, 10],
    contrast: [-100, 100],
    highlights: [-100, 100],
    shadows: [-100, 100],
    whites: [-100, 100],
    blacks: [-100, 100],
    saturation: [-100, 100],
    vibrance: [-100, 100],
  };
  for (const [name, range] of Object.entries(ranges)) {
    const value = settings?.[name];
    if (!Number.isFinite(value) || value < range[0] || value > range[1]) {
      throw rawError('settings', `Invalid RAW development setting: ${name}.`);
    }
  }
  for (const [name, maximum] of [['whiteBalance', 2], ['demosaicQuality', 2], ['highlightRecovery', 2]]) {
    const value = settings?.[name];
    if (!Number.isInteger(value) || value < 0 || value > maximum) {
      throw rawError('settings', `Invalid RAW development setting: ${name}.`);
    }
  }
}

function readMetadata() {
  const string = (field) => readString(module._rawkit_web_metadata_string(handle, field));
  const number = (field) => module._rawkit_web_metadata_number(handle, field);
  return {
    cameraMake: string(0),
    cameraModel: string(1),
    normalizedCameraMake: string(2),
    normalizedCameraModel: string(3),
    lens: string(4),
    lensMake: string(5),
    iso: number(0),
    shutterSpeed: number(1),
    aperture: number(2),
    focalLength: number(3),
    timestamp: Math.trunc(number(4)),
    orientation: Math.trunc(number(5)),
    width: Math.trunc(number(6)),
    height: Math.trunc(number(7)),
    rawWidth: Math.trunc(number(8)),
    rawHeight: Math.trunc(number(9)),
  };
}

function readString(pointer) {
  if (pointer === 0) return null;
  const value = module.UTF8ToString(pointer).trim();
  return value.length === 0 ? null : value;
}

function decodeKey(settings, colorSpace) {
  return [
    settings.whiteBalance,
    settings.temperature,
    settings.tint,
    settings.demosaicQuality,
    settings.highlightRecovery,
    colorSpace,
  ].join(':');
}

function nativeError(code, operation) {
  const pointer = module._rawkit_error_message(code);
  const detail = pointer === 0 ? `decoder error ${code}` : module.UTF8ToString(pointer);
  let kind = 'decode';
  if (code === -2 || code === -8) kind = 'unsupportedFile';
  if ([-100007, -100012, -100013, -200002].includes(code)) kind = 'memory';
  if (code === -100009) kind = 'io';
  if ([-4, -7, -200004].includes(code)) kind = 'state';
  return rawError(kind, `Could not ${operation}: ${detail}.`, code);
}

function rawError(kind, message, code = null) {
  const error = new Error(message);
  error.rawKind = kind;
  error.rawCode = code;
  return error;
}

function serializeError(error) {
  const code = Number.isInteger(error?.rawCode) ? error.rawCode : null;
  return {
    kind: error?.rawKind ?? (error instanceof RangeError ? 'memory' : 'backend'),
    message: error?.message ?? String(error),
    hasCode: code !== null,
    code: code ?? 0,
  };
}

function respond(id, values, transfers = []) {
  self.postMessage({type: 'response', id, ok: true, ...values}, transfers);
}

function fail(id, error) {
  self.postMessage({type: 'response', id, ok: false, error: serializeError(error)});
}

function clearCache() {
  previewCache = null;
  fullCache = null;
  previewKey = null;
  fullKey = null;
}

function closeDocument() {
  clearCache();
  if (handle !== 0 && module !== undefined) {
    module._rawkit_close(handle);
    handle = 0;
  }
}

function requireDocument() {
  if (handle === 0 || module === undefined) {
    throw rawError('state', 'The RAW document is closed.', -200004);
  }
}

function integer(value, name) {
  if (!Number.isInteger(value)) {
    throw rawError('backend', `The RAW Worker received an invalid ${name}.`);
  }
  return value;
}

function positiveInteger(value, name) {
  const result = integer(value, name);
  if (result <= 0) {
    throw rawError('settings', `${name} must be positive.`);
  }
  return result;
}

function smoothStep(edge0, edge1, value) {
  const normalized = clamp01((value - edge0) / (edge1 - edge0));
  return normalized * normalized * (3 - 2 * normalized);
}

function mix(start, end, amount) {
  return start + (end - start) * amount;
}

function clamp01(value) {
  return Math.min(1, Math.max(0, value));
}

function quantize(value, maximum) {
  return Math.round(clamp01(value) * maximum);
}

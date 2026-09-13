import createRawKitModule from './rawkit_web.mjs';

const modulePromise = createRawKitModule({
  locateFile: (path) => new URL(path, import.meta.url).href,
});

// Number of intervals in each lookup table over the [0, 1] domain.
const TABLE_INTERVALS = 1 << 16;

// Values below this bound are computed exactly: power curves are too steep
// near black for linear interpolation between the first table entries.
const EXACT_BELOW = 64 / TABLE_INTERVALS;

let module;
let handle = 0;
let documentMetadata = null;
let halfCache = null;
let halfKey = null;
let fullCache = null;
let fullKey = null;
let resampledCache = null;
let resampledSource = null;
let lastToneTable = null;
const encodeTables = [null, null, null];

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
    const errorPointer = module._malloc(4) >>> 0;
    if (errorPointer === 0) {
      throw rawError('memory', 'RawKit could not allocate WebAssembly input memory.', -200002);
    }
    try {
      const input = module._rawkit_memory_allocate(buffer.byteLength) >>> 0;
      if (input === 0) {
        throw rawError('memory', 'RawKit could not allocate WebAssembly input memory.', -200002);
      }
      module.HEAPU8.set(new Uint8Array(buffer), input);
      module.HEAP32[errorPointer >>> 2] = 0;
      // The document takes ownership of input, including when opening fails.
      handle = module._rawkit_open_owned_memory(input, buffer.byteLength, errorPointer) >>> 0;
      if (handle === 0) {
        throw nativeError(module.HEAP32[errorPointer >>> 2], 'open RAW memory buffer');
      }
    } finally {
      module._free(errorPointer);
    }
    documentMetadata = readMetadata();
    self.postMessage({
      type: 'ready',
      metadata: documentMetadata,
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
  luminanceCoefficients(colorSpace);
  const bitDepth = integer(command.bitDepth, 'bitDepth');
  if (bitDepth !== 0 && bitDepth !== 1) {
    throw rawError('settings', 'Unsupported output bit depth.');
  }
  const maximumWidth = positiveInteger(command.maximumWidth, 'maximumWidth');
  const maximumHeight = positiveInteger(command.maximumHeight, 'maximumHeight');
  const halfSize = command.preview === true && halfSizeCoversPreview(documentMetadata, maximumWidth, maximumHeight);
  const key = decodeKey(settings, colorSpace);
  const decoded = halfSize ? decodedHalf(settings, colorSpace, key) : decodedFull(settings, colorSpace, key);
  const source = developable(decoded, maximumWidth, maximumHeight);
  const image = develop(source, settings, bitDepth);
  respond(id, image, [image.pixels]);
}

function decodedHalf(settings, colorSpace, key) {
  if (halfCache !== null && halfKey === key) return halfCache;
  releaseDerived(halfCache);
  // Releases the stale decode before allocating its replacement.
  halfCache = null;
  halfKey = null;
  halfCache = decode(settings, colorSpace, true);
  halfKey = key;
  return halfCache;
}

function decodedFull(settings, colorSpace, key) {
  if (fullCache !== null && fullKey === key) return fullCache;
  releaseDerived(fullCache);
  fullCache = null;
  fullKey = null;
  fullCache = decode(settings, colorSpace, false);
  fullKey = key;
  return fullCache;
}

// Returns decoded pixels sized for the bounds, reusing the last downscaled copy.
function developable(decoded, maximumWidth, maximumHeight) {
  const dimensions = fitDimensions(decoded.width, decoded.height, maximumWidth, maximumHeight);
  if (dimensions.width === decoded.width && dimensions.height === decoded.height) {
    return decoded;
  }
  if (
    resampledCache !== null &&
    resampledSource === decoded &&
    resampledCache.width === dimensions.width &&
    resampledCache.height === dimensions.height
  ) {
    return resampledCache;
  }
  resampledCache = null;
  resampledCache = resample(decoded, dimensions.width, dimensions.height);
  resampledSource = decoded;
  return resampledCache;
}

function releaseDerived(source) {
  if (source !== null && resampledSource === source) {
    resampledCache = null;
    resampledSource = null;
  }
}

function decode(settings, colorSpace, halfSize) {
  const outputPointer = module._malloc(4) >>> 0;
  if (outputPointer === 0) {
    throw rawError('memory', 'RawKit could not allocate WebAssembly output memory.', -200002);
  }
  let image = 0;
  try {
    module.HEAPU32[outputPointer >>> 2] = 0;
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
    image = module.HEAPU32[outputPointer >>> 2];
    const width = module._rawkit_web_image_width(image) >>> 0;
    const height = module._rawkit_web_image_height(image) >>> 0;
    const channels = module._rawkit_web_image_channels(image) >>> 0;
    const bitsPerSample = module._rawkit_web_image_bits_per_sample(image) >>> 0;
    const data = module._rawkit_web_image_data(image) >>> 0;
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
    let pixels;
    try {
      pixels = new Uint16Array(module.HEAPU8.buffer, data, sampleCount).slice();
    } catch (error) {
      throw rawError('memory', 'The browser could not allocate the decoded image buffer.', -200002);
    }
    return {width, height, colorSpace, pixels};
  } finally {
    if (image !== 0) module._rawkit_image_free(image);
    module._free(outputPointer);
  }
}

// Area-averages source pixels in linear light into a smaller image.
function resample(source, width, height) {
  const columns = axisCoverage(source.width, width);
  const rows = axisCoverage(source.height, height);
  const pixels = source.pixels;
  let output;
  try {
    output = new Uint16Array(width * height * 3);
  } catch (error) {
    throw rawError('memory', 'The browser could not allocate the preview buffer.', -200002);
  }
  const row = new Float64Array(width * 3);
  for (let outputY = 0; outputY < height; outputY += 1) {
    const rowStart = rows.starts[outputY];
    const rowWeightStart = rows.weightStarts[outputY];
    const rowCount = rows.weightStarts[outputY + 1] - rowWeightStart;
    row.fill(0);
    for (let rowOffset = 0; rowOffset < rowCount; rowOffset += 1) {
      const rowWeight = rows.weights[rowWeightStart + rowOffset];
      const rowBase = (rowStart + rowOffset) * source.width;
      let outputIndex = 0;
      for (let outputX = 0; outputX < width; outputX += 1) {
        const columnStart = columns.starts[outputX];
        const columnWeightStart = columns.weightStarts[outputX];
        const columnCount = columns.weightStarts[outputX + 1] - columnWeightStart;
        let red = 0;
        let green = 0;
        let blue = 0;
        for (let columnOffset = 0; columnOffset < columnCount; columnOffset += 1) {
          const weight = columns.weights[columnWeightStart + columnOffset];
          const sourceIndex = (rowBase + columnStart + columnOffset) * 3;
          red += pixels[sourceIndex] * weight;
          green += pixels[sourceIndex + 1] * weight;
          blue += pixels[sourceIndex + 2] * weight;
        }
        row[outputIndex] += red * rowWeight;
        row[outputIndex + 1] += green * rowWeight;
        row[outputIndex + 2] += blue * rowWeight;
        outputIndex += 3;
      }
    }
    const outputStart = outputY * width * 3;
    for (let index = 0; index < row.length; index += 1) {
      output[outputStart + index] = Math.floor(row[index] + 0.5);
    }
  }
  return {width, height, colorSpace: source.colorSpace, pixels: output};
}

// Computes box-filter source spans and weights for each output sample.
function axisCoverage(sourceLength, outputLength) {
  const starts = new Int32Array(outputLength);
  const weightStarts = new Int32Array(outputLength + 1);
  const weights = [];
  const scale = sourceLength / outputLength;
  for (let output = 0; output < outputLength; output += 1) {
    const spanStart = output * scale;
    const spanEnd = Math.min((output + 1) * scale, sourceLength);
    const first = Math.floor(spanStart);
    const last = Math.min(Math.ceil(spanEnd), sourceLength) - 1;
    starts[output] = first;
    weightStarts[output] = weights.length;
    const spanLength = spanEnd - spanStart;
    for (let sourceIndex = first; sourceIndex <= last; sourceIndex += 1) {
      const overlap = Math.min(spanEnd, sourceIndex + 1) - Math.max(spanStart, sourceIndex);
      weights.push(overlap / spanLength);
    }
  }
  weightStarts[outputLength] = weights.length;
  return {starts, weightStarts, weights: Float64Array.from(weights)};
}

// Applies tone, saturation and output encoding at the source resolution.
function develop(source, settings, bitDepth) {
  const sampleCount = source.width * source.height * 3;
  let pixels;
  try {
    pixels = bitDepth === 0 ? new Uint8Array(sampleCount) : new Uint16Array(sampleCount);
  } catch (error) {
    throw rawError('memory', 'The browser could not allocate the developed image buffer.', -200002);
  }
  const colorSpace = source.colorSpace;
  const weights = luminanceCoefficients(colorSpace);
  const luminanceRed = weights.red;
  const luminanceGreen = weights.green;
  const luminanceBlue = weights.blue;
  const tone = toneTable(settings, colorSpace);
  const encode = encodeTable(colorSpace);
  const gain = 2 ** settings.exposure / 65535;
  const saturation = settings.saturation / 100;
  const vibrance = settings.vibrance / 100;
  const maximum = bitDepth === 0 ? 255 : 65535;
  const input = source.pixels;

  for (let index = 0; index < sampleCount; index += 3) {
    let red = input[index] * gain;
    let green = input[index + 1] * gain;
    let blue = input[index + 2] * gain;
    const luminance = red * luminanceRed + green * luminanceGreen + blue * luminanceBlue;
    let target;
    if (luminance >= EXACT_BELOW && luminance <= 1) {
      const position = luminance * TABLE_INTERVALS;
      const entry = position | 0;
      const start = tone[entry];
      target = start + (tone[entry + 1] - start) * (position - entry);
    } else {
      target = toneCurve(luminance, settings);
    }

    if (luminance > 0.000001) {
      const ratio = target / luminance;
      red *= ratio;
      green *= ratio;
      blue *= ratio;
    } else {
      red = target;
      green = target;
      blue = target;
    }

    const adjustedLuminance = red * luminanceRed + green * luminanceGreen + blue * luminanceBlue;
    let channelMaximum = red > green ? red : green;
    if (blue > channelMaximum) channelMaximum = blue;
    let channelMinimum = red < green ? red : green;
    if (blue < channelMinimum) channelMinimum = blue;
    const normalizedChroma = (channelMaximum - channelMinimum) / (channelMaximum > 0.000001 ? channelMaximum : 0.000001);
    let saturationMultiplier = 1 + saturation + (vibrance >= 0 ? vibrance * (1 - normalizedChroma) * 0.85 : vibrance * 0.85);
    if (saturationMultiplier < 0) saturationMultiplier = 0;

    pixels[index] = encodeChannel(encode, adjustedLuminance + (red - adjustedLuminance) * saturationMultiplier, colorSpace, maximum);
    pixels[index + 1] = encodeChannel(encode, adjustedLuminance + (green - adjustedLuminance) * saturationMultiplier, colorSpace, maximum);
    pixels[index + 2] = encodeChannel(encode, adjustedLuminance + (blue - adjustedLuminance) * saturationMultiplier, colorSpace, maximum);
  }
  return {
    width: source.width,
    height: source.height,
    channels: 3,
    bitDepth,
    colorSpace,
    pixels: pixels.buffer,
  };
}

// Clamps, encodes and rounds one linear channel to [0, maximum].
function encodeChannel(table, linear, colorSpace, maximum) {
  const clamped = linear < 0 ? 0 : linear > 1 ? 1 : linear;
  if (clamped < EXACT_BELOW) {
    return Math.floor(encodeValue(clamped, colorSpace) * maximum + 0.5);
  }
  const position = clamped * TABLE_INTERVALS;
  const entry = position | 0;
  const start = table[entry];
  return Math.floor((start + (table[entry + 1] - start) * (position - entry)) * maximum + 0.5);
}

// Returns the sampled tone curve, reusing the last table for unchanged settings.
function toneTable(settings, colorSpace) {
  const cached = lastToneTable;
  if (
    cached !== null &&
    cached.colorSpace === colorSpace &&
    cached.shadows === settings.shadows &&
    cached.highlights === settings.highlights &&
    cached.whites === settings.whites &&
    cached.blacks === settings.blacks &&
    cached.contrast === settings.contrast
  ) {
    return cached.values;
  }
  const values = new Float64Array(TABLE_INTERVALS + 2);
  for (let index = 0; index <= TABLE_INTERVALS; index += 1) {
    values[index] = toneCurve(index / TABLE_INTERVALS, settings);
  }
  values[TABLE_INTERVALS + 1] = values[TABLE_INTERVALS];
  lastToneTable = {
    colorSpace,
    shadows: settings.shadows,
    highlights: settings.highlights,
    whites: settings.whites,
    blacks: settings.blacks,
    contrast: settings.contrast,
    values,
  };
  return values;
}

// Returns the sampled output transfer function of a color space.
function encodeTable(colorSpace) {
  const cached = encodeTables[colorSpace];
  if (cached !== null) return cached;
  const values = new Float64Array(TABLE_INTERVALS + 2);
  for (let index = 0; index <= TABLE_INTERVALS; index += 1) {
    values[index] = encodeValue(index / TABLE_INTERVALS, colorSpace);
  }
  values[TABLE_INTERVALS + 1] = values[TABLE_INTERVALS];
  encodeTables[colorSpace] = values;
  return values;
}

// Maps adjusted linear luminance through the regional and contrast curve.
function toneCurve(luminance, settings) {
  let target = luminance;
  target = adjustRegion(target, settings.shadows / 100, 1 - smoothStep(0.05, 0.72, target), 0.42);
  target = adjustRegion(target, settings.highlights / 100, smoothStep(0.28, 0.95, target), 0.38);
  target = adjustRegion(target, settings.whites / 100, smoothStep(0.62, 1, target), 0.3);
  target = adjustRegion(target, settings.blacks / 100, 1 - smoothStep(0, 0.38, target), 0.28);
  return applyContrast(target, settings.contrast);
}

function fitDimensions(width, height, maximumWidth, maximumHeight) {
  const scale = Math.min(1, maximumWidth / width, maximumHeight / height);
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale)),
  };
}

// Reports whether a half-size decode has enough pixels for a preview.
function halfSizeCoversPreview(metadata, maximumWidth, maximumHeight) {
  const width = metadata?.width ?? 0;
  const height = metadata?.height ?? 0;
  if (width <= 0 || height <= 0) return true;
  const swapsAxes = metadata.orientation === 6 || metadata.orientation === 8;
  const displayedWidth = swapsAxes ? height : width;
  const displayedHeight = swapsAxes ? width : height;
  const fitted = fitDimensions(displayedWidth, displayedHeight, maximumWidth, maximumHeight);
  return fitted.width <= Math.floor((displayedWidth + 1) / 2) && fitted.height <= Math.floor((displayedHeight + 1) / 2);
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

function encodeValue(linear, colorSpace) {
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
  const address = pointer >>> 0;
  if (address === 0) return null;
  const value = module.UTF8ToString(address).trim();
  return value.length === 0 ? null : value;
}

// Identifies the controls that require a new decode. Temperature and tint only
// matter for custom white balance, matching the desktop worker.
function decodeKey(settings, colorSpace) {
  const custom = settings.whiteBalance === 2;
  return [
    settings.whiteBalance,
    custom ? settings.temperature : 0,
    custom ? settings.tint : 0,
    settings.demosaicQuality,
    settings.highlightRecovery,
    colorSpace,
  ].join(':');
}

function nativeError(code, operation) {
  const pointer = module._rawkit_error_message(code) >>> 0;
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
  halfCache = null;
  halfKey = null;
  fullCache = null;
  fullKey = null;
  resampledCache = null;
  resampledSource = null;
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

function clamp01(value) {
  return Math.min(1, Math.max(0, value));
}

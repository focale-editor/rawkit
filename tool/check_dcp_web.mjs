import fs from 'node:fs';
import createRawKitModule from '../assets/web/rawkit_web.mjs';

// Runs the actual distributed WebAssembly colour path against native buffers.
const directory = process.argv[2];
const module = await createRawKitModule({wasmBinary: fs.readFileSync(new URL('../assets/web/rawkit_web.wasm', import.meta.url))});
const allocate = bytes => {const address = module._malloc(bytes.length); module.HEAPU8.set(bytes,address); return address;};
const source = fs.readFileSync(`${directory}/source.dng`);
const sourcePointer = allocate(source), error = module._malloc(4);
const handle = module._rawkit_open_memory(sourcePointer,source.length,error);
module._free(sourcePointer);
if (!handle) throw Error(`Open failed: ${module.HEAP32[error>>>2]}`);
let maximumDifference = 0;
try {
  for (let profile = 0; profile < 4; profile++) {
    const bytes = fs.readFileSync(`${directory}/profile${profile}.dcp`), pointer = allocate(bytes);
    const status = module._rawkit_set_camera_profile(handle,pointer,bytes.length);
    module._free(pointer);
    if (status) throw Error(`Profile failed: ${status}`);
    for (let space = 0; space < 3; space++) {
      const status = module._rawkit_web_decode(handle,0,0,1,1,space,6500,0,error);
      if (status) throw Error(`Decode failed: ${status}`);
      const image = module.HEAPU32[error>>>2];
      try {
        const size = module._rawkit_web_image_width(image)*module._rawkit_web_image_height(image)*3;
        const address = module._rawkit_web_image_data(image);
        const actual = new Uint16Array(module.HEAPU8.buffer,address,size);
        const expected = fs.readFileSync(`${directory}/native${profile}-${space}.bin`);
        if (expected.length !== size*2) throw Error('Dimensions differ');
        for (let i=0;i<size;i++) maximumDifference = Math.max(maximumDifference,Math.abs(actual[i]-expected.readUInt16LE(i*2)));
      } finally {module._rawkit_image_free(image);}
    }
  }
} finally {module._rawkit_close(handle);module._free(error);}
if (maximumDifference > 2) throw Error(`Native/WASM mismatch: ${maximumDifference}`);
console.log(`12 native/WASM comparisons passed; maximum difference ${maximumDifference}/65535.`);

export const NEUTRAL_SPREAD = 12;

const PAPER_MIN_CHANNEL = 240;
const MIN_FILL_DISTANCE_SQUARED = 40 * 40;
const EDGE_FIT_RMS = 12;
const OPAQUE_COVERAGE = 0.97;
const NEIGHBOURS = [
  [-1, -1],
  [0, -1],
  [1, -1],
  [-1, 0],
  [1, 0],
  [-1, 1],
  [0, 1],
  [1, 1],
] as const;

export type RasterImage = Pick<ImageData, "data" | "width" | "height">;

export const isNeutral = (data: Uint8ClampedArray, index: number) =>
  Math.max(data[index], data[index + 1], data[index + 2]) -
    Math.min(data[index], data[index + 1], data[index + 2]) <=
  NEUTRAL_SPREAD;

export const invertNeutralPixels = (image: RasterImage) => {
  const { data } = image;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0 || !isNeutral(data, i)) continue;
    data[i] = 255 - data[i];
    data[i + 1] = 255 - data[i + 1];
    data[i + 2] = 255 - data[i + 2];
  }
};

export const setNeutralInkForBackdrop = (
  ink: RasterImage,
  backdrop: RasterImage,
) => {
  const { data } = ink;
  const background = backdrop.data;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i + 3] === 0 || !isNeutral(data, i)) continue;
    const visibleBackdrop = background[i + 3] / 255;
    const luminance =
      (0.299 * background[i] +
        0.587 * background[i + 1] +
        0.114 * background[i + 2]) *
      visibleBackdrop;
    const value = luminance > 128 ? 0 : 255;
    data[i] = value;
    data[i + 1] = value;
    data[i + 2] = value;
  }
};

// Anti-aliased edges of a coloured shape drawn over an opaque white box are pale mixes
// of the shape colour and white. Re-expressing them as the pure shape colour at partial
// alpha lets the dark page show through instead of a light halo.
export const recoverEdgesFromPaper = (image: RasterImage) => {
  const { data, width, height } = image;
  const paper = new Uint8Array(width * height);
  for (let p = 0; p < paper.length; p++) {
    const i = p * 4;
    const isPaper =
      data[i + 3] === 255 &&
      isNeutral(data, i) &&
      Math.min(data[i], data[i + 1], data[i + 2]) >= PAPER_MIN_CHANNEL;
    paper[p] = isPaper ? 1 : 0;
  }

  const updates: { index: number; fill: number; alpha: number }[] = [];
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = y * width + x;
      const i = p * 4;
      if (paper[p] || data[i + 3] !== 255 || isNeutral(data, i)) continue;

      let touchesPaper = false;
      for (const [dx, dy] of NEIGHBOURS) {
        const nx = x + dx;
        const ny = y + dy;
        if (
          nx >= 0 &&
          ny >= 0 &&
          nx < width &&
          ny < height &&
          paper[ny * width + nx]
        ) {
          touchesPaper = true;
          break;
        }
      }
      if (!touchesPaper) continue;

      let bestFill = -1;
      let bestAlpha = 0;
      let bestNorm = 0;

      for (const [dx, dy] of NEIGHBOURS) {
        const nx = x + dx;
        const ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
        const q = ny * width + nx;
        if (paper[q]) continue;
        const j = q * 4;
        if (data[j + 3] !== 255) continue;

        const fr = 255 - data[j];
        const fg = 255 - data[j + 1];
        const fb = 255 - data[j + 2];
        const norm = fr * fr + fg * fg + fb * fb;
        if (norm < MIN_FILL_DISTANCE_SQUARED || norm <= bestNorm) continue;

        const pr = 255 - data[i];
        const pg = 255 - data[i + 1];
        const pb = 255 - data[i + 2];
        const alpha = Math.min(
          1,
          Math.max(0, (pr * fr + pg * fg + pb * fb) / norm),
        );
        const errR = pr - alpha * fr;
        const errG = pg - alpha * fg;
        const errB = pb - alpha * fb;
        const residual = (errR * errR + errG * errG + errB * errB) / 3;
        if (residual > EDGE_FIT_RMS * EDGE_FIT_RMS) continue;

        bestFill = j;
        bestAlpha = alpha;
        bestNorm = norm;
      }

      if (bestFill >= 0 && bestAlpha < OPAQUE_COVERAGE) {
        updates.push({ index: i, fill: bestFill, alpha: bestAlpha });
      }
    }
  }

  for (const { index, fill, alpha } of updates) {
    data[index] = data[fill];
    data[index + 1] = data[fill + 1];
    data[index + 2] = data[fill + 2];
    data[index + 3] = Math.round(alpha * 255);
  }
};

import { describe, it, expect } from "vitest";
import {
  recoverEdgesFromPaper,
  setNeutralInkForBackdrop,
  type RasterImage,
} from "./darkPdfPixels";

const row = (pixels: number[][]): RasterImage => ({
  width: pixels.length,
  height: 1,
  data: new Uint8ClampedArray(
    pixels.flatMap(([r, g, b, a = 255]) => [r, g, b, a]),
  ),
});

const pixel = (image: RasterImage, x: number) =>
  Array.from(image.data.slice(x * 4, x * 4 + 4));

const GREEN = [40, 140, 60];
const mix = (coverage: number) =>
  GREEN.map((c) => Math.round(coverage * c + (1 - coverage) * 255));

describe("recoverEdgesFromPaper", () => {
  it("turns a pale edge between paper and a coloured shape into partial alpha of the pure colour", () => {
    const image = row([[255, 255, 255], [...mix(0.5)], [...GREEN], [...GREEN]]);

    recoverEdgesFromPaper(image);

    const [r, g, b, a] = pixel(image, 1);
    expect([r, g, b]).toEqual(GREEN);
    expect(a).toBeGreaterThan(115);
    expect(a).toBeLessThan(140);
  });

  it("leaves pure shape colours untouched", () => {
    const image = row([[255, 255, 255], [...GREEN], [...GREEN]]);

    recoverEdgesFromPaper(image);

    expect(pixel(image, 1)).toEqual([...GREEN, 255]);
    expect(pixel(image, 2)).toEqual([...GREEN, 255]);
  });

  it("leaves a pastel fill that is not a mix with paper unchanged", () => {
    const pastel = [200, 220, 255];
    const image = row([[255, 255, 255], [...pastel], [...pastel]]);

    recoverEdgesFromPaper(image);

    expect(pixel(image, 1)).toEqual([...pastel, 255]);
  });

  it("does not change neutral anti-aliasing next to paper", () => {
    const image = row([
      [255, 255, 255],
      [128, 128, 128],
      [0, 0, 0],
    ]);

    recoverEdgesFromPaper(image);

    expect(pixel(image, 1)).toEqual([128, 128, 128, 255]);
  });

  it("leaves pixels that are not a blend of the neighbouring fill and paper", () => {
    const image = row([[255, 255, 255], [200, 60, 200], [...GREEN]]);

    recoverEdgesFromPaper(image);

    expect(pixel(image, 1)).toEqual([200, 60, 200, 255]);
  });
});

describe("setNeutralInkForBackdrop", () => {
  it("draws neutral ink white over a dark backdrop and black over a light one", () => {
    const ink = row([
      [90, 90, 90],
      [90, 90, 90],
    ]);
    const backdrop = row([
      [10, 10, 10],
      [250, 250, 250],
    ]);

    setNeutralInkForBackdrop(ink, backdrop);

    expect(pixel(ink, 0)).toEqual([255, 255, 255, 255]);
    expect(pixel(ink, 1)).toEqual([0, 0, 0, 255]);
  });

  it("treats a transparent backdrop as dark", () => {
    const ink = row([[90, 90, 90]]);
    const backdrop = row([[250, 250, 250, 0]]);

    setNeutralInkForBackdrop(ink, backdrop);

    expect(pixel(ink, 0)).toEqual([255, 255, 255, 255]);
  });
});

"""Real-ESRGAN 4x upscaling through onnxruntime, tiled.

The model is RGB-only and takes NCHW float32 in 0..1. Alpha is not its problem
and is carried separately by the caller.

Tiling exists for two reasons. A 1024x1024 input in one shot allocates a
4096x4096x3 float32 activation set and peaks far above it, and the run time is
superlinear in practice. Tiles overlap and are blended with a linear ramp
rather than butt-joined, because a seam between two independently hallucinated
regions is a visible straight line - the one artifact a texture cannot hide.
"""
import numpy as np

try:
    import onnxruntime as ort
except ImportError:                                    # pragma: no cover
    ort = None

SCALE = 4


class Upscaler:
    def __init__(self, model_path, tile=192, overlap=24, threads=0):
        if ort is None:
            raise RuntimeError("onnxruntime is not installed")
        opts = ort.SessionOptions()
        if threads:
            opts.intra_op_num_threads = threads
        self.sess = ort.InferenceSession(model_path, opts,
                                         providers=['CPUExecutionProvider'])
        self.iname = self.sess.get_inputs()[0].name
        self.tile = tile
        self.overlap = overlap

    def _run(self, rgb):
        """rgb (h,w,3) uint8 -> (h*4, w*4, 3) float32 in 0..1."""
        x = rgb.astype(np.float32).transpose(2, 0, 1)[None] / 255.0
        y = self.sess.run(None, {self.iname: x})[0]
        return y[0].transpose(1, 2, 0)

    @staticmethod
    def _ramp(n, left, right):
        """Blend weight along one axis: rises over `left`, falls over `right`."""
        w = np.ones(n, np.float32)
        if left > 0:
            w[:left] = np.linspace(0, 1, left, endpoint=False, dtype=np.float32)
        if right > 0:
            w[n - right:] = np.linspace(1, 0, right, endpoint=False, dtype=np.float32)
        return w

    def upscale(self, rgb, progress=None):
        h, w, _ = rgb.shape
        t, ov = self.tile, self.overlap
        if h <= t and w <= t:
            return np.clip(self._run(rgb) * 255.0, 0, 255).astype(np.uint8)

        out = np.zeros((h * SCALE, w * SCALE, 3), np.float32)
        acc = np.zeros((h * SCALE, w * SCALE, 1), np.float32)
        step = t - ov
        ys = list(range(0, max(1, h - ov), step))
        xs = list(range(0, max(1, w - ov), step))
        total = len(ys) * len(xs)
        done = 0

        for y0 in ys:
            for x0 in xs:
                y1, x1 = min(y0 + t, h), min(x0 + t, w)
                y0c, x0c = max(0, y1 - t), max(0, x1 - t)
                piece = self._run(rgb[y0c:y1, x0c:x1])

                ph, pw = piece.shape[:2]
                wy = self._ramp(ph, 0 if y0c == 0 else ov * SCALE,
                                0 if y1 == h else ov * SCALE)
                wx = self._ramp(pw, 0 if x0c == 0 else ov * SCALE,
                                0 if x1 == w else ov * SCALE)
                weight = (wy[:, None] * wx[None, :])[..., None]

                oy, ox = y0c * SCALE, x0c * SCALE
                out[oy:oy + ph, ox:ox + pw] += piece * weight
                acc[oy:oy + ph, ox:ox + pw] += weight
                done += 1
                if progress:
                    progress(done, total)

        np.maximum(acc, 1e-6, out=acc)
        return np.clip(out / acc * 255.0, 0, 255).astype(np.uint8)

#!/usr/bin/env python3
"""Converts Deezer's Spleeter 2stems model (MIT licence) to Core ML for Perch.

Perch can strip the music from a song before the speech recogniser hears it
("Time words by ear" → neural voice separation). The network is Spleeter's
U-Net, one for the vocals and one for the accompaniment; this script reads
their TensorFlow checkpoint without TensorFlow, rebuilds both networks with
coremltools' MIL builder and saves one ML program that gives each instrument's
soft mask for a stretch of stereo magnitude spectrogram.

    model input  "magnitude"      [1, 2, T, 1024]  |STFT| of the left and right
                                                   channels at 44.1 kHz,
                                                   4096-sample Hann frames,
                                                   1024-sample hop, bins 0..1023
    model output "vocals"         [1, 2, T, 1024]  each network's sigmoid mask;
                 "accompaniment"  [1, 2, T, 1024]  Perch turns them into
                                                   Spleeter's ratio mask
                                                   v² / (v² + a²)

Use Scripts/make-vocal-model.sh, which fetches the checkpoint, checks it and
runs this script. Needs numpy and coremltools; --verify also needs nothing more
(the check is a plain numpy version of the same networks).
"""

import argparse
import os
import struct
import sys

import numpy as np

# ---------------------------------------------------------------------------
# TensorFlow checkpoint (V2 "tensor bundle") reader: an SSTable index of
# BundleEntryProto records pointing into a raw data file.


def _varint(buf, pos):
    result, shift = 0, 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7


def _protobuf(buf):
    """Field number → list of values (ints for varints, bytes for the rest)."""
    fields, pos = {}, 0
    while pos < len(buf):
        key, pos = _varint(buf, pos)
        number, kind = key >> 3, key & 7
        if kind == 0:
            value, pos = _varint(buf, pos)
        elif kind == 1:
            value, pos = buf[pos:pos + 8], pos + 8
        elif kind == 2:
            length, pos = _varint(buf, pos)
            value, pos = buf[pos:pos + length], pos + length
        elif kind == 5:
            value, pos = buf[pos:pos + 4], pos + 4
        else:
            raise ValueError("unsupported protobuf wire type %d" % kind)
        fields.setdefault(number, []).append(value)
    return fields


def _block_entries(data, offset, size):
    block = data[offset:offset + size]
    if data[offset + size] != 0:
        raise ValueError("compressed SSTable blocks are not supported")
    restarts = struct.unpack_from("<I", block, len(block) - 4)[0]
    end = len(block) - 4 - 4 * restarts
    pos, key = 0, b""
    while pos < end:
        shared, pos = _varint(block, pos)
        unshared, pos = _varint(block, pos)
        length, pos = _varint(block, pos)
        key = key[:shared] + block[pos:pos + unshared]
        pos += unshared
        yield key, block[pos:pos + length]
        pos += length


def read_checkpoint(prefix):
    """All float32 tensors of a checkpoint, by name."""
    with open(prefix + ".index", "rb") as f:
        index = f.read()
    if struct.unpack_from("<Q", index, len(index) - 8)[0] != 0xDB4775248B80FB57:
        raise ValueError("not a TensorFlow checkpoint index")
    footer = index[-48:]
    _, pos = _varint(footer, 0)  # metaindex handle, unused
    _, pos = _varint(footer, pos)
    index_offset, pos = _varint(footer, pos)
    index_size, pos = _varint(footer, pos)
    shards = {}
    tensors = {}
    for _, handle in _block_entries(index, index_offset, index_size):
        offset, p = _varint(handle, 0)
        size, _ = _varint(handle, p)
        for name, value in _block_entries(index, offset, size):
            if not name:
                continue  # the bundle header
            entry = _protobuf(value)
            dtype = entry.get(1, [0])[0]
            if dtype != 1:  # DT_FLOAT
                continue
            shape = []
            for dim in _protobuf(entry[2][0]).get(2, []) if 2 in entry else []:
                shape.append(_protobuf(dim).get(1, [0])[0])
            shard = entry.get(3, [0])[0]
            if shard not in shards:
                path = "%s.data-%05d-of-%05d" % (prefix, shard, 1)
                with open(path, "rb") as f:
                    shards[shard] = f.read()
            start = entry.get(4, [0])[0]
            length = entry.get(5, [0])[0]
            array = np.frombuffer(shards[shard], dtype="<f4", count=length // 4, offset=start)
            tensors[name.decode()] = array.reshape(shape).copy()
    return tensors


# ---------------------------------------------------------------------------
# Spleeter's U-Net (spleeter/model/functions/unet.py), weights by layer.

FILTERS = [16, 32, 64, 128, 256, 512]
BN_EPSILON = 1e-3  # Keras' default, which Spleeter keeps


def _suffix(index):
    return "" if index == 0 else "_%d" % index


def unet_weights(tensors, number):
    """Weights of the network `number` (0: vocals, 1: accompaniment), in
    PyTorch/Core ML layouts: conv [out, in, kh, kw], transposed conv [in, out, kh, kw]."""
    def conv(i):
        name = "conv2d" + _suffix(i)
        kernel = tensors[name + "/kernel"]  # [kh, kw, in, out]
        return kernel.transpose(3, 2, 0, 1), tensors[name + "/bias"]

    def deconv(i):
        name = "conv2d_transpose" + _suffix(i)
        kernel = tensors[name + "/kernel"]  # [kh, kw, out, in]
        return kernel.transpose(3, 2, 0, 1), tensors[name + "/bias"]

    def norm(i):
        name = "batch_normalization" + _suffix(i)
        return (tensors[name + "/gamma"], tensors[name + "/beta"],
                tensors[name + "/moving_mean"], tensors[name + "/moving_variance"])

    return {
        "conv": [conv(7 * number + i) for i in range(6)],
        "last": conv(7 * number + 6),
        "deconv": [deconv(6 * number + i) for i in range(6)],
        "norm": [norm(12 * number + i) for i in range(12)],
    }


def check_shapes(weights):
    channels = 2
    for i, (kernel, _) in enumerate(weights["conv"]):
        assert kernel.shape == (FILTERS[i], channels, 5, 5), (i, kernel.shape)
        channels = FILTERS[i]
    outs = FILTERS[4::-1] + [1]
    ins = [512] + [2 * f for f in FILTERS[4:0:-1]] + [32]
    for i, (kernel, _) in enumerate(weights["deconv"]):
        assert kernel.shape == (ins[i], outs[i], 5, 5), (i, kernel.shape)
    assert weights["last"][0].shape == (2, 1, 4, 4), weights["last"][0].shape


# ---------------------------------------------------------------------------
# The same network in MIL, for Core ML.


def build_mlmodel(nets, frames):
    import coremltools as ct
    from coremltools.converters.mil import Builder as mb

    def batch_norm(x, params):
        gamma, beta, mean, variance = params
        return mb.batch_norm(x=x, mean=mean, variance=variance, gamma=gamma, beta=beta, epsilon=BN_EPSILON)

    def conv(x, params, **options):
        kernel, bias = params
        return mb.conv(x=x, weight=kernel, bias=bias, **options)

    def deconv(x, params, size):
        # TensorFlow's "same" transposed convolution: the full output cropped by 1 before, 2 after.
        kernel, bias = params
        full = mb.conv_transpose(x=x, weight=kernel, bias=bias, strides=[2, 2], pad_type="valid")
        return mb.slice_by_index(x=full, begin=[0, 0, 1, 1], end=[0, 0, 1 + size[0], 1 + size[1]],
                                 end_mask=[True, True, False, False])

    def unet(x, w):
        # Encoder: TensorFlow's "same" padding for a stride-2 5×5 kernel pads 1 before, 2 after.
        skips, h = [], x
        for i in range(6):
            c = conv(h, w["conv"][i], strides=[2, 2], pad_type="custom", pad=[1, 2, 1, 2])
            skips.append(c)  # Spleeter joins the decoder with the convolutions before normalising
            h = mb.leaky_relu(x=batch_norm(c, w["norm"][i]), alpha=0.2)
        h = skips[5]  # the decoder starts from the last convolution itself
        size = (frames // 64, 1024 // 64)
        for i in range(6):
            size = (size[0] * 2, size[1] * 2)
            h = batch_norm(mb.relu(x=deconv(h, w["deconv"][i], size)), w["norm"][6 + i])
            if i < 5:
                h = mb.concat(values=[skips[4 - i], h], axis=1)
        return mb.sigmoid(x=conv(h, w["last"], dilations=[2, 2], pad_type="custom", pad=[3, 3, 3, 3]))

    shape = (1, 2, frames, 1024)

    @mb.program(input_specs=[mb.TensorSpec(shape=shape)], opset_version=ct.target.macOS14)
    def program(magnitude):
        vocals = unet(magnitude, nets[0])
        accompaniment = unet(magnitude, nets[1])
        return mb.identity(x=vocals, name="vocals"), mb.identity(x=accompaniment, name="accompaniment")

    model = ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS14,
                       compute_precision=ct.precision.FLOAT16,
                       inputs=[ct.TensorType(name="magnitude", shape=shape)])
    model.short_description = ("Spleeter 2stems (Deezer, MIT licence) converted for Perch: soft masks of "
                               "the vocals and the accompaniment from a stereo magnitude spectrogram.")
    model.author = "Deezer Research (Spleeter); conversion: Perch"
    model.license = "MIT"
    model.version = "1"
    return model


# ---------------------------------------------------------------------------
# A plain numpy version of the networks, to check the conversion.


def _np_conv(x, kernel, bias, stride, pad, dilation=1):
    # x [c, h, w]; kernel [o, c, kh, kw]
    x = np.pad(x, ((0, 0), (pad[0], pad[1]), (pad[2], pad[3])))
    o, c, kh, kw = kernel.shape
    h = (x.shape[1] - dilation * (kh - 1) - 1) // stride + 1
    w = (x.shape[2] - dilation * (kw - 1) - 1) // stride + 1
    out = np.zeros((o, h, w), dtype=np.float32)
    for i in range(kh):
        for j in range(kw):
            patch = x[:, i * dilation:i * dilation + stride * (h - 1) + 1:stride,
                      j * dilation:j * dilation + stride * (w - 1) + 1:stride]
            out += np.einsum("chw,oc->ohw", patch, kernel[:, :, i, j], optimize=True)
    return out + bias[:, None, None]


def _np_deconv(x, kernel, bias):
    # x [c, h, w]; kernel [c, o, 5, 5]; TensorFlow "same", stride 2
    c, h, w = x.shape
    o = kernel.shape[1]
    full = np.zeros((o, 2 * h + 3, 2 * w + 3), dtype=np.float32)
    for i in range(5):
        for j in range(5):
            full[:, i:i + 2 * h:2, j:j + 2 * w:2] += np.einsum("chw,co->ohw", x, kernel[:, :, i, j], optimize=True)
    return full[:, 1:1 + 2 * h, 1:1 + 2 * w] + bias[:, None, None]


def _np_norm(x, params):
    gamma, beta, mean, variance = params
    scale = gamma / np.sqrt(variance + BN_EPSILON)
    return (x - mean[:, None, None]) * scale[:, None, None] + beta[:, None, None]


def numpy_unet(x, w):
    skips, h = [], x
    for i in range(6):
        c = _np_conv(h, *w["conv"][i], stride=2, pad=(1, 2, 1, 2))
        skips.append(c)
        n = _np_norm(c, w["norm"][i])
        h = np.where(n > 0, n, 0.2 * n)
    h = skips[5]
    for i in range(6):
        h = _np_norm(np.maximum(_np_deconv(h, *w["deconv"][i]), 0), w["norm"][6 + i])
        if i < 5:
            h = np.concatenate([skips[4 - i], h], axis=0)
    logits = _np_conv(h, *w["last"], stride=1, pad=(3, 3, 3, 3), dilation=2)
    return 1 / (1 + np.exp(-np.clip(logits, -60, 60)))


def test_input(frames, seed=0):
    """Something like a song's spectrogram: a few harmonic tones over noise."""
    rng = np.random.default_rng(seed)
    t = np.arange(frames)[:, None]
    f = np.arange(1024)[None, :]
    spectrum = rng.exponential(0.5, size=(2, frames, 1024)) / (1 + f / 50)
    for k in range(1, 12):
        pitch = 20 + 3 * np.sin(t / 15)
        spectrum += 40 / k * np.exp(-((f - k * pitch) ** 2) / 2)
    return spectrum.astype(np.float32)


# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checkpoint", help="folder of the unpacked 2stems.tar.gz (with model.index)")
    parser.add_argument("output", help="where to write the .mlpackage")
    parser.add_argument("--frames", type=int, default=512, help="STFT frames per run, a multiple of 64")
    parser.add_argument("--verify", action="store_true", help="compare Core ML with a numpy version of the networks")
    args = parser.parse_args()
    assert args.frames % 64 == 0

    tensors = read_checkpoint(os.path.join(args.checkpoint, "model"))
    nets = [unet_weights(tensors, n) for n in range(2)]
    for net in nets:
        check_shapes(net)
    used = sum(k.size + b.size for net in nets for k, b in net["conv"] + net["deconv"] + [net["last"]])
    used += sum(p.size for net in nets for params in net["norm"] for p in params)
    print("Checkpoint: %d tensors; the two networks use %.1f M weights" % (len(tensors), used / 1e6))

    model = build_mlmodel(nets, args.frames)
    model.save(args.output)
    print("Saved", args.output)

    if args.verify:
        import time
        x = test_input(args.frames)
        start = time.time()
        expected = [numpy_unet(x, net) for net in nets]
        print("numpy reference: %.1f s" % (time.time() - start))
        import coremltools as ct
        compiled = ct.models.MLModel(args.output, compute_units=ct.ComputeUnit.ALL)
        compiled.predict({"magnitude": x[None]})
        start = time.time()
        result = compiled.predict({"magnitude": x[None]})
        print("Core ML: %.3f s for %.1f s of sound" % (time.time() - start, args.frames * 1024 / 44100))
        worst = 0
        for name, reference in zip(["vocals", "accompaniment"], expected):
            difference = np.abs(result[name][0] - reference)
            worst = max(worst, difference.max())
            print("%s: mean mask %.3f, max difference %.4f, mean %.5f"
                  % (name, reference.mean(), difference.max(), difference.mean()))
        if worst > 0.05:
            sys.exit("✗ Core ML and numpy disagree")
        print("✓ Core ML matches the numpy networks")


if __name__ == "__main__":
    main()

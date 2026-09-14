# MobileFaceNet Model — Source & Credits

This document records the provenance, license, and technical specification of the
face-embedding model bundled with this app (`assets/models/mobilefacenet.tflite`).

## Model

| Property          | Value                                                        |
| ----------------- | ------------------------------------------------------------ |
| Architecture      | MobileFaceNet (Sheng Chen et al., "MobileFaceNets: Efficient CNNs for Accurate Real-time Face Verification on Mobile Devices") |
| File              | `assets/models/mobilefacenet.tflite`                         |
| Size              | 5,233,552 bytes                                              |
| Input tensor      | `"input"`, shape `[1, 112, 112, 3]`, `float32`, no quantization |
| Output tensor     | `"embeddings"`, shape `[1, 192]`, `float32` (192-d embedding) |
| Preprocessing     | RGB pixel values normalized with `(value - 128) / 128` → range `[-1, 1]` |
| Input alignment   | Face cropped, rotated to the eye axis, padded, resized to 112×112 |

## Provenance

- The original TensorFlow implementation of MobileFaceNet weights is published
  by the open-source project `sirius-ai/MobileFaceNet_TF`, licensed under the
  [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
- The concrete `.tflite` file in this repo is the community-converted export
  that is publicly redistributed by the reference project
  [`MCarlomagno/FaceRecognitionAuth`](https://github.com/MCarlomagno/FaceRecognitionAuth)
  (BSD-3-Clause licensed reference app), which embeds and uses the identical file for
  the same purpose (face verification). The reference app does not restate an
  explicit license for the binary itself, so attribution is traced back to the
  above TF implementation.
- This app performs no training: model weights are used as-is for feature
  extraction only. No face images or embeddings are uploaded or leave the device.

## License notice

Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0)

```
Copyright 2019 The Apache Software Foundation and the MobileFaceNet contributors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## References

- MobileFaceNets paper: https://arxiv.org/abs/1804.07573
- `sirius-ai/MobileFaceNet_TF`: https://github.com/sirius-ai/MobileFaceNet_TF
- `MCarlomagno/FaceRecognitionAuth`: https://github.com/MCarlomagno/FaceRecognitionAuth
# LocalVQE (vendored)

Neural acoustic echo cancellation for the mic stream — see SPEC §7 and
`SadiKit/Sources/SadiKit/EchoCanceller.swift`.

- `liblocalvqe.dylib` — built from [localai-org/LocalVQE](https://github.com/localai-org/LocalVQE)
  (Apache-2.0; GGML MIT) by `../../scripts/build-localvqe.sh`. Self-contained:
  links only system frameworks. CPU backend (statically registered).
- `localvqe-v1.4-aec-200K-f32.gguf` — the v1.4-AEC *echo-only* model
  (203 K params): removes far-end echo, passes near-end voice, noise, and
  room through unchanged (keeps WeSpeaker voiceprints trustworthy). From
  <https://huggingface.co/LocalAI-io/LocalVQE>. SHA-256:
  `b6e43138588a83bfe903ab5e143b4020b91c1e1629f5a575ac5855ff0003c731`

Why v1.4-AEC and not the joint v1.2/v1.3 models: the joint line also does
noise suppression + dereverb, which colors the signal our speaker embeddings
and archives rely on. Spike comparison in `scratch/localvqe-spike/`.

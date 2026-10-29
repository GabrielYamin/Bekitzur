# NVIDIA Nemotron 3.5 Transcribe: could it replace Bekitzur's speech recognition?

Checked on October 29, 2026, one day after release. Community ports appeared within hours of the release and are still changing, so recheck section 5 before acting on it.

## Verdict for Bekitzur

Not as a replacement today, for either language.

- **Hebrew: keep ivrit.ai.** NVIDIA puts Hebrew in its lowest support tier, "supported, may need fine-tuning" ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). Its published Hebrew error rate on FLEURS, 20.4–21.0% WER ([report, Table 23](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)), is no better than the 18.1% ivrit.ai reports for its turbo fine-tune on the same test set ([ivrit.ai leaderboard](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)). The two were scored differently, so this is only indicative. NVIDIA also calls code-switching across many language pairs a weakness of the model ([report, section 4.6](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).
- **English: better accuracy, but hard to run on our Macs.** It is the most accurate open-weights model on the public English Open ASR Leaderboard sets, at 4.71% WER vs 6.66% for Whisper large-v3. In NVIDIA's tests its word timestamps also beat Whisper large-v3 with DTW by a wide margin ([report, Tables 6 and 15](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). But it has 34 billion parameters: on a Mac it needs about 22 GB of 4-bit files ([community GGUF sizes](https://huggingface.co/AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF)) and NVIDIA's NeMo-Speech.cpp runtime. That runtime's Metal support for this model exists only on the unreleased `main` branch ([NeMo-Speech.cpp docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/models.md), [releases](https://github.com/NVIDIA/NeMo-Speech.cpp/releases)), and no Mac measurements have been published. The model also has no streaming mode ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)).
- **The only Core ML port is much weaker.** FluidAudio's "Transcribe Lite" leaves out the 30B language model and is far less accurate: 5.50% vs 1.09% WER on LibriSpeech test-clean ([FluidAudio PR #1069](https://github.com/FluidInference/FluidAudio/pull/1069)).

It is worth one bench test on a 32 GB Mac: our scripted Hebrew read plus a few English meetings (see section 6). If the English results and memory use hold up, it could become an optional after-the-call English pass. It is not a candidate for live transcription.

## 1. What it is

- **Name and release date.** The model is `NVIDIA-Nemotron-3.5-Transcribe-30B-A4B`, released on October 28, 2026 on Hugging Face, GitHub (NeMo Speech), NGC and build.nvidia.com ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). NVIDIA's [research page](https://research.nvidia.com/labs/nemotron/NVIDIA-Nemotron-3.5-Transcribe/) and [Hugging Face blog post](https://huggingface.co/blog/nvidia/nemotron-transcribe-granary) give the same date.
- **Variants.** Four are public on Hugging Face: BF16 (the reference weights), FP8, NVFP4 (for Blackwell GPUs), and a DFlash2 draft model used for speculative decoding ([Hugging Face listing](https://huggingface.co/api/models?author=nvidia&search=Nemotron-3.5-Transcribe)). NVIDIA's research page also lists a `-GGUF` repository with "GGUF files for NeMo-Speech.cpp", but [that URL](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF) returns 401, meaning it is not public yet. The blog says local deployment with NeMo-Speech.cpp is "coming soon" ([blog](https://huggingface.co/blog/nvidia/nemotron-transcribe-granary)).
- **Architecture.** It is a speech-augmented language model (SALM): an LLM writes the transcript. It is not a FastConformer TDT, RNNT or CTC model. Its parts, from the [technical report, section 2 and Table 1](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf):
  - A Transformer speech encoder: 32 layers, about 0.6B parameters, 80 ms per output frame, initialized from an encoder pretrained as a TDT transducer.
  - A frozen Nemotron 3 Diarization model (Sortformer, about 0.1B, up to 8 speakers). Its speaker activity is added to the encoder output.
  - The Nemotron 3.5 Lightning 30B-A3B language model, a hybrid Mamba-2/Transformer mixture of experts. It has 52 layers (23 Mamba-2, 23 MoE, 6 attention) and 128 experts with top-6 routing.
  - A multi-token-prediction module (about 1.3B) for speculative decoding, and a CTC head (about 50M) that aligns the generated text to the audio to produce word timestamps.
- **Size.** About 34B parameters in total and about 4.3B active per token: 3.5B in the language model plus about 0.8B on the audio side ([report, section 2.3](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). The checkpoints are 67.5 GB in BF16, about 35 GB in FP8 and about 21 GB in NVFP4 ([report, section 2.7](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).
- **License: OpenMDW-1.1, and commercial use is allowed.** The card says the model "is ready for commercial or non-commercial use" ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). The [license file](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B/blob/main/LICENSE) matches the [OpenMDW-1.1 text](https://openmdw.ai/license/1-1/). It grants permission "to deal in the Model Materials without restriction" and puts no restrictions on outputs. There are two conditions: keep the license and notices when you redistribute the model, and your rights end if you sue claiming the model infringes a patent or copyright. A few code snippets on the card are Apache-2.0 instead ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)).
- **Watch out for the "EA" checkpoint.** An early-access build distributed through NGC, `Nemotron-3.5-Transcribe-30B-A4B-EA-0.1.0`, is under NVIDIA's Software and Model Evaluation License, not OpenMDW ([mlx-audio README](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/nemotron_transcribe/README.md)). Some MLX conversions are built from it (section 5).
- **Not the same as "Nemotron 3.5 ASR".** NVIDIA also publishes `nemotron-3.5-asr-streaming-0.6b`, a 0.6B streaming FastConformer-RNNT model (card date 06/04/2026). It treats Hebrew only as "adaptation-ready": the tokenizer knows the language, but the model needs fine-tuning before it can transcribe it ([model card](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)). ivrit.ai measures it at 46.0% WER on FLEURS Hebrew ([ivrit.ai leaderboard](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)). This smaller model, not Transcribe, is the one supported by NeMo-Speech.cpp's default setup, mlx-community and sherpa-onnx.

## 2. Languages

The model card's language matrix lists 40 languages for transcription, in three quality tiers ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)):

| Tier (NVIDIA's wording) | Languages |
|---|---|
| Leading: "state of the art or near state of the art out of the box" | Czech, Dutch, English (US, India, UK), French (France, Canada), German, Hindi, Italian, Korean, Polish, Portuguese (Portugal, Brazil), Russian, Slovak, Spanish (US, Spain) |
| Production-ready | Bulgarian, Croatian, Danish, Estonian, Finnish, Hungarian, Japanese, Latvian, Lithuanian, Romanian, Slovenian, Swedish, Thai, Turkish, Ukrainian |
| Supported: "supported, may need fine-tuning" | Arabic, Bengali, Chinese Mandarin, Greek, **Hebrew**, Indonesian, Maltese, Marathi, Tagalog, Tamil, Telugu, Vietnamese |

The matrix also has a Norwegian row with no transcription support. The report says Norwegian's training data "did not yield usable quality" ([report, section 3.1](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).

- **Hebrew is supported, in the lowest tier.** The Hebrew row marks transcription, translation to and from English, and code-switching as supported. Speaker-attributed transcription is "not specified", and the quality tier is "Supported" ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). Hebrew made up about 5,400 hours of distinct training audio, 0.55% of all audio seen in training; English made up 36% ([report, Table 2](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).
- **English is supported in the top tier,** including Indian and British English.
- **Code-switching is listed for all 40 languages, but NVIDIA calls it a weakness.** Training included code-switched transcription targets ([report, section 3.1](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). The card gives a prompt for choosing the script of each language: "Transcribe verbatim in the original languages … Write [language] in [script] and English in Latin script" ([model card, Prompt Recommendations](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). But NVIDIA writes that "code-switching across many language pairs remains a weakness of the model" ([report, section 4.6](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). No Hebrew–English code-switching result has been published.
- **Automatic language identification is available as a prompted task.** The default transcription prompt says "Language: as spoken", so no language has to be chosen up front, and a separate prompt returns a language label. Reported FLEURS language-ID accuracy is 99.37% for Hebrew and 99.69% for English ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). NVIDIA's Mac-capable runtime, however, states that "the model does not detect the language": you either pass a language code, which adds "The speech is in …" to the instruction, or write the language into a custom instruction ([NeMo-Speech.cpp docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/transcripts.md)).

## 3. Accuracy

All numbers below are NVIDIA's unless marked otherwise. Lower is better, except for the timestamp F1 score.

| Benchmark | Nemotron 3.5 Transcribe | Whisper large-v3, as reported by NVIDIA | Source |
|---|---|---|---|
| English Open ASR Leaderboard, mean WER over the 9 public sets | 4.71% | 6.66% | [report, Table 6](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |
| Long-form track (Earnings-21, Earnings-22, CORAAL), mean WER | 10.98% | 13.92% | [report, Table 7](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |
| Multilingual Open ASR Leaderboard (de, fr, it, es, pt, nl, hi), mean WER | 4.62% | 7.94% | [report, Table 9](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |
| CS-FLEURS code-switching, human-read (14 pairs), CER | 25.83% | 19.83% | [report, Table 10](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |
| CS-FLEURS code-switching, MMS-TTS speech (45 pairs), CER | 44.90% | 40.07% | [report, Table 10](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |
| Word timestamps on AMI headset mix, F1 within 200 ms (higher is better) | 80.03% | 54.02% (with faster-whisper's DTW timestamps) | [report, Table 15](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |
| FLEURS Hebrew, WER | 20.97% (card), 20.36% (report) | not reported | [model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B), [report, Table 23](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf) |

- **Two different English leaderboard figures.** NVIDIA's blog cites 5.33% "average WER" on the English leaderboard ([blog](https://huggingface.co/blog/nvidia/nemotron-transcribe-granary)). That is the leaderboard's default average, which also counts two private test sets, "Private (scripted)" and "Private (conversational)" ([leaderboard config](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard/blob/main/init.py)). NVIDIA's report notes it has no access to those private sets ([report, section 4.2, footnote 2](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). The 4.71% figure covers only the nine public sets. The leaderboard's results file requires a login, so I couldn't recheck 5.33% myself.
- **Code-switching is mixed.** On the other two CS-FLEURS sets, which use XTTS synthetic speech, it is slightly ahead of Whisper large-v3: 18.00% vs 18.46% CER and 33.87% vs 36.06% ([report, Table 10](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).
- **There is no published comparison with Whisper large-v3-turbo or with any ivrit.ai model.** The timestamp-accuracy table covers 15 languages, and Hebrew is not one of them.
- **Hebrew context from ivrit.ai's own leaderboard.** These are FLEURS Hebrew WERs scored with ivrit.ai's text normalization, so they are not directly comparable with NVIDIA's figures ([ivrit.ai leaderboard data](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)):
  - ivrit.ai whisper-large-v3-turbo (20250513): 18.1%
  - stock Whisper large-v3-turbo: 28.9%
  - stock Whisper large-v3: 26.2%
  - the 0.6B sibling, Nemotron 3.5 ASR: 46.0%
  - Nemotron 3.5 Transcribe is not on the leaderboard yet.

  Taken together, Transcribe's Hebrew read-speech accuracy likely falls somewhere between stock Whisper and ivrit.ai's fine-tune. Only our own test can settle it.
- **Quantization costs more outside English.** Relative to BF16, NVIDIA's FP8 checkpoint has an average error rate 1.0% higher (relative, not percentage points) and NVFP4 3.6% higher, with larger losses in languages other than English ([report, section 4.12](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). NVIDIA did not evaluate the 4-bit formats a Mac would use (IQ4_NL GGUF, MLX 4-bit). A community GGUF publisher found its IQ4_NL files within noise of BF16 for English, German, French, Spanish and Chinese, measured on CUDA only and not on Hebrew ([AtomicChat GGUF card](https://huggingface.co/AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF)).

## 4. Features

- **Word-level timestamps: yes.** A CTC head force-aligns the generated transcript to the audio at 40 ms resolution and returns each word's start and end time, plus speaker tags when requested ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B), [report, section 2.5](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). In NeMo-Speech.cpp, timestamps "cover every language", and if alignment fails the transcript comes back without times rather than with made-up ones ([NeMo-Speech.cpp docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/timestamps-and-speakers.md)). Timestamps are not available in vLLM when the DFlash2 draft model is used ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)), and the MLX ports don't produce them (section 5).
- **Punctuation and capitalization: yes.** The prompt chooses the style, for example verbatim with fillers or clean written text ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)).
- **Custom vocabulary: yes, through the prompt** ("Context terms: …"). Given a list of expected entities, English named-entity WER on ContextASR-Bench drops from 12.21% to 2.20% ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)). This could help with tech terms, but it is untested in Hebrew.
- **Streaming or low latency: no.** The card says: "This is an offline model. Internal audio chunking does not make it a real-time streaming ASR service" ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)), and the report calls streaming "future work" ([report, Limitations](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). NeMo-Speech.cpp refuses live and streaming audio input for this model and accepts only complete recordings, though it can stream the text out as it is generated ([NeMo-Speech.cpp docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/README.md)).
- **Long-form audio: up to one hour per request,** with a 65,536-token context. For longer recordings NVIDIA used 55-minute chunks with 5 seconds of overlap. A dense one-hour conversation can need about 20,000 output tokens ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)).
- **Speaker diarization: built in, up to 8 speakers, but not for Hebrew.** Speaker-attributed transcription is listed for 13 languages, and Hebrew is not one of them ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B), [blog](https://huggingface.co/blog/nvidia/nemotron-transcribe-granary)). On English meetings and calls it scored best among the systems NVIDIA compared: 15.80% vs 16.83% mean cpWER ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)).
- **Known failure modes.**
  - Generation loops. NVIDIA recommends a regex guardrail; on the long-form track, loops hit 7 of 451 recordings, and without the guardrail the mean WER would have been 12.87% instead of 10.98% ([report, section 4.3](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).
  - Invented text in stretches of noise or music ([NeMo-Speech.cpp docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/transcripts.md)).
  - Occasional empty outputs or refusals for valid transcription requests ([report, Limitations](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).

## 5. Runtimes

**NVIDIA's documented setups are NVIDIA-GPU only.** Inference runs on vLLM 0.32.0 with NeMo Speech's `main` branch as a plugin, on SGLang-Omni 0.2.0, on Hugging Face Transformers installed from source, or on GGML. The reference setup is one H100 80 GB. Supported hardware is NVIDIA Ampere, Hopper, Lovelace and Blackwell; supported operating systems are Linux, Windows through WSL2, and native Windows for GGML. macOS and Apple Silicon don't appear in the hardware table ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B), [report, Table 17](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)). Training and fine-tuning use NeMo Speech with PyTorch ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)); NVIDIA's adaptation examples each ran on a single GB300 GPU ([report](https://research.nvidia.com/labs/nemotron/files/NVIDIA-Nemotron-3.5-Transcribe-Technical-Report.pdf)).

**Paths to Apple Silicon.** None is listed for Macs on NVIDIA's model card.

| Path | Status on Oct 29, 2026 | Key facts for a Mac |
|---|---|---|
| NeMo-Speech.cpp (NVIDIA, GGML, Apache-2.0 code) | Only on `main` and the nightly build; not in a tagged release | Metal listed for this model; IQ4_NL decoder; no speculative decoding; offline only; word timestamps and speakers supported; C API and shared libraries |
| NVIDIA's own GGUF files | Announced, not public | – |
| Community GGUF from AtomicChat (OpenMDW) | Public | 4-bit decoder 19.7–22.6 GB plus a 1.67 GB encoder file; tested on CUDA only |
| Core ML: FluidAudio "Transcribe Lite" | Released in FluidAudio v0.18.0 | Encoder and CTC head only, without the LLM; evaluated in English only; macOS 15 or newer |
| MLX: mlx-audio with nativ-community files | Public | Built from the early-access checkpoint under an evaluation license; no word timestamps |
| MLX: mere.run (Swift) | Files public; runtime change not merged | Built from the public checkpoint; no CTC timestamps |
| ONNX and sherpa-onnx | None found | Only the 0.6B sibling is exported |

**NeMo-Speech.cpp.** This is NVIDIA's "official solution for local speech inference". It is built on ggml, the same tensor library whisper.cpp uses, with CPU, CUDA, Vulkan and Metal backends, prebuilt Apple Silicon macOS archives, and a C API, shared libraries and CMake package for embedding in an app ([README](https://github.com/NVIDIA/NeMo-Speech.cpp), [releases](https://github.com/NVIDIA/NeMo-Speech.cpp/releases)). Its docs for this model list Metal under the "upstream llama.cpp" path, with "no speculative decoding; IQ4_NL decoder" ([models and platforms](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/models.md)). However:

- **Not released yet.** The README's model table still lists only the 0.6B–1.1B ASR models. The latest tagged release, v0.2.0 from October 2, doesn't mention this model ([releases](https://github.com/NVIDIA/NeMo-Speech.cpp/releases)), and the SALM docs don't exist at that tag (the path returns 404). They exist only on `main`. The docs say release archives include SALM support, so the nightly archive should too; I didn't download it to confirm.
- **Memory is reserved up front.** On Metal, each decode slot reserves its whole context when it starts, plus about 48 MiB of recurrent state. For a laptop the docs suggest 4 slots of 18,432 tokens each, which holds one hour of audio in about 0.5 GiB of KV cache. For a 24 GB GPU the suggested settings use the IQ4_NL model and cap a request at 29 minutes ([configuration](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/configuration.md)).
- **Model files must be converted.** NVIDIA's GGUF files aren't public yet. The bundled converter can build them from the public 67.5 GB checkpoint ([models and platforms](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/models.md)).
- **Building on a Mac** needs the Xcode Command Line Tools plus Homebrew's cmake, ninja, sentencepiece and abseil. The speech-LLM component is off by default except in the `*-server` presets ([build docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/build.md)).
- **No Mac measurements for this model are published,** and the [issue tracker](https://github.com/NVIDIA/NeMo-Speech.cpp/issues) has no reports about it on Metal yet.

**AtomicChat GGUF (community, OpenMDW).** Each model is the 1.67 GB encoder file plus one decoder file. The publisher labels each decoder by target hardware ([card](https://huggingface.co/AtomicChat/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-GGUF)):

- Q8_0, 35.00 GB: "64 GB Macs"
- IQ4_NL_L, 22.55 GB: "32 GB GPUs and Macs"
- IQ4_NL, 19.68 GB: for "CPU, Metal, Vulkan"
- Q2_0_L, 15.55 GB: "24 GB Macs"

All of their accuracy checks ran on an A100: "Our measurements ran on CUDA only." They report that NVIDIA's own converter produces a 20.35 GB IQ4_NL decoder.

**FluidAudio (Core ML).** FluidAudio v0.18.0, released October 28, ships "Nemotron 3.5 Transcribe Lite": NVIDIA's roughly 600M-parameter encoder and its CTC head as Core ML models, *without the 30B language model*. It runs as a simple greedy CTC recognizer next to FluidAudio's existing Nemotron 3 Diarization port ([release notes](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0), [PR #1069](https://github.com/FluidInference/FluidAudio/pull/1069)).

- The download is 1.36 GB, and it requires macOS 15 / iOS 18 or newer ([docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/NemotronTranscribeLite.md), [PR #1070](https://github.com/FluidInference/FluidAudio/pull/1070)).
- It is very fast: a 49.5-minute meeting took 5.53 s on an M5 Pro (537× real time).
- Accuracy is far below the full model: 5.50% WER on LibriSpeech test-clean versus NVIDIA's 1.09%, and 26.4% WER on an AMI meeting ([PR #1069](https://github.com/FluidInference/FluidAudio/pull/1069)).
- "Only English was evaluated" ([Hugging Face card](https://huggingface.co/FluidInference/nemotron-3.5-transcribe-lite-coreml)).
- Searching FluidAudio's issues and PRs for "nemotron" turned up no proposal to port the full model ([search](https://github.com/FluidInference/FluidAudio/issues?q=nemotron)). A full Core ML port would mean converting the 30B mixture-of-experts language model with its Mamba layers. Nobody has published one, and FluidAudio chose to ship only the audio side.

**MLX.**

- **mlx-audio and nativ-community.** mlx-audio's implementation targets the early-access checkpoint (`…-EA-0.1.0` from NGC, under the evaluation license). It produces no word timestamps and encodes the whole recording before it starts generating text ([README](https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/nemotron_transcribe/README.md)). nativ-community's MLX conversions of that checkpoint report, on an M3 Ultra with 512 GB, peak MLX memory of 20.37 GB at 4-bit (65.62 GB in BF16), and a 53.8-second clip transcribed in 1.59 s, 33.8× real time ([Neywa Labs post](https://www.neywalabs.ai/blog/nemotron-transcribe-nativ), [card](https://huggingface.co/nativ-community/Nemotron-3.5-Transcribe-30B-A4B-EA-4bit)).
- **mere.run (Swift).** This Swift/MLX conversion of the public checkpoint (OpenMDW) stores the routed experts in 4-bit, giving 25.07 GB of files ([card](https://huggingface.co/Sawfwair/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B-MLX-4bit)).
  - On an M5 Max with 128 GiB, peak process memory was 21.83 GiB, and a 46.6-second recording took 6.45 s including model load.
  - Accuracy was evaluated in English only, and CTC timestamps and live streaming are outside what it supports.
  - It needs a runtime change in mere.run that hasn't been merged yet.
- **A 3-bit research build.** One MLX build with 3-bit experts uses about 17 GB and reports 1.17% and 2.80% WER on LibriSpeech test-clean and test-other, at 23.6× real time on an M5 Pro. Its authors call it "just a research experiment" ([card](https://huggingface.co/divergentlabs/Nemotron-3.5-Transcribe-30B-A4B-MLX)).
- **mlx-community and parakeet-mlx.** mlx-community has no Transcribe conversion; it hosts the 0.6B sibling ([mlx-audio model list](https://blaizzy.github.io/mlx-audio/models/stt/), [Hugging Face search](https://huggingface.co/api/models?search=Nemotron-3.5-Transcribe&limit=50)), and parakeet-mlx supports only Parakeet models ([parakeet-mlx](https://github.com/senstella/parakeet-mlx)).

**ONNX.** sherpa-onnx exports only `nemotron-3.5-asr-streaming-0.6b` ([sherpa-onnx export](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/nemo/nemotron-3.5-asr-streaming-0.6b/README.md)). I found no ONNX export of Transcribe.

**For scale.** Bekitzur's current English model file, the official `ggml-large-v3-turbo.bin`, is about 1.6 GB ([whisper.cpp model files](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo.bin)). A 4-bit Transcribe needs roughly 22 GB for the decoder and encoder files alone (my arithmetic from the sizes above), before runtime buffers. On a 32 GB laptop that also has to run macOS, Bekitzur and FluidAudio, that leaves about 10 GB.

## 6. Verdict for Bekitzur

**Replace ivrit.ai for Hebrew? No, not now.**

- NVIDIA rates Hebrew in its lowest tier, and Hebrew was only 0.55% of the training audio.
- The published Hebrew figure (20.4–21.0% WER on FLEURS) is no better than ivrit.ai's turbo fine-tune on the same test set (18.1% on ivrit.ai's leaderboard, scored differently).
- There is no Hebrew–English code-switching result, and NVIDIA names code-switching as a weakness. That is exactly our hardest Hebrew case.
- Speaker-attributed transcription isn't offered for Hebrew. We would keep FluidAudio for speakers either way.

**Replace Whisper large-v3-turbo for English? Not as a drop-in.**

- In NVIDIA's numbers, accuracy and word timestamps are clearly better than Whisper large-v3. NVIDIA didn't compare against turbo.
- But the Mac runtime for this model is new and unreleased, keeps 20+ GB of memory in use, and has no streaming. Our live helper process would have to hold the model in memory for the whole call.
- A plausible future role is an optional after-the-call English pass over the full recording, using its long-form support and word timestamps, if it fits in memory and runs fast enough on our laptops.

**Replace both? No.**

**What would have to be true**

1. NeMo-Speech.cpp ships a tagged release with this model on Metal, and public OpenMDW GGUF files exist, either NVIDIA's own or a conversion we have checked. We should avoid conversions of the early-access checkpoint, which is under an evaluation license.
2. With Bekitzur and FluidAudio running, peak memory on a 32 GB laptop still leaves macOS comfortable headroom, and speed is acceptable on our oldest supported chip.
3. For Hebrew: on our scripted read, using the 4-bit model the Mac would actually run, it beats ivrit.ai turbo (16.0% WER, 97.3% of Hebrew words right) and writes English terms in English letters. A Hebrew fine-tune could change this picture: NVIDIA provides a fine-tuning toolkit, but it needs an NVIDIA GPU, and no Hebrew fine-tune exists yet.
4. For English: it clearly beats whisper.cpp large-v3-turbo on our own meeting recordings, and its word timestamps split speaker changes at least as well as DTW.

**What to test**

1. **Runtime.** NeMo-Speech.cpp's nightly build with the Metal backend on a 32 GB Apple Silicon laptop, using an IQ4_NL decoder (about 20 GB) or IQ4_NL_L (22.55 GB) plus the encoder file.
2. **Our scripted Hebrew read,** with three instructions:
   - the default ("Audio transcription. Language: as spoken. …");
   - the same with the language code `he`;
   - a script-control instruction modeled on NVIDIA's code-switching prompts, for example "Transcribe verbatim in the original languages. Write Hebrew in Hebrew script and English words in the Latin alphabet.", optionally followed by "Context terms: …" listing our tech terms. Context terms go in the instruction text, because NeMo-Speech.cpp doesn't support its separate phrase-boosting fields for this model ([docs](https://github.com/NVIDIA/NeMo-Speech.cpp/blob/main/docs/salm/README.md)).

   Score WER, the share of Hebrew words right, and the share of English terms written in Latin letters, against the 16.0% / 97.3% baseline.
3. **English meetings.** Run a handful of real meeting recordings against whisper.cpp large-v3-turbo, and compare word timestamps at speaker changes.
4. **Resources.** Measure peak memory, cold-load time, processing time per minute of audio, and a one-hour recording. Also measure latency for 10–30 s chunks, to learn whether live use is even conceivable.
5. **Robustness.** Check silence and music (for invented text), generation loops (with NVIDIA's guardrail applied), and that "as spoken" never translates Hebrew into English.
6. **A cheap side experiment.** Run FluidAudio's Transcribe Lite on the Hebrew read to see what the encoder alone produces. NVIDIA describes the CTC head as aligning "any generated transcript" to the audio. Whether it could time ivrit.ai's Hebrew output better than DTW is untested, and trying it would need custom alignment code.

**Things to watch:** NVIDIA publishing its GGUF files and a tagged NeMo-Speech.cpp release that includes this model; Mac measurements in NeMo-Speech.cpp's issues; a Nemotron 3.5 Transcribe entry on ivrit.ai's Hebrew leaderboard; and any Hebrew fine-tunes.

## Inconsistencies and gaps found

- **GGUF availability.** NVIDIA's research page and report list a GGUF release, but the Hugging Face repository isn't public, and the blog says local deployment is "coming soon". The blog also calls quantized versions "coming soon", although the FP8 and NVFP4 repositories are already public.
- **Hebrew FLEURS WER.** The card says 20.97% and the report says 20.36%. Many languages differ slightly between the two documents, which suggests separate evaluation runs.
- **English leaderboard WER.** 4.71% covers the 9 public sets; 5.33% is the leaderboard's default average, which includes private sets.
- **Mac support.** The card's hardware table lists only NVIDIA GPUs on Linux and Windows, while NeMo-Speech.cpp's docs list Metal for the same model.
- **Language detection.** The card reports language-ID results, while NeMo-Speech.cpp says "the model does not detect the language". This seems to describe the runtime, not the model's ability to answer a language-ID prompt.
- **Language count.** The language matrix has 41 rows; Norwegian is listed without transcription support.
- **Repository name.** A footnote in the report links to `nvidia/Nemotron-3.5-Transcribe-30B-A4B`, but the actual repository is `nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B`.
- **Early-access weights.** Nothing documents whether the NGC early-access weights are identical to the public OpenMDW release.
- **No arXiv paper.** I found no arXiv version of the technical report; it exists only as a PDF on NVIDIA's site.

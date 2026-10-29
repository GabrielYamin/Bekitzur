# Newer open speech models for Bekitzur: Hebrew, English and speakers

Checked on October 29, 2026. This covers open-weight models released from about mid-2025 to now that could run locally on Bekitzur's Macs. NVIDIA Nemotron 3.5 Transcribe has its own note, [nemotron-transcribe.md](nemotron-transcribe.md), and is only referenced here.

WER is word error rate. DER is diarization error rate: missed speech, false alarms and speech given to the wrong speaker, as a share of speech time. Lower is better for both. Numbers from different test sets or scoring setups are not comparable unless stated.

## Verdict for Bekitzur

- **Speakers: test NVIDIA Nemotron 3 Diarization first. It is the most likely fix for the merged-voices bug.**
  - It is already in Bekitzur's FluidAudio 0.17.7: FluidAudio added it in v0.17.0 ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.0)).
  - It handles 8 speakers instead of Sortformer's 4. It runs on the Neural Engine, and its OpenMDW license allows commercial use ([model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)).
  - Compared with Sortformer 4spk v2.1, NVIDIA reports 11.1% vs 21.4% DER on far-field AMI meetings. It also gets the speaker count right on 91.6% vs 84.4% of CALLHOME phone calls ([model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)).
  - On an independent English benchmark it merged different people into one speaker in 7.9% of sessions. Sortformer 4spk v2 did so in 22.3% and pyannote community-1 in 24.5% ([Voice Arena](https://voicearena.com/diarization-bench)).
  - It has not been evaluated on Hebrew.
- **Hebrew: keep ivrit.ai. No newer model beats it.**
  - No model released since mid-2025 publishes better Hebrew numbers than ivrit.ai's turbo fine-tune.
  - The one model with slightly better numbers is ivrit.ai's own larger fine-tune, whisper-large-v3, from the same May 2025 training round, with a GGML build. It scores 17.4% vs 18.1% WER on FLEURS and is better on 4 of ivrit.ai's 5 test sets ([leaderboard data](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)). But it has 32 decoder layers instead of 4 ([OpenAI card](https://huggingface.co/openai/whisper-large-v3-turbo)), so it is slower. It is a cheap whisper.cpp test for an after-the-call pass.
  - Newer multilingual models either don't support Hebrew (Qwen3-ASR, Voxtral, Granite Speech, Cohere Transcribe, Kyutai) or publish no Hebrew results (Microsoft VibeVoice-ASR).
  - The new small Hebrew models come close to the turbo fine-tune on conversation, but they write English words in Hebrew letters or spell them out letter by letter (section 1.2).
- **English: test Parakeet through FluidAudio.**
  - Parakeet TDT 0.6B v2 averages 6.02% WER on the Open ASR Leaderboard vs 7.64% for Whisper large-v3-turbo, and 9.1% vs 13.9% on AMI meetings ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
  - It runs on the Neural Engine in the FluidAudio package Bekitzur already uses, and returns token timings.
  - Parakeet Ultra, released September 2026 in the same package, is a more accurate retraining of Parakeet v3 ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)).
  - On the leaderboard's long-recording track, Parakeet v2 is no better than turbo (13.08% vs 12.82%), so only Bekitzur's own meetings can decide.
  - If Parakeet disappoints, Qwen3-ASR-1.7B (5.40%) is the most accurate small open model. It needs an MLX or GGML runtime and a separate aligner for word times.
- **Order of tests:**
  1. Nemotron 3 Diarization.
  2. ivrit.ai whisper-large-v3 GGML.
  3. Parakeet v2 and Ultra for English.
  4. Optional: ivrit.ai's streaming Zipformer for live Hebrew captions, and Qwen3-ASR for English.

  All recommended models are small, a few GB at most, so memory on the 32 GB laptops is not the constraint. The test plan is in section 5.

## Ranked candidates

### Hebrew

WER on ivrit.ai's leaderboard, in this order: eval-d1 (podcast) / eval-whatsapp (voice notes) / SASpeech / FLEURS / Kan. Each model is linked to its card; the other facts are cited in section 1.

| # | Model | Hebrew WER, % | English terms | Size | License | Word times | Streaming | Mac runtime |
|---|---|---|---|---|---|---|---|---|
| now | [ivrit.ai whisper-large-v3-turbo](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo) (2025.05.13) | [5.3 / 7.1 / 6.6 / 18.1 / 8.2](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv) | Not published | 1.6 GB GGML | Apache-2.0 | DTW | Chunked | whisper.cpp |
| 1 | [ivrit.ai whisper-large-v3](https://huggingface.co/ivrit-ai/whisper-large-v3-ggml) (2025.05.13) | [5.1 / 7.2 / 6.4 / 17.4 / 8.1](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv) | Not published | 3.1 GB GGML | Apache-2.0 | DTW (large-v3 preset) | Chunked, slower | whisper.cpp |
| 2 | [ivrit.ai zipformer2-66m-streaming-he](https://huggingface.co/ivrit-ai/zipformer2-66m-streaming-he) (Oct 2026) | [5.3 / 8.8 / 6.4 / 23.4 / 11.8](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv) | Weak: spelled letter by letter | 66M; 72 MB int8 | CC-BY-4.0 | Not documented | Yes, 1.28 s chunks | sherpa-onnx (Swift API) |
| 3 | [Community Hebrew fine-tune of Parakeet TDT 0.6B v3](https://huggingface.co/thewh1teagle/parakeet-tdt-0.6b-v3-he) (Oct 2026) | [5.7 / 9.0 / 7.2 / 23.1 / 9.8](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/discussions/6) (submitted, not merged) | Written in Hebrew letters | 0.6B; 741 MB Q8_0 | CC-BY-4.0 | Token times | No | transcribe.cpp (GGML) |
| 4 | [Microsoft VibeVoice-ASR](https://huggingface.co/microsoft/VibeVoice-ASR) (Jan 2026) | None published | Claimed; trained mainly on English–Chinese | 9B | MIT | Segment times | No | mlx-audio (Python only) |
| 5 | [Meta Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) (Nov 2025; v2 Dec 2025) | Only CER 6.7%, on Meta's own set | Not published | 0.3–7.8B | Apache-2.0 | Not documented | No; 40 s inputs | sherpa-onnx; Python reference |

### English

Open ASR Leaderboard, version of October 28, 2026. "Average" is the leaderboard's default over 11 test sets, two of them private. "AMI" is meetings, "Conversational" is the private conversational set, and "Long-form" is the separate track of hour-long recordings (Earnings-21, Earnings-22, CORAAL) ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).

| # | Model | Average | AMI | Conversational | Long-form | Size | License | Word times | Streaming | Mac runtime |
|---|---|---|---|---|---|---|---|---|---|---|
| now | Whisper large-v3-turbo | 7.64 | 13.88 | 15.40 | 12.82 | 0.8B | – | DTW | Chunked | whisper.cpp |
| 1 | [Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) (2025) | 6.02 | 9.09 | 13.58 | 13.08 | 0.6B | CC-BY-4.0 | Token times | Sliding window | FluidAudio Core ML |
| 2 | [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) (Sep 2026) | not listed | – | – | – | 0.6B; 595 MB encoder | CC-BY-4.0 | Token times | Sliding window | FluidAudio Core ML |
| 3 | [Nemotron Speech Streaming EN 0.6B](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) (Dec 2025) | 6.60 | 8.84 | 13.28 | – | 0.6B | NVIDIA Open Model License | Token times | Yes | FluidAudio Core ML |
| 4 | [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) (Jan 2026) | 5.40 | 8.31 | 12.14 | – | 2.35B; 4.7 GB BF16 | Apache-2.0 | Separate 0.6B aligner | MLX Swift API | mlx-audio-swift, transcribe.cpp, sherpa-onnx |
| 5 | [Granite Speech 5.0 2B](https://huggingface.co/ibm-granite/granite-speech-5.0-2b) (Oct 2026) | 5.68 | 6.96 | 13.79 | – | 3.1 GB Q8_0 GGUF | Apache-2.0 | No | Not documented | llama.cpp, mlx-audio |

### Speakers

| # | Model | Published DER | Speaker count | Max speakers | License | Mac runtime |
|---|---|---|---|---|---|---|
| now | Sortformer 4spk v2/v2.1, with fallback to pyannote community-1 | [Voice Arena](https://voicearena.com/diarization-bench): 24.6% (Sortformer v2), 30.6% (community-1) | Merged people in 22.3% / 24.5% of Voice Arena sessions | 4 / no fixed limit | Sortformer: CC-BY-4.0 (v2) or NVIDIA Open Model License (v2.1); community-1: CC-BY-4.0 | FluidAudio Core ML |
| 1 | [NVIDIA Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) (Sep 2026) | AMI far-field 11.1% vs 21.4%, DIHARD III 12.7% vs 19.1% (both vs Sortformer v2.1); Voice Arena 14.7% | Right on 91.6% of CALLHOME calls (Sortformer v2.1: 84.4%); merged people in 7.9% of Voice Arena sessions | 8 | OpenMDW-1.1 | FluidAudio Core ML, v0.17.0+ (190 MB, or 95 MB quantized) |
| 2 | [LS-EEND](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/LS-EEND.md) (FluidAudio port) | DIHARD III 19.6%, CALLHOME 12.1%, AMI 20.8% | Not published | 10 | MIT (Core ML build) | FluidAudio Core ML; 8 kHz input |
| – | Not usable: DiariZen v2 (non-commercial license), pyannoteAI precision-2/3 (commercial, not open weights), VibeVoice-ASR's built-in speakers (no Hebrew results) | | | | | |

## 1. Hebrew

### 1.1 ivrit.ai's models and leaderboard

- **The leaderboard.** It scores five Hebrew test sets: a podcast, WhatsApp voice notes, SASpeech (podcast speech), FLEURS (read Wikipedia sentences) and Kan (broadcast clips) ([leaderboard description](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/src/about.py)).
  - The data file was last updated about two weeks ago, when the Zipformer was added ([data file](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)).
  - Scoring uses jiwer after a Hebrew normalizer that removes niqqud, quote marks and direction marks. Latin letters are kept, so an English term written in the wrong script counts as an error ([scoring code](https://github.com/ivrit-ai/asr-training/blob/master/evaluate_model.py)). None of the five sets targets code-switching.
  - The ivrit.ai rows are the CTranslate2 builds run with faster-whisper. Bekitzur runs the GGML conversions of the same weights, so its numbers will differ somewhat.
- **ivrit.ai's newest Whisper weights are still from May 2025.** Both GGML repositories were last updated on May 22, 2025 ("New version: 2025.05.13") ([turbo commits](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/commits/main), [large-v3 commits](https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/commits/main)). An October 2025 change to the CTranslate2 repository only edited the README ([commits](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ct2/commits/main)).
  - To confirm Bekitzur has the latest turbo build: the current file is 1,624,555,275 bytes with SHA-256 `c8090411…ef8641b1` ([file list](https://huggingface.co/api/models/ivrit-ai/whisper-large-v3-turbo-ggml/tree/main)).
- **ivrit.ai's own recommendations** ([organization page](https://huggingface.co/ivrit-ai)):
  - whisper-large-v3 for the best Hebrew accuracy;
  - the turbo GGML for laptops and whisper.cpp;
  - the Zipformer for "real-time / on-device streaming";
  - its pyannote 3.1 mirror for speakers.
- **The turbo fine-tune can't detect languages.** Its card says language detection "has been degraded during training" and that the language should be set to Hebrew explicitly ([model card](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo)). Bekitzur's language detection should keep using stock Whisper.
- **A new dataset is useful for testing word times.** `eval-forced-alignment` (September 2026) has 72 Hebrew clips, about 10 minutes, with human-checked word timings. Most come from Knesset committee recordings ([dataset](https://huggingface.co/datasets/ivrit-ai/eval-forced-alignment)).
- The other models ivrit.ai released in this period are Yiddish fine-tunes ("yi-whisper-…"), which don't apply here ([model list](https://huggingface.co/ivrit-ai/models)).

### 1.2 Candidates

**1. ivrit.ai whisper-large-v3 (2025.05.13), GGML.**
- **Accuracy.** It beats the turbo fine-tune on 4 of 5 sets by 0.1–0.7 points and is 0.1 point worse on WhatsApp notes ([leaderboard data](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)). The five-set average is 8.84% vs 9.06%, about 2% fewer errors (my arithmetic). On FLEURS, the read-speech set closest to Bekitzur's scripted read, it is 17.4% vs 18.1%.
- **Cost.** Turbo is the same model with the decoder cut from 32 layers to 4, "way faster, at the expense of a minor quality degradation" ([OpenAI card](https://huggingface.co/openai/whisper-large-v3-turbo)). The GGML file is 3.1 GB vs 1.6 GB ([file list](https://huggingface.co/ivrit-ai/whisper-large-v3-ggml/tree/main)). whisper.cpp lists about 3.9 GB of memory for large models ([whisper.cpp README](https://github.com/ggml-org/whisper.cpp/blob/master/README.md#memory-usage)). No Mac speed comparison has been published.
- **Integration.** It needs only a model swap in whisper.cpp. Word timestamps keep working: whisper.cpp has a DTW alignment preset for large-v3 next to the one for large-v3-turbo ([whisper.h](https://github.com/ggml-org/whisper.cpp/blob/master/include/whisper.h)).
- **License:** Apache-2.0, like all ivrit.ai models ([organization page](https://huggingface.co/ivrit-ai)).

**2. ivrit.ai zipformer2-66m-streaming-he (October 14, 2026).** Everything below is from the [model card](https://huggingface.co/ivrit-ai/zipformer2-66m-streaming-he) unless noted.
- **What it is.** A 66M-parameter streaming transducer that decodes in 1.28 s chunks. It is ivrit.ai's mirror of a community model, with extra ONNX exports, and it powers live-transcribe.ivrit.ai. It was trained on about 20,000 hours of ivrit.ai audio labeled by ivrit.ai's Whisper models.
- **Accuracy.** On conversational sets it nearly matches the turbo fine-tune: eval-d1 5.3% vs 5.3% and WhatsApp 8.8% vs 7.1%. It is clearly worse on read speech: FLEURS 23.4% vs 18.1% ([leaderboard data](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/blob/main/benchmark.csv)).
- **Limitations.** "English is weak (spelled letter by letter)", and numbers come out inconsistently as words or digits.
- **Size, license, runtime.** The int8 files total about 72 MB ([file list](https://huggingface.co/ivrit-ai/zipformer2-66m-streaming-he/tree/main/sherpa-onnx)). License CC-BY-4.0. It runs in sherpa-onnx, which has a Swift API ([sherpa-onnx releases](https://github.com/k2-fsa/sherpa-onnx/releases)). The card doesn't mention word timestamps.
- **Role for Bekitzur:** only a live Hebrew preview during calls, with Whisper still producing the final transcript.

**3. Community Hebrew fine-tune of Parakeet TDT 0.6B v3 (October 1, 2026).**
- **Training.** About 9,000 hours of ivrit.ai audio, labeled with ivrit.ai's whisper-large-v3-turbo ([model card](https://huggingface.co/thewh1teagle/parakeet-tdt-0.6b-v3-he)).
- **Accuracy.** It is close to, but never better than, the turbo fine-tune that labeled its training data. Published figures differ by source:
  - Leaderboard submission (not merged yet): 5.7 / 9.0 / 7.2 / 23.1 / 9.8 ([pull request](https://huggingface.co/spaces/ivrit-ai/hebrew-transcription-leaderboard/discussions/6)).
  - Model card: 6.1% (eval-d1) and 8.8% (WhatsApp).
  - Q8_0 GGML build: 5.30% and 8.44% on the full sets ([GGUF card](https://huggingface.co/vladkens/parakeet-tdt-0.6b-v3-he-gguf)).
- **Limitations.** "Hebrew only: English words come out in Hebrew letters". It is weaker on read encyclopedic text with "rare names, numbers, Latin terms" ([model card](https://huggingface.co/thewh1teagle/parakeet-tdt-0.6b-v3-he)). That fails Bekitzur's requirement to keep English terms in English letters.
- **Runtime.** The Q8_0 file is 741 MB and runs unpatched in transcribe.cpp ([GGUF card](https://huggingface.co/vladkens/parakeet-tdt-0.6b-v3-he-gguf)). transcribe.cpp gives token timestamps for the Parakeet family ([transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)). I found no Core ML build. License CC-BY-4.0.

**4. Microsoft VibeVoice-ASR (January 21, 2026).**
- **What it is.** A 9B-parameter, MIT-licensed model that transcribes up to 60 minutes in one pass. It outputs speaker labels and timestamps, accepts hotword lists, supports "over 50 languages" and "natively handles code-switching" ([model card](https://huggingface.co/microsoft/VibeVoice-ASR)). Hebrew is in its language tags.
- **Why it ranks low.**
  - Its report has no Hebrew results.
  - It warns that fine-tuning "predominantly focused on English, Chinese, and code-switching data", so languages left out of that stage may degrade ([technical report](https://arxiv.org/html/2601.18184)).
  - The streaming variants cover 10 languages, without Hebrew ([streaming model](https://huggingface.co/microsoft/VibeVoice-ASR-Streaming-7B)).
  - It is weaker than turbo in English (8.16% average) ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **Runtime.** mlx-audio's Python package supports it ([mlx-audio models](https://blaizzy.github.io/mlx-audio/models/stt/)). The Swift package doesn't list it ([mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)).

**5. Meta Omnilingual ASR (November 2025; v2 checkpoints December 2025).**
- **What it is.** Apache-2.0 models for over 1,600 languages, from 0.3B to 7.8B parameters ([README](https://github.com/facebookresearch/omnilingual-asr)).
- **Hebrew.** The only Hebrew figure is a character error rate of 6.7% for the original 7B LLM model, trained on just 155.5 hours of Hebrew ([per-language results](https://github.com/facebookresearch/omnilingual-asr/blob/main/per_language_results_table_7B_llm_asr.csv)). That is not a word error rate, and the test set isn't the same as ivrit.ai's.
- **Limitations.** Inputs must be under 40 seconds, except for the "Unlimited" LLM variants ([README](https://github.com/facebookresearch/omnilingual-asr)). English is weak (8.13% average for the 7B LLM v2) ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **Not on ivrit.ai's leaderboard,** although ivrit.ai's evaluation code already includes an Omnilingual engine ([engine](https://github.com/ivrit-ai/asr-training/blob/master/engines/omnilingual_engine.py)).
- **Runtime.** sherpa-onnx supports Omnilingual ([release notes](https://github.com/k2-fsa/sherpa-onnx/releases)).

### 1.3 Checked and ruled out for Hebrew

- **No Hebrew support:**
  - Qwen3-ASR covers 30 languages and 22 Chinese dialects ([card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)).
  - Mistral Voxtral: the July 2025 models cover 8 languages ([Mini 3B](https://huggingface.co/mistralai/Voxtral-Mini-3B-2507)) and Voxtral Realtime covers 13 ([Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)). The "Transcribe 3" versions appear on Voice Arena only as commercial API entries ([Voice Arena](https://voicearena.com/diarization-bench)), and I found no open weights for them on Hugging Face.
  - IBM Granite Speech 5.0: six languages ([card](https://huggingface.co/ibm-granite/granite-speech-5.0-2b)).
  - Cohere Transcribe: 14 languages ([card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)).
  - Kyutai STT: English, or English and French ([models](https://huggingface.co/kyutai/stt-1b-en_fr)).
  - Microsoft Phi-4-multimodal: eight speech languages, February 2025 ([card](https://huggingface.co/microsoft/Phi-4-multimodal-instruct)).
  - NVIDIA Parakeet v3, Parakeet Ultra and Nemotron Unified: 25 European languages ([FluidAudio README](https://github.com/FluidInference/FluidAudio), [v0.18.0 notes](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0)).
  - OpenMOSS MOSS-Transcribe-Diarize: its card lists English and Chinese ([model page](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize)).
- **Google Gemma 4 (Apache-2.0).** The E2B, E4B and 12B models accept at most 30 seconds of audio. The card gives no per-language speech results ([card](https://huggingface.co/google/gemma-4-E4B-it)). It scores 11.86% in English ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **NVIDIA Nemotron 3.5 ASR streaming 0.6B.** Hebrew needs fine-tuning, and ivrit.ai measures 46.0% WER on FLEURS. Nemotron 3.5 Transcribe scores 20.4–21.0% on FLEURS Hebrew. Both are in [nemotron-transcribe.md](nemotron-transcribe.md).
- **Weaker community Hebrew models:**
  - BuzzASR's whisper-large-v3 fine-tune: 28.6% WER on FLEURS ([card](https://huggingface.co/BuzzASR/hebrew)).
  - A 351M Hebrew+English streaming transducer on EmbeddingGemma 2: 5.80 / 10.30 / 23.39 on eval-d1 / WhatsApp / FLEURS, worse than the turbo fine-tune in its own comparison. It has no punctuation and runs in PyTorch only ([card](https://huggingface.co/MaorB/embeddinggemma-2-asr-hebrew-english-streaming)).
  - A Hebrew fine-tune of Nemotron 3.5 ASR: 17.4% on a Knesset dev set, NeMo only ([card](https://huggingface.co/notmax123/nemotron-3.5-asr-hebrew-streaming-0.6b)).

### 1.4 English terms inside Hebrew speech

No model publishes a Hebrew–English code-switching result.
- ivrit.ai's test sets aren't built for it (section 1.1).
- The two new fast Hebrew models handle English badly (section 1.2).
- VibeVoice-ASR's code-switching training was synthetic English–Chinese speech ([report](https://arxiv.org/html/2601.18184)).
- NVIDIA calls code-switching a weakness of Nemotron 3.5 Transcribe ([nemotron-transcribe.md](nemotron-transcribe.md)).

The ivrit.ai Whisper models and the models with mixed Hebrew–English vocabularies (VibeVoice-ASR, the EmbeddingGemma 2 transducer, Nemotron 3.5 Transcribe) can at least write Latin script inside Hebrew text. The Parakeet fine-tune writes English words in Hebrew letters, and the Zipformer spells them out letter by letter. No one publishes how often any model gets English terms right, so Bekitzur's own scripted read is the only evidence that matters. It should add a score for English terms (section 5.2).

## 2. English

### 2.1 The leaderboard

- **Source of the numbers.** They come from the public Open ASR Leaderboard app as of its October 28, 2026 update ("Add nvidia/Nemotron-3.5-Transcribe-30B-A4B") ([version list](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard/blob/main/init.py)). The underlying results file requires a Hugging Face login, so I read the table from the app itself ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **What the average covers.** It is the mean over 11 sets, including two private ones (I checked it against turbo's per-set numbers). The set list has changed over time: Cohere's card quotes 5.42% on the older 8-set version ([Cohere card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)), while the current table shows 5.77%.
- **Speed figures don't transfer.** The leaderboard's speed numbers are from NVIDIA GPUs, not Macs.

Selected open models, as average / AMI: Nemotron 3.5 Transcribe 5.33 / 7.78 (see the other note), Qwen3-ASR-1.7B 5.40 / 8.31, Granite Speech 5.0 2B 5.68 / 6.96, Cohere Transcribe 5.77 / 7.02, Canary-Qwen-2.5B 5.94 / 7.91, Parakeet TDT v2 6.02 / 9.09, Parakeet TDT v3 6.18 / 9.42, Nemotron Speech Streaming EN 6.60 / 8.84, distil-large-v3.5 6.76 / 12.09, Phonon-2 6.87 / 9.32, Whisper large-v3 7.16 / 13.63, Voxtral Mini 3B 7.25 / 13.57, **Whisper large-v3-turbo 7.64 / 13.88**, Omnilingual LLM 7B v2 8.13 / 13.86, VibeVoice-ASR 8.16 / 12.02, Voxtral Mini 4B Realtime 8.44 / 13.34, Gemma 4 E4B 11.86 / 20.57 ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).

### 2.2 Candidates

**1. Parakeet TDT 0.6B v2 on FluidAudio.**
- **Leaderboard.** 6.02% average and 9.09% on AMI vs turbo's 7.64% and 13.88%. On the long-recording track, though, it scores 13.08% vs turbo's 12.82% ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **On a Mac.** On an M4 Pro with 48 GB, FluidAudio measures 2.1% average WER on LibriSpeech test-clean at about 146× real time ([FluidAudio benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)). FluidAudio recommends v2 "if you only need English", for its better recall ([ASR guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md)).
- **Integration.** Results include token timings ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Bark3.md)). Live transcription uses a sliding window ([README](https://github.com/FluidInference/FluidAudio)). There is also a keyword-boosting option for domain terms. On FluidAudio's earnings-call test it found 85.2% of the listed terms with 99.3% precision ([benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)).
- **License:** CC-BY-4.0 ([model page](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)).
- **Language detection.** Parakeet has none, so Bekitzur still needs stock Whisper's language detection to route calls.

**2. Parakeet Ultra (September 22, 2026) on FluidAudio.**
- **What it is.** A full-precision post-training of Parakeet v3 by moondream, with the same architecture, 25 languages and API. FluidAudio's Core ML build has a 595 MB int8 encoder and needs macOS 14 or newer. FluidAudio calls it the "default choice for new integrations" ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)).
- **Accuracy vs v3, on FluidAudio's harness** ([benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)):
  - LibriSpeech test-clean 2.13% vs 2.27%, test-other 3.81% vs 4.12%.
  - A one-hour Earnings-22 recording: 13.5% vs 16.5%.
- **Gaps.** It is not on the Open ASR Leaderboard, and nobody has compared it with v2 on the same harness. FluidAudio's v2 figure is a per-file average, while Ultra's are corpus-level.
- **License:** CC-BY-4.0 ([model page](https://huggingface.co/moondream/parakeet-ultra)).
- **Related FluidAudio models.**
  - Underdog Bark 3.0 (v0.18.0) is an English retraining with a "verbatim" and a "clean" variant. On test-other it scores 4.96% vs v3's 4.12% ([Bark docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Bark3.md)).
  - Phonon-2 scores 6.87% on the leaderboard, worse than v2 ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).

**3. Nemotron Speech Streaming EN 0.6B (December 2025) for live English.**
- **Accuracy.** 6.60% average and 8.84% on AMI ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **On FluidAudio.** It runs as true streaming on the Neural Engine, with 0.56–2.24 s chunks and 2.58–2.71% WER on LibriSpeech test-clean ([benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)). It returns per-token timings ([FluidAudio v0.15.3](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.3)).
- **License:** NVIDIA Open Model License; commercial use allowed ([card](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)).
- **Role:** a candidate for the live helper process during English calls.

**4. Qwen3-ASR-1.7B (January 28, 2026).**
- **Accuracy.** The best small open model on the leaderboard: 5.40% average, 8.31% on AMI, and 12.14% on the conversational set ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **What it is.** Apache-2.0, with 2.35B parameters, about 4.7 GB in BF16 ([model info](https://huggingface.co/api/models/Qwen/Qwen3-ASR-1.7B)).
- **Limitations** ([card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B)):
  - The model itself gives no timestamps. Word times need a second model, Qwen3-ForcedAligner-0.6B, which supports English.
  - Qwen's own toolkit streams only with the vLLM backend.
- **Mac runtimes.**
  - mlx-audio-swift: an MIT Swift package with 8-, 6- and 4-bit Qwen3-ASR builds, the forced aligner and a streaming API. It is installed from its `main` branch ([mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)).
  - transcribe.cpp, without timestamps ([transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)).
  - sherpa-onnx ([release notes](https://github.com/k2-fsa/sherpa-onnx/releases)).
- **FluidAudio dropped its port.** It removed its "experimental Qwen3 ASR backend" in v0.15.3 ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.3)). The release notes don't say why, and the pull request didn't load for me.

**5. IBM Granite Speech 5.0 2B (October 20, 2026).**
- **Accuracy.** 5.68% average, and the lowest AMI figure of any open model listed: 6.96% ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
- **What it is** ([card](https://huggingface.co/ibm-granite/granite-speech-5.0-2b)): Apache-2.0, for English, French, German, Spanish, Portuguese and Japanese. Prompts can carry a keyword list of up to 2,000 terms. The card mentions no word timestamps.
- **Runtimes.** It runs in llama.cpp and mlx-audio. The Q8_0 GGUF is 1.96 GB plus a 1.16 GB audio file ([GGUF files](https://huggingface.co/ibm-granite/granite-speech-5.0-2b-GGUF/tree/main)).
- **Role:** interesting only for an after-the-call pass with a company term list, since it has no word times.

### 2.3 Checked and ruled out for English

- **Cohere Transcribe (Apache-2.0).** It has no timestamps or language detection, and "inconsistent performance on code-switched audio" ([card](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)). FluidAudio's port is still beta: about 2× real time on an M2, and a cold Neural Engine compile of about 3 minutes per process ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md)).
- **TheStage AI "TheWhisper" large-v3-turbo.** It scores 5.91% on the leaderboard, but the repository holds encrypted engines. Using them requires TheStage's SDK and an API token from their website, and the first downloads need network access ([card](https://huggingface.co/TheStageAI/thewhisper-large-v3-turbo)). That conflicts with the no-cloud rule.
- **Others:**
  - Canary-Qwen-2.5B (5.94%): transcribe.cpp lists no timestamp support for it ([transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)).
  - distil-large-v3.5 (6.76%): only 12.09% on AMI, and worse than turbo on the long-recording track ([leaderboard](https://huggingface.co/spaces/hf-audio/open_asr_leaderboard)).
  - VibeVoice-ASR, Voxtral and Gemma 4: all score worse than or about the same as turbo (section 2.1).

## 3. Speaker separation

### 3.1 NVIDIA Nemotron 3 Diarization

- **What it is.** Released September 23, 2026: a 100M-parameter successor to Streaming Sortformer for up to 8 speakers. One checkpoint serves both live and offline use, with input buffers from 0.32 s to 30.4 s. License: OpenMDW-1.1, "ready for commercial or non-commercial use" ([model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)).
- **NVIDIA's results against Sortformer 4spk v2.1,** each given at 30.4 s / 1.04 s latency. Collar 0, except 0.25 s for CALLHOME ([model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)):

  | Test set | Nemotron 3 DER | Sortformer v2.1 DER | Speaker count right, Nemotron 3 vs Sortformer v2.1 |
  |---|---|---|---|
  | CALLHOME part 2 (phone calls) | 9.10 / 10.29 | 10.32 / 11.31 | 91.6 / 89.2% vs 84.4 / 82.4% |
  | CALLHOME, 3-speaker calls | 9.26 / 10.90 | 10.41 / 11.26 | – |
  | CALLHOME, 4-speaker calls | 11.03 / 11.84 | 12.36 / 13.49 | – |
  | AMI far-field (SDM) | 11.14 / 12.80 | 21.42 / 21.73 | 87.5% vs 93.75% |
  | DIHARD III (11 domains) | 12.73 / 13.18 | 19.09 / 19.60 | 81.5 / 76.8% vs 75.3 / 69.5% |
  | NOTSOFAR1 far-field, 5–7 speakers | 13.21 / 15.44 | 38.42 / 39.84 | – |

  Speaker counting got worse on AMI: 2 of 16 meetings wrong instead of 1.
- **An independent check.** Voice Arena's early diarization results cover 139 English sessions, about 22 hours, scored with collar 0 ([Voice Arena](https://voicearena.com/diarization-bench)):
  - Overall DER: Nemotron 3 14.7%, DiariZen v2 19.3%, Sortformer 4spk v2 24.6%, pyannote community-1 30.6%.
  - On the 24 online calls: 11.7%, 17.0%, 19.7% and 27.9%.
  - Sessions where people were merged ("too few" speakers): 7.9% for Nemotron 3, 22.3% for Sortformer v2, 24.5% for community-1.

  Caveats: the online subset is small, the results are early, the Sortformer row is v2 rather than v2.1, and the benchmark is English only.
- **On a Mac, through FluidAudio.**
  - Added in v0.17.0 ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.0)), with a crash fix in v0.17.2 ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.2)) and an M3 Neural Engine fix in v0.17.4 ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.4)). Bekitzur's 0.17.7 contains all three.
  - The Core ML files are 190 MB, or 95 MB for the fully Neural-Engine W8A8 builds. They are public: not gated on October 29 ([model info](https://huggingface.co/api/models/FluidInference/nemotron-3-diarization-coreml)).
  - On an M5 Pro, AMI headset-mix meetings scored with NVIDIA's protocol give 9.36–10.07% DER depending on the preset, against NVIDIA's 9.25–9.48% ([Core ML card](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml)).

  | Preset | Latency | DER | Meetings with the right count | Speed |
  |---|---|---|---|---|
  | `fast128` | 10.56 s | 9.36% | 16 of 16 | 546× real time |
  | `offline` | 30.4 s | 9.47% | 14 of 16 | 904× |
  | `fast32` (FluidAudio's default) | 2.88 s | 9.53% | 15 of 16 | 179× |
  | `low` | 1.04 s | 9.75% | 12 of 16 | 31× |

  - FluidAudio notes that "window size drives speaker counting". Every miscount with these presets was an extra speaker, not a merge ([benchmark data](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/main/BENCHMARKS.md)).
  - Its streaming API lets each word take the speaker slot with the most activity over that word's span ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Nemotron3.md)).
- **No Hebrew data.** Nemotron 3's training data includes multilingual sets, but none is listed as Hebrew ([model card](https://huggingface.co/nvidia/Nemotron-3-Diarization)).

### 3.2 The merged-voices case

- **Sortformer has 4 fixed speaker slots.** FluidAudio warns it "will miss or merge" a fifth speaker ([FluidAudio docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Sortformer.md)). If the local user's voice is in the same stream as the three remote people, that call had four voices, Sortformer's maximum.
- **What should help:**
  - Nemotron 3's 8 slots.
  - Its lower merge rate in Voice Arena's sessions (7.9% vs 22.3%).
  - Its better counting on 3–4-speaker phone calls.
  - The long-window presets (`fast128` or `offline`) for the after-call pass, even if live captions use a shorter window.
- **Keep the pyannote fallback for now, but don't count on it.** Community-1 merged people in 24.5% of Voice Arena's sessions ([Voice Arena](https://voicearena.com/diarization-bench)).
- **An untested idea for a better safety check.** FluidAudio v0.18.0 adds per-speaker embeddings and `embedSpans` ([release](https://github.com/FluidInference/FluidAudio/releases/tag/v0.18.0)). With those, the app could check whether one diarized speaker's segments split into two clearly separate voices. This needs the 0.18.0 upgrade; Nemotron 3 itself doesn't.

### 3.3 Other options

- **pyannote: nothing newer and open.** community-1 (September 2025, CC-BY-4.0) is still the newest open pipeline ([model page](https://huggingface.co/pyannote/speaker-diarization-community-1)). pyannote.audio's 2026 releases, 4.0.4 to 4.0.7, are maintenance and batch-inference changes ([changelog](https://github.com/pyannote/pyannote-audio/blob/main/CHANGELOG.md)). The "precision" pipelines are pyannoteAI's premium models, used with a pyannoteAI API key ([changelog](https://github.com/pyannote/pyannote-audio/blob/main/CHANGELOG.md)). pyannote's own community-1 figures are 19.9% DER on AMI far-field, 26.7% on CALLHOME and 20.2% on DIHARD III ([pyannote benchmark](https://pypi.org/project/pyannote-audio/4.0.0/)).
- **LS-EEND (FluidAudio, MIT Core ML build)** ([model page](https://huggingface.co/FluidInference/ls-eend-coreml)).
  - It handles up to 10 speakers. FluidAudio's README now calls it the default live diarizer ([README](https://github.com/FluidInference/FluidAudio)).
  - It runs on 8 kHz audio. Its published DER is 19.61% on DIHARD III (protocol not stated) and 12.11% on CALLHOME ([LS-EEND docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/LS-EEND.md)), worse than Nemotron 3's 12.73% and 9.10%.
  - FluidAudio says it is "more prone to false alarms" and can fail to enroll speakers whose voices are similar ([diarization guide](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)).
  - Only worth it if meetings regularly exceed 8 speakers.
- **DiariZen v2 (BUT FIT).** Second on Voice Arena, but its weights are CC-BY-NC-4.0, which means non-commercial use only ([model page](https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md-v2)). That likely rules it out on a corporate Mac.

## 4. Mac runtimes

- **whisper.cpp.** v1.9.5 (October 6, 2026) is a maintenance release, and it runs only Whisper-family models ([releases](https://github.com/ggml-org/whisper.cpp/releases)).
- **FluidAudio (Core ML, Neural Engine).** It covers the Parakeet family, Nemotron streaming, a Cohere beta and all the diarizers above. v0.18.0 came out October 28, 2026 ([releases](https://github.com/FluidInference/FluidAudio/releases)).
- **transcribe.cpp.** An MIT-licensed C library on ggml and Metal, much like whisper.cpp, with a single C header and Swift bindings. It runs 16+ transcription model families, including Parakeet, Qwen3-ASR, Granite, Voxtral, Cohere and Whisper, plus Sortformer v2.1 for speakers ([README](https://github.com/handy-computer/transcribe.cpp)). It is young: v0.4.1 came out October 22, 2026 ([releases](https://github.com/handy-computer/transcribe.cpp/releases)).
- **mlx-audio-swift.** An MIT Swift package on MLX for Qwen3-ASR with its aligner, Parakeet, Granite, Cohere, Whisper and Sortformer. It is installed from the `main` branch ([README](https://github.com/Blaizzy/mlx-audio-swift)).
- **sherpa-onnx.** v2.0.1 came out October 26, 2026. It has a Swift API and supports the Hebrew Zipformer, Qwen3-ASR and Omnilingual ([releases](https://github.com/k2-fsa/sherpa-onnx/releases)).
- **Python-only paths** (NeMo, transformers, mlx-audio's Python package) are fine for a bench test on a developer Mac, but not for shipping in an ad-hoc-signed app.

## 5. Test plan

### 5.1 Speakers (first)

1. **Collect test audio.** Take the app's speaker tests, including the call where Sortformer merged two of the three remote people. Add a few Hebrew calls and one meeting with 5+ people. Note the true speaker count for each, and keep reference speaker timelines (RTTM files) where they exist.
2. **Run FluidAudio's command-line tool on each file, with no app changes.** Use `fluidaudiocli nemotron3-diarize file.wav --variant fast128 --output out.rttm`, then repeat with `fast32` (live-like) and `offline` ([CLI docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Nemotron3.md)). Compare each result with today's pipeline output.
3. **Record:**
   - detected vs true speaker count;
   - whether the two merged people now come out separate;
   - DER at collar 0 and 0.25 s, where references exist;
   - speed;
   - Neural Engine load while transcription runs at the same time.
4. **Sanity-check the setup** on a 32 GB laptop with `fluidaudiocli nemotron3-benchmark --variant fast128 --collar 0`. With the same AMI references FluidAudio used, it should land near its published 9.4% DER.
5. **If it holds up, wire it into the app behind a setting.** Use `fast32` or `low` live, and `fast128` or `offline` after the call. Keep today's fallback until the app's speaker tests pass in both Hebrew and English.

### 5.2 Hebrew

1. **Baseline.** Rerun the scripted read with the current turbo file, after confirming it is the 2025.05.13 build (section 1.1). Expect 16.0% WER and 97.3% of Hebrew words right.
2. **Add an English-term score.** List the English tech terms in the script, then count how many come out in Latin letters and spelled correctly. Report it with every run.
3. **Swap in ivrit.ai whisper-large-v3.** Use the GGML file with the large-v3 DTW preset, the same decoding settings, and Hebrew forced. Measure:
   - WER;
   - the share of Hebrew words right;
   - the English-term score;
   - processing time per minute of audio on the M4 Pro and on a 32 GB laptop;
   - peak memory.

   Adopt it for the after-the-call pass only if it clearly beats turbo on the read and on a few real meetings, at an acceptable speed.
4. **Optional, word timing.** Compare DTW word times from turbo and large-v3 against ivrit.ai's human-timed `eval-forced-alignment` clips.
5. **Optional, live captions.** Run the Zipformer through sherpa-onnx streaming on the read and on a recorded call. Measure delay per chunk, CPU use and WER, and expect English terms to break.
6. **Optional, comparable numbers.** ivrit.ai's evaluation script has a whisper.cpp engine ([engines](https://github.com/ivrit-ai/asr-training/tree/master/engines)). Running it on the GGML files would give numbers directly comparable with the leaderboard.

### 5.3 English

1. **Test audio.** Pick 5–10 real English meetings with checked transcripts. AMI test meetings can be added; FluidAudio's tool downloads them.
2. **Compare models.** Run whisper.cpp turbo against `fluidaudiocli transcribe --model-version v2` and `--model-version ultra`, and optionally `bark3`. Score with the same text normalizer. Check that token timings line up at speaker changes at least as well as DTW. Measure speed and memory.
3. **Live transcription.** Compare Nemotron Speech Streaming EN, at 1120 or 2240 ms chunks, with the current chunked turbo helper. Measure delay, CPU and Neural Engine use, and WER.
4. **Keep language detection on stock Whisper,** since Parakeet has none.
5. **Only if Parakeet doesn't win on real meetings:**
   - try Qwen3-ASR-1.7B in 8-bit through mlx-audio-swift, with Qwen3-ForcedAligner for word times;
   - or try Granite Speech 5.0 2B through llama.cpp with a list of the company's tech terms.

## 6. Inconsistencies and gaps

- **Parakeet Hebrew fine-tune numbers differ by source:** card 6.1 / 8.8, leaderboard pull request 5.7 / 9.0, GGML card 5.30 / 8.44 (eval-d1 / WhatsApp). The runs used different setups, and the pull request is still unmerged.
- **The Zipformer's numbers differ by build:** card 5.1 / 8.9 for the PyTorch model, 5.3 / 8.8 for the int8 build on the leaderboard.
- **Third-party runs of ivrit.ai turbo differ from the leaderboard.** The EmbeddingGemma 2 model card measured it at 4.87 / 7.56 / 20.51 on eval-d1 / WhatsApp / FLEURS, against the leaderboard's 5.3 / 7.1 / 18.1, so comparisons across sources are rough.
- **The leaderboard description lists a Common Voice set,** but the data file has no Common Voice column.
- **Open ASR Leaderboard access.** The results file needs a login, so I read the numbers from the public app. The average includes two private sets, and the set list changed during 2026 (see Cohere's two figures).
- **FluidAudio's docs lag the code:**
  - Nemotron3.md says the Core ML files are gated, but they are public.
  - The Core ML card says v0.17.3+ loads the M3-fixed files, while the release notes put that change in v0.17.4.
  - The diarization guide's model-choice table and the README's diarization section don't mention Nemotron 3 yet.
  - The docs link to `FluidInference/lseend-coreml`, which returns 401; the public repository is `FluidInference/ls-eend-coreml`.
- **FluidAudio withdrew some measurements.** Its Nemotron 3 figures for AliMeeting, NOTSOFAR1, VoxConverse and DIHARD came from a preview checkpoint and were taken down pending re-runs ([benchmark data](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/blob/main/BENCHMARKS.md)).
- **Protocols differ across diarization numbers.** pyannote's community-1 figures, FluidAudio's own AMI runs, LS-EEND's figures and NVIDIA's tables use different references and collars, so compare only within a source.
- **Omnilingual's Hebrew figure** is a character error rate for the original 7B model, not v2, on Meta's test data.
- **FluidAudio's speed claims vary:** its README says about 190× real time on an M4 Pro, its ASR guide about 120×, and its benchmark page 146× for v2.
- **No Hebrew evaluation exists for any diarizer here.**

**Things to watch:**
- ivrit.ai merging the Parakeet submission, or adding VibeVoice-ASR or Omnilingual rows.
- FluidAudio re-publishing Nemotron 3 results on DIHARD and VoxConverse, and updating its diarization guide.
- Voice Arena's final version 1 results.
- The Nemotron 3.5 Transcribe Mac runtime ([nemotron-transcribe.md](nemotron-transcribe.md)).

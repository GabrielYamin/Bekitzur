# Newer open-weight models for Bekitzur's Notes

Checked on October 29, 2026. Sources are the publishers' model cards and reports, the leaderboards' own data, and llama.cpp's repository. Figures marked *estimate* are my arithmetic from published configurations and measurements; nothing here was run.

## Verdict for Bekitzur

No newer model is a clear win on paper. One cheap change and four bake-offs are worth doing, in this order:

0. **First, give the current model a longer context.** The 32K limit is Bekitzur's setting, not Gemma's: [`LanguageModel`](../../Sources/BekitzurNotes/LanguageModel.swift) defaults to 32,768 tokens and refuses longer prompts. Gemma 4 26B-A4B supports 256K ([model card](https://ai.google.dev/gemma/docs/core/model_card_4)). Google reports 97.3% on RULER at 32K and 89.8% at 128K, and puts its whole 32K cache at 0.28 GB in 8-bit ([technical report, Tables 3 and 9](https://arxiv.org/html/2607.02770)). If Notes on a long real meeting hold up at 64K–128K, long meetings stop failing with no new model.
1. **Gemma 4 31B** (17.65 GB at 4-bit). The best evidence of better Hebrew among models that fit. It beats 26B-A4B on all five tasks of [Dicta's Hebrew chat leaderboard](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results), including summaries (48.5 vs 46.0) and translation (33.3 vs 27.3), and ranks second of six on [AlephBench](https://huggingface.co/datasets/HebArabNlpProject/AlephBench), behind only Gemini 2.5 Flash. It is clearly better at long context (RULER at 128K: 96.4 vs 89.8, [report, Table 9](https://arxiv.org/html/2607.02770)). It uses the same chat format, so trying it is a file swap. The cost is speed: it is dense, so expect reading and writing to be several times slower.
2. **DictaLM 3.0 24B Thinking** (14.3 GB). The highest Hebrew summary score of any model on [Dicta's leaderboard](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results) that fits a 48 GB Mac (56.9). But it [always thinks before answering](https://huggingface.co/dicta-il/DictaLM-3.0-24B-Thinking), the mode that looped in Gemma; it stops at 65K tokens; and its cache costs about 5.4 GB per 32K tokens.
3. **Qwen3.6-35B-A3B** (20.4 GB). The leanest at long context and likely the fastest: [3B active parameters, 262K tokens](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), about 0.7 GB of cache per 32K tokens. But there is no Hebrew result for it, [earlier small Qwen models](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results) scored very low on Dicta's Hebrew tasks, and at 4-bit it won't fit a 32 GB laptop.
4. **Muse Glimmer 30B** (16.8 GB). Meta's new local model has the [best long-context scores](https://huggingface.co/meta-models/Muse-Glimmer-30B) in Meta's comparison with Gemma 4 31B and Qwen3.6-27B, and a tiny cache. But its [reasoning can't be switched off, and Meta says greedy decoding makes it repetitive](https://dev.meta.ai/docs/muse-glimmer/deploy); it is dense, and there is no Hebrew result.

Not worth a bake-off now: NVIDIA Nemotron 3.5 Lightning ([Hebrew isn't a supported language](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16), and [its predecessor](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results) is near the bottom of Dicta's leaderboard), gpt-oss-20b, GLM-4.7-Flash, Jamba2 Mini, Hebatron, DictaLM's 12B model, Qwen3.8-27B (unless Qwen3.6 surprises in Hebrew), and the 2026 Mistral, Meta and Qwen flagships, which don't fit in 37 GB. Section 6 gives the reasons and sources.

Keep in mind:

- The current model already finds every required item in the five synthetic Conversations ([plan](../plan.md#llm-bake-off-results)). A new model can only gain on Owners, due dates and length, so the long cases and a real meeting should decide.
- No published benchmark measures Hebrew meeting notes or Hebrew–English code-switching. All Hebrew evidence below comes from general Hebrew tasks.
- Only the current model and Muse Glimmer are likely to fit a 32 GB laptop at long context (estimates in section 8).

## Candidates, ranked

Hebrew scores are from [Dicta's Hebrew chat leaderboard](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results) (summaries, then translation) and [AlephBench](https://huggingface.co/datasets/HebArabNlpProject/AlephBench); section 7 explains both. "Fits" means at a 128K context, or the model's maximum if lower, using the estimates in section 8.

| Rank | Model, release | Architecture (total / active) | Context | 4-bit file | Fits 48 GB Mac / 32 GB laptop | llama.cpp | License | Hebrew evidence |
|---|---|---|---|---|---|---|---|---|
| Now | [Gemma 4 26B-A4B](https://ai.google.dev/gemma/docs/core/model_card_4), Mar 31, 2026 | MoE, 25.2B / 3.8B | 256K | [14.4 GB, Google](https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf) | Yes / yes | [`gemma4`](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp), in use | Apache 2.0 | 46.0, 27.3 |
| 1 | [Gemma 4 31B](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf), Mar 31, 2026 | Dense, 30.7B | 256K | [17.65 GB, Google](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf) | Yes / short context only | [`gemma4`](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp), same prompt | Apache 2.0 | 48.5, 33.3; AlephBench 2nd of 6 |
| 2 | [DictaLM 3.0 24B Thinking](https://huggingface.co/dicta-il/DictaLM-3.0-24B-Thinking), Dec 2025 | Dense, 24B | 65K | [14.3 GB, Dicta](https://huggingface.co/dicta-il/DictaLM-3.0-24B-Thinking-GGUF) | Yes / short context only | Standard Mistral | Apache 2.0 | 56.9, 30.1; AlephBench 3rd of 6 |
| 3 | [Qwen3.6-35B-A3B](https://huggingface.co/Qwen/Qwen3.6-35B-A3B), Apr 2026 | MoE, 35B / 3B | 262K | [20.4 GB, ggml-org](https://huggingface.co/ggml-org/Qwen3.6-35B-A3B-GGUF) | Yes / no | [`qwen35moe`](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp) | Apache 2.0 | None for this model |
| 4 | [Muse Glimmer 30B](https://huggingface.co/meta-models/Muse-Glimmer-30B), Aug 10, 2026 | Dense, 29.6B | 131K+ | [16.8 GB, Meta](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF) | Yes / yes | [`muse-glimmer`](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp) | Apache 2.0 | None |

Checked and not recommended now (details in section 6):

| Model, release | Size | Why not now |
|---|---|---|
| Qwen3.8-27B, Aug 2026 | Dense 27B, 19.0 GB | Dense, so slow; no Hebrew result |
| Nemotron 3.5 Lightning 30B-A3B, Aug 11, 2026 | Hybrid MoE, 18.9 GB | Hebrew not supported; Nemotron 3 Nano scored 20.5 and 7.0 on Dicta's board |
| gpt-oss-20b, Aug 5, 2025 | MoE 21B / 3.6B, 12.1 GB | No Hebrew result; its 120B sibling scored 34.8 and 10.8 |
| GLM-4.7-Flash, Jan 19, 2026 | MoE 31B / 3B | Card lists English and Chinese only |
| Jamba2 Mini, Jan 8, 2026 | MoE 52B / 12B | Supports Hebrew, but about 30 GB at 4-bit; Jamba Mini 1.7 scored 24.9 and 2.8 |
| Hebatron, May 2026 | Hybrid MoE 31.6B / 3B | AlephBench 77.1, below Gemma 3 27B |
| DictaLM 3.0 Nemotron 12B, Dec 2025 | Hybrid 12B | 33.3 and 13.5, below the current model |
| Ministral 3 14B; Gemma 4 12B Unified | 14B; 12B | Smaller; no Hebrew listed or tested |
| Mistral Small 4, Mistral Medium 3.5, Muse Spark Open, Qwen3.8-Flash-Next | 119B to 816B | Too big for 37 GB |

## 1. The current model at a longer context

- **What it supports.** Gemma 4 26B-A4B has 30 layers, a 1,024-token sliding window and a 256K context ([model card](https://ai.google.dev/gemma/docs/core/model_card_4)). Five of every six layers are sliding-window layers, and the global layers reuse keys as values; with its other changes, Google says this cuts the global cache by up to 37.5% ([report, section 2](https://arxiv.org/html/2607.02770)).
- **Memory.** Google gives 16.2 GB at Q4_0 plus 0.28 GB for an 8-bit cache at 32K ([report, Table 3](https://arxiv.org/html/2607.02770)). Bekitzur measured about 1.5 GB beyond the model file at 32K once the sliding-window cache held only the window ([plan](../plan.md)). At 128K I estimate about 18 GB in total (section 8), within both Macs.
- **Long-context quality, without thinking.** RULER 97.3% at 32K and 89.8% at 128K, and LOFT retrieval at 128K 66.3 ([report, Table 9](https://arxiv.org/html/2607.02770)). The 31B is better on both (section 2).
- **Speed on an M4 Pro.** Bekitzur measured reading at 640–930 tokens per second and writing at about 66 ([plan](../plan.md#llm-bake-off-results)). An independent paper measured llama.cpp on a 16-core-GPU M4 Pro at 58.0 tokens per second writing and 558 reading at 2,048 tokens ([BaseRT paper, Tables 1 and 2](https://arxiv.org/html/2607.00501v1)).
- **A faster option.** Google released multi-token-prediction drafters for Gemma 4 on April 16, 2026 ([release notes](https://ai.google.dev/gemma/docs/releases)), and llama.cpp runs them since June 7, 2026 ([commit](https://github.com/ggml-org/llama.cpp/commit/d1e70aaf024d469aa3a2f443880335fb565d5e19)). A quantization-aware target needs a quantization-aware drafter ([QAT card](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf)). Bekitzur's engine runs its own greedy loop, so using a drafter would need engine work.

## 2. Gemma 4 31B

- **Release and license.** March 31, 2026 ([release notes](https://ai.google.dev/gemma/docs/releases)), Apache 2.0 ([Google blog](https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/)).
- **Architecture.** Dense, 30.7B parameters, 60 layers, the same 1,024-token sliding window and the same 256K context ([QAT card](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf)).
- **Files.** Google's quantization-aware Q4_0 GGUF is 17.65 GB, plus a 1.2 GB vision file Bekitzur doesn't need ([file list](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf)). Google's report gives 19.2 GB and 1.10 GB for an 8-bit cache at 32K ([report, Table 3](https://arxiv.org/html/2607.02770)).
- **Drop-in.** Same llama.cpp architecture, `gemma4` ([llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp)), and the same chat format and thinking switch: with thinking off, the model writes an empty thought block ([QAT card](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf)). The engine's `gemma4Prompt` should work unchanged ([`LanguageModel`](../../Sources/BekitzurNotes/LanguageModel.swift)).
- **Hebrew.** On Dicta's leaderboard it scores 48.5 on summaries, 33.3 on translation, 58.5 on trivia, 86.0 on Winograd and 73.4 on nikud, against 46.0, 27.3, 44.5, 78.1 and 68.1 for 26B-A4B ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results)). On AlephBench it scores 88.1, second of six after Gemini 2.5 Flash's 88.8 ([AlephBench](https://huggingface.co/datasets/HebArabNlpProject/AlephBench)).
- **Other evidence.** IFBench 76.0 vs 72.0, MMMLU 88.4 vs 86.3, RULER at 128K 96.4 vs 89.8, LOFT retrieval at 128K 79.5 vs 66.3, and MRCR v2 8-needle at 128K 66.4 vs 44.1 ([report, Tables 5 and 9](https://arxiv.org/html/2607.02770)).
- **Speed.** I found no published Apple Silicon numbers. It uses about 8 times more parameters per token than 26B-A4B (30.7B vs 3.8B active), so expect several times slower reading and writing (section 8). A drafter is published for it, as for 26B-A4B.
- **Memory.** About 21 GB at 32K and 27 GB at 128K, or 23 GB with an 8-bit cache (*estimate*). It fits the 48 GB Mac at 128K; a 32 GB laptop only at about 32K, so one option is the 31B on 48 GB Macs and 26B-A4B on laptops.

## 3. DictaLM 3.0 24B Thinking

- **Release and license.** Published on Hugging Face on December 1, 2025 ([Hugging Face](https://huggingface.co/dicta-il), [collection](https://huggingface.co/collections/dicta-il/dictalm-30-collection)), with a technical report in February 2026 ([arXiv](https://arxiv.org/abs/2602.02104)). Apache 2.0 ([Dicta](https://dicta.org.il/dicta-lm-3)). Dicta has published no newer chat model since ([Hugging Face listing](https://huggingface.co/dicta-il)).
- **How it was built.** Mistral-Small-3.1-24B-Base, continued on about 130B tokens, 75% of them Hebrew, with a 65K context ([report, sections 2–3](https://arxiv.org/html/2602.02104)).
- **Architecture and memory.** Dense, 40 layers, 8 key-value heads of size 128, no sliding window, at most 65,280 positions ([config](https://huggingface.co/dicta-il/DictaLM-3.0-24B-Thinking/blob/main/config.json)). Every layer keeps a cache: about 160 KB per token, so 5.4 GB at 32K and 10.7 GB at 65K (*estimate*).
- **Always thinks.** The card says it "first thinks out the right way to respond in a designated thinking block" before every reply ([model card](https://huggingface.co/dicta-il/DictaLM-3.0-24B-Thinking)). Dicta released no 24B instruct model. In Dicta's own comparison, its unreleased instruct variant scored far lower, for example 31.1 vs 74.1 on AlpacaEval and 60.8 vs 86.4 on MATH ([report, Table 11](https://arxiv.org/html/2602.02104)), so skipping the thinking may cost quality. Its reasoning tags follow DeepSeek-R1's convention ([report, section 5.1.1](https://arxiv.org/html/2602.02104)).
- **Files and runtime.** Dicta publishes its own GGUFs: Q4_K_M is 14.33 GB and IQ4_XS 12.76 GB ([file list](https://huggingface.co/dicta-il/DictaLM-3.0-24B-Thinking-GGUF)). The architecture is standard Mistral, which llama.cpp runs.
- **Hebrew.** On Dicta's leaderboard: 56.9 on summaries, 30.1 on translation, 60.1 on trivia, 78.1 on Winograd and 86.9 on nikud ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results)). Its summary score is third overall, behind GPT-5.1 (66.0) and GLM-5.3-Flash (60.5), and above Gemini 2.5 Pro (49.1). On AlephBench it scores 85.2, third of six, below Gemma 4 31B ([AlephBench](https://huggingface.co/datasets/HebArabNlpProject/AlephBench)). Dicta runs the leaderboard and made the model.
- **English.** IFEval 88.2 and MMLU 85.9 ([report, Table 9](https://arxiv.org/html/2602.02104)).
- **Speed.** None published. Dense 24B, so slower than now, though faster than the 31B (*estimate*).

## 4. Qwen3.6-35B-A3B

- **Release and license.** Mid-April 2026: Qwen's card cites April 2026 ([model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)) and Alibaba Cloud's announcement is dated April 17 ([Alibaba Cloud](https://www.alibabacloud.com/blog/603042)). Apache 2.0 ([model page](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)).
- **Architecture.** 35B parameters with 3B active, and 40 layers: ten blocks of three Gated DeltaNet (linear-attention) layers and one gated-attention layer. Attention has 2 key-value heads of size 256. It has 256 experts, 8 routed plus 1 shared, a 262,144-token native context (1,010,000 with YaRN), and a vision encoder ([model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)). Only the 10 attention layers keep a growing cache: about 20 KB per token, or 0.7 GB at 32K and 2.7 GB at 128K (*estimate*).
- **Thinking and sampling.** Thinking is on by default and can be switched off with `enable_thinking: false`. For non-thinking use Qwen recommends temperature 0.7, top-p 0.8, top-k 20 and a presence penalty of 1.5, and suggests the penalty "to reduce endless repetitions" ([model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)). Bekitzur decodes greedily, so test both.
- **Files.** Qwen publishes no GGUF. llama.cpp's own organization publishes Q4_K_M at 20.42 GB, plus a 1.06 GB multi-token-prediction drafter and a small DFlash drafter ([file list](https://huggingface.co/ggml-org/Qwen3.6-35B-A3B-GGUF)).
- **llama.cpp on Metal.** The architecture is `qwen35moe` ([llama.cpp](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp)). A Metal kernel for the Gated DeltaNet step was merged on March 11, 2026 ([PR #20361](https://github.com/ggml-org/llama.cpp/pull/20361)). It covers the head sizes Qwen3.5 uses; other sizes fall back to the CPU ([PR #20244](https://github.com/ggml-org/llama.cpp/pull/20244)). llama.cpp's operation table marks the operation "partially supported" on Metal, consistent with those limits ([ops table](https://github.com/ggml-org/llama.cpp/blob/master/docs/ops.md)).
- **Published speed.** A maintainer's benchmark for this architecture at Q4_0, hardware not stated: 2,462 tokens per second reading at 2,048 tokens and 77.7 writing ([PR #20361](https://github.com/ggml-org/llama.cpp/pull/20361)).
- **Other evidence.** In Qwen's own table it beats Gemma 4 26B-A4B on MMLU-Pro (85.2 vs 82.6) and GPQA (86.0 vs 82.3) ([model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B)), but none of its listed tests is about Hebrew or summaries. Its predecessor with the same architecture, Qwen3.5-35B-A3B, scores 85.2 on MMMLU, 70.2 on IFBench, 58.5 on AA-LCR and 59.0 on LongBench v2 ([model card](https://huggingface.co/Qwen/Qwen3.5-35B-A3B)).
- **Hebrew.** Qwen says Qwen3.5 covers 201 languages ([model card](https://huggingface.co/Qwen/Qwen3.5-35B-A3B)) but publishes no list. Neither Hebrew leaderboard includes Qwen3.6. The family's results are mixed. Qwen3.5-122B-A10B, about four times larger, ties 26B-A4B on Dicta's summaries (46.2 vs 46.0) and beats it on translation (31.0) and trivia (70.1). Qwen3-30B-A3B-Thinking-2507 scored 12.4 on summaries and 1.0 on translation ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results)), and Qwen3-14B with thinking scored 15.8 and 0.9 ([DictaLM report, Table 8](https://arxiv.org/html/2602.02104)).
- **Memory.** About 22 GB at 32K and 24 GB at 128K (*estimate*): fine on the 48 GB Mac, too big for a 32 GB laptop at 4-bit.

## 5. Muse Glimmer 30B

- **Release and license.** August 10, 2026, under Apache 2.0 ([Meta](https://research.meta.ai/blog/introducing-muse-glimmer-open-agentic-model)). It is "intended for commercial and research use" ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)).
- **Architecture.** Dense, 29.6B parameters including a 1.8B vision encoder, and 52 layers in a repeating pattern of three local layers and one global layer. The sliding window is 2,048 tokens, there are 2 key-value heads of size 128, the context is "131,072+", and the knowledge cutoff is January 4, 2026 ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)). Only the 13 global layers keep a growing cache: about 13 KB per token, so 1.7 GB at 128K (*estimate*).
- **Files.** Meta publishes two 4-bit GGUFs: 16.76 GB, with 1.0% average degradation and aimed at 24 GB devices, and 19.65 GB, with 0.2% and aimed at 32 GB. A 1.63 GB DFlash drafter is also published ([file list](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF), [model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)). llama.cpp supported it, drafter included, on release day ([Hugging Face blog](https://huggingface.co/blog/muse-glimmer)).
- **Long context and instructions.** In Meta's table, where the other models ran in thinking mode, it scores 80.0 on AA-LCR, against 68.3 for Gemma 4 31B and 73.3 for Qwen3.6-27B. It scores 65.1 on Beam at 128K (58.2 and 63.0), and 77.0 on IFBench (76.0 and 70.8) ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)).
- **Reasoning can't be turned off.** "The template opens the thinking channel unconditionally." Strengths run from low to xhigh (default high), and reasoning tokens count against the output limit. Meta's troubleshooting table lists "Flat, repetitive answers" with the cause "Running greedy" ([Meta docs](https://dev.meta.ai/docs/muse-glimmer/deploy)). Both conflict with Bekitzur's greedy, grammar-constrained decoding.
- **Hebrew.** "Trained on data from more than 100 languages", and it "has not been evaluated on all languages" ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)). It is on neither Hebrew leaderboard.
- **Speed.** Meta measured 23.7 tokens per second on an M4 Max without speculation and 37.8 with DFlash, and 26.6 and 50.2 on an M5 Max, using ExecuTorch rather than llama.cpp ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)). An M4 Pro has 273 GB/s of memory bandwidth against 410 or 546 GB/s for an M4 Max ([Apple](https://support.apple.com/en-us/121553)), and Meta doesn't say which M4 Max it used. Expect roughly 12–16 tokens per second without speculation (*estimate*).
- **Memory.** About 18 GB at 32K and 20 GB at 128K, plus 1.6 GB with the drafter (*estimate*).

## 6. Checked and not recommended now

- **Qwen3.8-27B (August 2026).** Dense 27B, 64 layers, three Gated DeltaNet layers per attention layer, 262K context, Apache 2.0, IFBench 79.5 ([model card](https://huggingface.co/Qwen/Qwen3.8-27B)). llama.cpp's organization publishes an 18.97 GB Q4_K_M ([file list](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)). In llama.cpp's benchmark, this dense architecture read 407 tokens per second against 2,462 for the 35B-A3B on the same machine, at Q8_0 and Q4_0 respectively ([PR #20361](https://github.com/ggml-org/llama.cpp/pull/20361)). No Hebrew result. Try it only if Qwen3.6 does well in Hebrew but falls short on quality.
- **NVIDIA Nemotron 3.5 Lightning 30B-A3B (August 11, 2026).** This is the language model inside Nemotron 3.5 Transcribe ([earlier note](nemotron-transcribe.md)). It is a hybrid of Mamba-2, mixture-of-experts and attention layers, with up to 1M tokens of context, under OpenMDW-1.1, and it allows commercial use. Supported languages are English, Spanish, French, German, Italian and Japanese ([model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16)). Only 6 of its 52 layers are attention layers, with 2 key-value heads each ([config](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16/blob/main/config.json)), so its cache is tiny. NVIDIA's card links official GGUFs from llama.cpp's organization ([NVFP4 card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4)); the Q4_0 file is 18.90 GB ([file list](https://huggingface.co/ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF)). Its pre-training web data in other languages lists 15 languages, Arabic but not Hebrew, and it scores 52.0 on AA-LCR ([NVFP4 card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-NVFP4)). Its predecessor, Nemotron 3 Nano, scored 20.5 on Dicta's summaries, 7.0 on translation and 5.4 on nikud ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results)).
- **gpt-oss-20b (August 5, 2025).** MoE with 20.9B parameters and 3.6B active, 128K context, Apache 2.0 plus a usage policy. It is a reasoning model with low, medium and high effort ([OpenAI](https://openai.com/index/introducing-gpt-oss/)), and its MXFP4 GGUF is 12.11 GB ([file list](https://huggingface.co/ggml-org/gpt-oss-20b-GGUF)). OpenAI's multilingual test covers 14 languages, not Hebrew ([model card, Table 2](https://deploymentsafety.openai.com/gpt-oss/introduction)). gpt-oss-120b scored 34.8 on Dicta's summaries and 10.8 on translation ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results)). OpenAI has released no newer open-weight chat model ([OpenAI](https://openai.com/open-models/)).
- **GLM-4.7-Flash (January 19, 2026).** MoE, 31B parameters with 3B active, MIT license; its card lists English and Chinese ([Hugging Face](https://huggingface.co/api/models/zai-org/GLM-4.7-Flash), [Z.ai](https://www.zhipuai.cn/en/news/148)). The newer GLM-5.3-Flash is 320B with 18B active ([Z.ai](https://docs.z.ai/release-notes/new-released)).
- **AI21 Jamba2 (January 8, 2026).** It comes in a dense 3B and Mini, an MoE with 52B parameters and 12B active, both with a 256K context and Apache 2.0 ([AI21](https://www.ai21.com/blog/introducing-jamba2/)). Hebrew is one of nine officially supported languages ([AI21 docs](https://docs.ai21.com/docs/jamba-foundation-models)). Mini would take about 30 GB at 4-bit (*estimate*), only community GGUFs exist ([Hugging Face search](https://huggingface.co/models?search=Jamba2-Mini)), and Jamba Mini 1.7 scored 24.9 on Dicta's summaries and 2.8 on translation ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results)).
- **Hebatron (May 2026).** A Hebrew fine-tune of Nemotron 3 Nano 30B-A3B by PwC Israel, MAFAT and AWS, with a 64K context ([model card](https://huggingface.co/HebArabNlpProject/Hebatron)). It is Apache 2.0 and thinks by default, and its template always prepends a fixed Hebrew identity prompt ([Hugging Face](https://huggingface.co/api/models/HebArabNlpProject/Hebatron)). It scores 77.1 on AlephBench, below Gemma 3 27B's 83.5 ([AlephBench](https://huggingface.co/datasets/HebArabNlpProject/AlephBench)).
- **DictaLM 3.0 Nemotron 12B Instruct (December 2025).** A hybrid with Mamba layers, so its cache is small. But it scores 33.3 on summaries and 13.5 on translation ([DictaLM report, Table 8](https://arxiv.org/html/2602.02104)), below the current model.
- **Mistral.** Mistral Small 4 is 119B with 6.5B active ([Mistral](https://mistral.ai/news/mistral-small-4/)), Mistral Medium 3.5 is a dense 128B ([model card](https://huggingface.co/mistralai/Mistral-Medium-3.5-128B)), and Mistral Large 4's weights are "coming soon" ([changelog](https://docs.mistral.ai/resources/changelogs)). None fits. Ministral 3 14B doesn't list Hebrew ([model card](https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512)). DictaLM 3.0 24B is Mistral's family adapted to Hebrew.
- **Meta and Llama.** Meta's newest Llama models on Hugging Face date from April 2025 ([Hugging Face](https://huggingface.co/meta-llama)). Muse Spark Open has 816B parameters with 42B active and a license with limited commercial terms ([Meta](https://research.meta.ai/blog/muse-spark-open)).
- **Other Qwen.** Qwen3.8-Flash-Next has 125B parameters plus 51B n-gram embeddings, with 6B active ([Qwen](https://www.linkedin.com/posts/qwen_meet-qwen38-flash-a-multimodal-moe-and-activity-7498356251966431232-JcQq)), under a custom license ([Hugging Face](https://huggingface.co/api/models?author=Qwen&search=Qwen3.8)). Qwen's Hugging Face organization has no Qwen3.7 or Qwen4 weights ([Hugging Face](https://huggingface.co/Qwen)).
- **Gemma 4 12B Unified (June 3, 2026).** Dense, 7.65 GB at Q4_0, and 91.2% on RULER at 128K, but weaker than 26B-A4B on most of Google's other benchmarks, for example MMLU Pro 77.2 vs 82.6 and MMMLU 83.4 vs 86.3 ([report, Tables 3, 5 and 9](https://arxiv.org/html/2607.02770)). Hebrew is untested. It could be a fallback for small laptops.

## 7. Hebrew evidence

**Dicta's Hebrew chat leaderboard** ([data](https://huggingface.co/datasets/hebrew-llm-leaderboard/chat-results), last updated August 31, 2026, 34 models) uses the five tasks from Dicta's report ([report, section 6.1](https://arxiv.org/html/2602.02104)):

- **Summaries.** 1,000 documents. Each summary is compared with Gemini 2.5 Pro's by GPT-4o; the score is the win rate, with ties counting half.
- **Translation.** English paragraphs translated into Hebrew, scored the same way.
- **Trivia.** 300 multiple-choice questions about Israel.
- **Winograd.** A Hebrew translation of the Winograd Schema Challenge.
- **Nikud.** Adding vowel marks, scored against expert-marked sentences.

The score files don't record how each model was run (thinking or not, precision), and Dicta both runs the board and makes DictaLM.

| Model | Summaries | Translation | Trivia | Winograd | Nikud |
|---|---|---|---|---|---|
| Gemini 2.5 Pro (reference) | 49.1 | 50.5 | 82.1 | 90.6 | 87.2 |
| DictaLM 3.0 24B Thinking | 56.9 | 30.1 | 60.1 | 78.1 | 86.9 |
| Gemma 4 31B | 48.5 | 33.3 | 58.5 | 86.0 | 73.4 |
| Gemma 4 26B-A4B (current) | 46.0 | 27.3 | 44.5 | 78.1 | 68.1 |
| Qwen3.5-122B-A10B | 46.2 | 31.0 | 70.1 | 93.2 | 67.1 |
| gpt-oss-120b | 34.8 | 10.8 | 74.8 | 71.9 | 49.5 |
| Nemotron 3 Super 120B-A12B | 52.8 | 18.4 | 67.1 | 74.8 | 20.0 |
| Nemotron 3 Nano 30B-A3B | 20.5 | 7.0 | 52.7 | 70.9 | 5.4 |
| Qwen3-30B-A3B-Thinking-2507 | 12.4 | 1.0 | 43.5 | 77.0 | 15.8 |
| Jamba Mini 1.7 | 24.9 | 2.8 | 46.5 | 67.3 | 12.6 |

**AlephBench** ([dataset](https://huggingface.co/datasets/HebArabNlpProject/AlephBench)) has 11 tasks: knowledge, reasoning, Hebrew question answering, inference, sentiment, Israeli trivia and English-to-Hebrew translation. All were run at temperature 0. Its only snapshot, from May 11, 2026, has six models: Gemini 2.5 Flash 88.8, Gemma 4 31B 88.1, DictaLM 3.0 24B 85.2, gpt-oss-120b 84.2, Gemma 3 27B 83.5 and Hebatron 77.1. Gemma 4 26B-A4B isn't in it.

Neither board tests conversations, meeting notes, or Hebrew mixed with English. The bake-off's mixed-language and speech-error cases are the only direct evidence.

## 8. Memory and speed on Apple Silicon

**Memory.** The cache rows are *estimates*: layers that keep a cache × key-value heads × head size × 2 (keys and values) × 2 bytes, from each config cited above. Gemma's figures are Google's 8-bit numbers doubled. Totals add about 1 GB of working buffers, in line with the 1.5 GB Bekitzur measured for the current model at 32K ([plan](../plan.md)).

| Model | 4-bit file | Cache per 32K tokens | Total at 32K | Total at 128K |
|---|---|---|---|---|
| Gemma 4 26B-A4B | 14.4 GB | 0.6 GB | 16 GB | 18 GB |
| Gemma 4 31B | 17.65 GB | 2.2 GB | 21 GB | 27 GB (23 GB with an 8-bit cache) |
| DictaLM 3.0 24B | 14.3 GB | 5.4 GB | 21 GB | Not supported (26 GB at 65K) |
| Qwen3.6-35B-A3B | 20.4 GB | 0.7 GB | 22 GB | 24 GB |
| Muse Glimmer 30B | 16.8 GB | 0.4 GB | 18 GB | 20 GB (21 GB with the drafter) |
| Qwen3.8-27B | 19.0 GB | 2.1 GB | 22 GB | 29 GB |
| Nemotron 3.5 Lightning | 18.9 GB | 0.2 GB | 20 GB | 21 GB |

Everything fits under the 48 GB Mac's 37 GB. I couldn't confirm the default GPU limit on a 32 GB laptop. If it is the same share as on the 48 GB Mac (37 of 48 GB), a 32 GB laptop gets about 24 GB; it may be less. Raising it with `sysctl iogpu.wired_limit_mb` needs admin rights, which these Macs don't have. The plan's own target is peak memory under 22 GB for an hour of audio ([plan](../plan.md)).

**Published speeds:**

- **Gemma 4 26B-A4B on an M4 Pro.** Bekitzur measured reading at 640–930 tokens per second and writing at about 66 ([plan](../plan.md#llm-bake-off-results)). llama.cpp on a 16-core-GPU M4 Pro: 58.0 writing and 558 reading at 2,048 tokens; Qwen3-30B-A3B 80.7 and 601 ([BaseRT paper](https://arxiv.org/html/2607.00501v1)).
- **Qwen's architecture in llama.cpp, hardware not stated.** 35B-A3B at Q4_0: 2,462 reading and 77.7 writing. Dense 27B at Q8_0: 407 and 20.4 ([PR #20361](https://github.com/ggml-org/llama.cpp/pull/20361)). On the same machine, the dense model read 6 times slower.
- **Muse Glimmer, with ExecuTorch.** 23.7 on an M4 Max (37.8 with DFlash), and 26.6 on an M5 Max (50.2) ([model card](https://huggingface.co/meta-models/Muse-Glimmer-30B)).
- **No primary Apple Silicon numbers** for Gemma 4 31B, DictaLM, Qwen3.6 or Nemotron 3.5 Lightning.

**What that means for a dense model (*estimate*).** Writing is limited by memory bandwidth: 273 GB/s on the M4 Pro ([Apple](https://support.apple.com/en-us/121553)) over a 17–19 GB file gives at most about 15 tokens per second, and Meta's M4 Max figure scales to 12–16. For reading, take today's 640–930 tokens per second and divide by the 6× gap in llama.cpp's benchmark, or by the 8× gap in parameters per token between Gemma 4 31B and 26B-A4B: a dense ~30B should read roughly 80–150 tokens per second. An hour of dense Hebrew (35,000 tokens) would then take roughly 4–7 minutes to read and 1–2 minutes to write. The plan's target is 3 minutes ([plan](../plan.md)). The MoE candidates, Qwen3.6 and Nemotron, should be at least as fast as now.

## 9. Test plan

Use the existing harness, [spikes/llm-bakeoff/bakeoff.py](../../spikes/llm-bakeoff/bakeoff.py), and the plan's targets ([plan](../plan.md)):

- every required item found, no traps, valid JSON;
- for an hour of audio, Notes within 3 minutes on the M4 Pro, with peak memory under 22 GB.

**Step 1: control.** The CLI's `notes` command already takes `--model` and `--json` and reads the bake-off's turn files with their headers, but it has no context option ([`NotesCommand`](../../Sources/bekitzur/NotesCommand.swift)). Add one that passes `contextSize` to `LanguageModel`, then run Gemma 4 26B-A4B at 65,536 and at 131,072 tokens on each case, for example `bekitzur notes spikes/llm-bakeoff/transcripts/t1-hebrew-team-sync.txt --json <dir>/t1-hebrew-team-sync.notes.json` (t4 and t5 are in `transcripts/generated/`). Score the folder with `python3 bakeoff.py score-notes <dir>` and record peak memory. The five cases fit in 32K, so their Notes should match the 32K run; any difference points to a context-handling problem, not quality.

**Step 2: long cases with answer keys.** `long_variant(t1, blocks_per_gap=35)` builds t5, which was 16,296 prompt tokens in the latest run ([score file](../../spikes/llm-bakeoff/results/gemma4_26b-a4b-it-qat-v2/t5-hebrew-team-sync-long.score.json)). t1 alone was 2,890 tokens, so each block per gap adds about 380 tokens. Add two variants with their own names to `build_cases`: about 160 blocks per gap for roughly 64K tokens, and about 300 for roughly 118K, which leaves room for the reply in a 131,072-token context. Check the real token counts in the run output. The filler is repetitive, so these cases test finding items across distance, not comprehension.

**Step 3: screen the candidates on all seven cases.** Keep the baseline's settings: prompt v2 (as in `results/gemma4_26b-a4b-it-qat-v2`), seed 42, temperature 0, and `--num-ctx 131072` (65,536 for DictaLM).

- **Gemma 4 31B:** through the engine with no code change beyond step 1's context option, `bekitzur notes <case>.txt --model gemma-4-31B_q4_0-it.gguf --json <dir>/<case>.notes.json`, for a result that matches production.
- **The others need their own chat format.** The engine hard-codes Gemma's ([`LanguageModel`](../../Sources/BekitzurNotes/LanguageModel.swift)). For a first screen, use the harness's Ollama path, `python3 bakeoff.py run --model <name> --prompt v2 --num-ctx 131072`, if the installed Ollama supports the architecture; Ollama applies each GGUF's own template. Port the survivors to the engine afterwards, for example with llama.cpp's `llama_chat_apply_template` and the template stored in the GGUF.
  - **Qwen3.6:** thinking off. Run once greedy, and once with Qwen's non-thinking sampling (temperature 0.7, top-p 0.8, top-k 20, presence penalty 1.5), to see whether greedy decoding repeats.
  - **DictaLM:** once with thinking on (`--think`, `--max-tokens 16384`), and once with an empty thinking block so it answers directly. Watch for loops.
  - **Muse Glimmer:** reasoning strength low, with a reasoning budget. Confirm the JSON schema constrains only the answer, not the reasoning. Run once greedy and once with Meta's sampling (temperature 1.0, top-p 0.95, top-k 64).
- **Record the harness's columns for each run:** Action Items, Owners, due dates, traps, extras, Decisions, Open Questions, grounded quotes, prompt tokens, reading and writing speed, time and memory. Compare prompt tokens too: tokenizers differ in how efficiently they encode Hebrew, which changes how much meeting fits.

**Step 4: a long real meeting.**

1. Pick a real Hebrew meeting with English terms that runs longer than two hours, so over 32K tokens: one that fails today. Add a one-hour meeting for timing.
2. Run the control at 128K and each surviving candidate through the whole pipeline: Notes, the follow-up checks in the same chat, and a few Ask questions. The engine's chat only appends and never rewinds, which also suits Qwen3.6's recurrent layers.
3. Check that it completes, that the Notes include items from the last third of the meeting, that quotes check out, and that Owners and dates make sense.
4. Have someone who attended mark each item correct, wrong, missing or invented, without knowing which model wrote it.

**Step 5: a 32 GB laptop.** Run the winner on a 32 GB laptop. Read the GPU memory limit from llama.cpp's Metal start-up log, and confirm that the model plus a 128K context fit without admin changes.

**Decision rule.** Switch only if a model:

- loses nothing on the five cases;
- does better on Owners, the long cases or the real-meeting review;
- meets the time and memory targets, or the team explicitly accepts slower Notes;
- runs on 32 GB laptops, or has a documented fallback (such as keeping 26B-A4B there).

If nothing wins, keep Gemma 4 26B-A4B with the longer context from step 1.

**Things to watch:** a Hebrew leaderboard entry for Qwen3.6, Muse Glimmer or Nemotron 3.5 Lightning; a non-thinking DictaLM 24B; any Qwen4 release (none on Hugging Face yet); and Hebrew fine-tunes of the hybrid models.

## Gaps and inconsistencies

- **No benchmark covers this task.** Nothing published measures Hebrew conversation, meeting notes, or Hebrew–English code-switching.
- **Dicta's leaderboard.** It doesn't record run settings, its summary scores depend on GPT-4o's judgment against Gemini 2.5 Pro, and it omits Qwen3.6, Muse Glimmer, Nemotron 3.5 Lightning, gpt-oss-20b and DictaLM's 12B; the 12B's scores come from Dicta's report. Dicta made one of the models it ranks highest.
- **AlephBench** is one six-model snapshot from May, without Gemma 4 26B-A4B.
- **Hebatron.** Its card claims a Hebrew reasoning average that beats DictaLM's (73.8%) ([model card](https://huggingface.co/HebArabNlpProject/Hebatron)), but AlephBench, run by the same organization, ranks it 77.1 to DictaLM's 85.2.
- **Gemma 4 sizes.** Google's report lists 16.2 GB (26B-A4B) and 19.2 GB (31B) at Q4_0 ([report, Table 3](https://arxiv.org/html/2607.02770)); Google's GGUF files are 14.44 GB and 17.65 GB.
- **Gemma 4 drafter dates.** Google's release notes date the drafters April 16, 2026 ([release notes](https://ai.google.dev/gemma/docs/releases)); the llama.cpp pull request that added the format cites a May 5 announcement ([PR #22738](https://github.com/ggml-org/llama.cpp/pull/22738)).
- **DictaLM licenses.** Dicta's page says all DictaLM 3.0 models are Apache 2.0 ([Dicta](https://dicta.org.il/dicta-lm-3)); Hugging Face lists the 12B models as "other" ([Hugging Face](https://huggingface.co/dicta-il)).
- **Qwen languages.** "201 languages" comes without a list; Hebrew is named only for Qwen3.5-Omni's speech recognition and synthesis ([Qwen](https://qwen.ai/blog?id=qwen3.5-omni)).
- **Speed sources.** llama.cpp's Qwen benchmark doesn't name its hardware, and Meta measured Muse Glimmer with ExecuTorch, not llama.cpp.
- **Vendor tables.** Qwen and Meta ran their comparisons themselves, with their own harnesses, so numbers can't be compared across cards.
- **32 GB laptops.** The default GPU memory limit on 32 GB laptops is unverified.

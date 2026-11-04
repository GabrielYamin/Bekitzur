# Bekitzur

Bekitzur (Hebrew for "in short") is a Mac menu bar app that records Conversations, calls and in-person meetings alike, transcribes them in Hebrew or English, recognizes who spoke, and writes English Notes: a summary, Decisions, Action Items with Owners and due dates, and Open Questions, each pointing to the lines it came from. Everything runs on the Mac.

Bekitzur is open source, under the [MIT License](LICENSE). Its releases are on this repository's [Releases](https://github.com/GabrielYamin/Bekitzur/releases) page, and the app updates itself from there.

## What it does

- Records the microphone you pick (or the Mac's default) and everything the Mac plays, so both sides of a call, as two tracks that keep time even when the Mac is busy, lined up after the call by the copy of it that laptop speakers put in the microphone.
- Shows a live Transcript while recording, and tells Hebrew from English by the first speech.
- Offers to record when Slack, Teams, Zoom, FaceTime, or a browser starts using the microphone, and to stop once the call is over; or, if you choose, records the call on its own and stops when it ends.
- Transcribes Hebrew with ivrit.ai's Whisper fine-tune and English with Whisper large-v3-turbo, through whisper.cpp. A call's two sides are transcribed each on its own, the microphone without the speakers' copy of the call, so two people talking at once are both written down. English terms spoken in Hebrew come out in English letters (the Vocabulary), and corrections teach it new spellings.
- Separates Speakers with FluidAudio (pyannote community-1 and NVIDIA's Nemotron 3 Diarization), and names people it has heard before from their Voiceprints, which can be renamed in Settings, everywhere they appear.
- Writes the Notes with Gemma 4 26B-A4B through llama.cpp. Quotes are checked against the Transcript, and due dates are worked out in code.
- For review: listen back along the Transcript, fix words and Speakers, update or edit the Notes, rename Conversations, check Action Items off and add the ones with a due day to your calendar, and ask questions that are answered only from the Transcript. Once every Action Item is done, it offers, now and then, to delete the Conversation.
- Finds Conversations by the people in them and by what was said in them, in their titles, Notes, and Transcripts.
- Downloads its own models with their progress, imports recordings made elsewhere, exports a Conversation as one file that someone else with Bekitzur opens to add it, and updates itself from signed releases after asking.

[docs/plan.md](docs/plan.md) has the design and a log of what was built and how it measured. [CONTEXT.md](CONTEXT.md) defines the terms, like Conversation, Speaker, and Voiceprint.

## Privacy

Recording, transcription, speaker recognition, and Notes all run on the Mac. Conversations, Voiceprints, and the Vocabulary are stored in `~/Library/Application Support/Bekitzur`, in files only the user can read. The app goes online only to download models from Hugging Face and to check GitHub for updates.

Recordings and personal data stay out of git: `eval/recordings/` and `eval/private/` (the scripted read and the team's own terms) are ignored, and test data uses invented names.

## Disclaimer

Bekitzur is provided as is, without warranty of any kind, and its authors aren't liable for anything that comes of using it, like a recording that's lost or incomplete, a mistake in a Transcript, Speakers, or Notes, or a decision made from them. Everything runs on your Mac: recordings, Transcripts, Notes, and voices stay on it, and Bekitzur goes online only to download its models and updates. You're responsible for telling the people you record, and for following the law and your organization's rules on recording. The [MIT License](LICENSE) has the full terms.

## Requirements

- A Mac with Apple silicon and at least 32 GB of memory, running macOS 26 or later. With 24 GB the app says writing Notes may be slow or fail; with less, it doesn't download its models.
- About 20 GB of free disk space for the models, which the download checks; a recording warns first with less than 2 GB free
- To build: Xcode 26 or its Command Line Tools (Swift 6.2)

## Install

1. Download [Bekitzur.zip](https://github.com/GabrielYamin/Bekitzur/releases/latest/download/Bekitzur.zip) and open it, which unpacks a Bekitzur folder.
2. Open Terminal and run:

   ```bash
   bash ~/Downloads/Bekitzur/install.sh
   ```

   It installs the app in the Applications folder of your home folder and opens it.
3. Bekitzur lives in the menu bar. Choose **Download** in its window to get its speech, language, and speaker models (about 18 GB) from Hugging Face; if the download is interrupted, Download picks up where it left off. The first recording asks for the microphone and for system audio (the other side of calls).

Bekitzur checks for new versions and asks before installing one; **Check for Updates…** in its menu checks right away. Updates keep your Conversations, names, and settings.

To remove it, quit Bekitzur, then delete `~/Applications/Bekitzur.app` and `~/Library/Application Support/Bekitzur` (your Conversations and the models).

## Working on a new Mac

1. Install the Command Line Tools (`xcode-select --install`), and clone this repository.
2. Build the app, install it in `~/Applications`, and open it: `scripts/build-app.sh`.
3. Choose Download in its window to get the models, about 18 GB at pinned revisions with checksums; an interrupted download picks up where it left off. `bekitzur models --download` does the same from Terminal.
4. Run the tests: `scripts/test.sh`. Tests that need the models or the scripted read (`eval/recordings/meeting-1.m4a`, which isn't in git) are skipped without them.
5. Record once to grant the microphone, system audio, and notification permissions.

To bring your data along, copy `~/Library/Application Support/Bekitzur` (its Models folder can download again instead), and `eval/private/` and `eval/recordings/` if you need them.

## Building

- `scripts/build-app.sh` builds `build/Bekitzur.app`, installs it in `~/Applications`, and opens it. It won't replace the app while it's recording.
- `scripts/package.sh` builds the app and packs it with `install.sh` into `build/Bekitzur.zip`, the file to hand someone. It installs nothing, so it can run while recording. `BEKITZUR_VERSION=0.3.0 scripts/package.sh` sets the version the app shows.
- `swift build -c release` builds the app's executable and the `bekitzur` command-line tool into `.build/release`.

Builds are signed ad hoc as `app.bekitzur.mac`, which needs no developer certificate and keeps macOS permissions across updates. Build numbers are the build's time in UTC, and updates compare only those. Builds made here show version 9.9.9, from `App/Info.plist`, so they're never mistaken for a release; releases show their tag's version.

Changes reach `main` through pull requests, which CI builds, tests, and packages on GitHub's macOS 26 runner before they can be merged. Releases are built, tested, and signed by the Release workflow on the same runner, which only the repository's owner can run. The app installs only releases signed with the key whose public half is `BekitzurUpdatePublicKey` in `App/Info.plist`.

`scripts/make-icon.swift` draws the icon and the menu bar images into `App/Resources`, and `scripts/generate-built-in-vocabulary.py` turns `eval/vocabulary/built-in.txt` into the built-in list of English terms.

## The command-line tool

`bekitzur` runs the same engine on audio files, to test and measure without the app:

```bash
swift build -c release --product bekitzur
.build/release/bekitzur transcribe --live --language auto recording.m4a
```

Its commands are `process` (Transcript, Speakers, and Notes for one recording), `transcribe`, `language`, `speech`, `speakers`, `enroll`, `align`, `separate`, `notes`, `vocabulary`, `ask`, `models`, and two experiments, `audio-check` and `english-terms`. `bekitzur help <command>` explains each one.

## How the code is organized

| Folder | What's in it |
|---|---|
| `Sources/BekitzurApp` | The menu bar app (SwiftUI) |
| `Sources/BekitzurCapture` | Recording the microphone and the Mac's audio |
| `Sources/BekitzurAudio` | Loading audio, and lining up a call's two tracks |
| `Sources/BekitzurTranscription` | Transcription and language detection with whisper.cpp |
| `Sources/BekitzurSpeakers` | Speaker separation, Voiceprints, and speech detection with FluidAudio |
| `Sources/BekitzurNotes` | Notes and answers with Gemma through llama.cpp |
| `Sources/BekitzurVocabulary` | English terms in Hebrew Transcripts |
| `Sources/BekitzurPipeline` | A Conversation from audio to Notes, and live transcription in a helper process |
| `Sources/BekitzurDomain` | Shared types, like Conversation, Transcript, and Notes |
| `Sources/BekitzurLibrary` | Conversations on disk |
| `Sources/BekitzurUpdates` | Checking, verifying, and installing updates |
| `Sources/BekitzurModels` | The models the app needs, and downloading them |
| `Sources/bekitzur` | The command-line tool |
| `App` | Info.plist, the icon, and the acknowledgements, which go into the app |
| `Tests` | Unit tests |
| `scripts` | Building, packaging, installing, testing, the icon, and update signing |
| `eval` | Scoring scripts for word error rate, Speakers, and the Vocabulary |
| `spikes` | Experiments: the comparison that chose Gemma for the Notes (`llm-bakeoff`), and questions to try Ask with (`ask-eval`) |
| `docs` | The plan, the architecture decisions, and research on the models |
| `release/notes` | Each release's notes, as `<version>.md` |
| `.github/workflows` | CI, which builds, tests, and packages each pull request, and the Release workflow |

## Credits

Bekitzur is built on these projects:

| Project | Used for | License |
|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Speech recognition | MIT |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Running the language model | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Speaker separation and speech detection | Apache 2.0 |
| [Swift Argument Parser](https://github.com/apple/swift-argument-parser) | The command-line tool | Apache 2.0 |

And these models, which the app downloads and which aren't part of it:

| Model | Used for | License |
|---|---|---|
| [ivrit.ai Whisper large-v3-turbo](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml) | Hebrew transcription | Apache 2.0 |
| [OpenAI Whisper large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo), in [whisper.cpp's format](https://huggingface.co/ggerganov/whisper.cpp) | English transcription and language detection | MIT |
| [Google Gemma 4 26B-A4B](https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf) | Notes and answers | Apache 2.0 |
| [Silero VAD](https://github.com/snakers4/silero-vad), [converted to Core ML by Fluid Inference](https://huggingface.co/FluidInference/silero-vad-coreml) | Finding speech | MIT |
| [pyannote speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) with WeSpeaker and BUT Speech@FIT, [converted to Core ML by Fluid Inference](https://huggingface.co/FluidInference/speaker-diarization-coreml) | Speaker embeddings and separation | CC BY 4.0 |
| [NVIDIA Nemotron 3 Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization), [converted to Core ML by Fluid Inference](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml) | Speaker separation | OpenMDW 1.1 |
| [NVIDIA Streaming Sortformer](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1), [converted to Core ML by Fluid Inference](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml) | Speaker separation in installs from before Nemotron, until its model is downloaded | NVIDIA Open Model License |
| [MossFormer2_SS_16K](https://huggingface.co/alibabasglab/MossFormer2_SS_16K) from Alibaba's [ClearerVoice-Studio](https://github.com/modelscope/ClearerVoice-Studio), [converted to Core ML](https://huggingface.co/Moipee/MossFormer2-SS-16K-CoreML) | Separating two people who talk at once | Apache 2.0 |

Thanks to ivrit.ai for open Hebrew speech models, to the ggml authors for whisper.cpp and llama.cpp, to Fluid Inference for FluidAudio and its Core ML conversions, and to OpenAI, Google, Alibaba, pyannote, WeSpeaker, BUT Speech@FIT, Silero, and NVIDIA for releasing their models.

The full license texts of the software in the app are in [App/Resources/Acknowledgements.txt](App/Resources/Acknowledgements.txt), which ships inside the app.

## License

Bekitzur is released under the [MIT License](LICENSE). The software and models it uses keep their own licenses, listed above.

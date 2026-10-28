# Capture audio on the Mac, not through meeting bots or platform transcripts

Bekitzur records the microphone and the Mac's system audio itself instead of joining calls as a bot or importing Teams' built-in transcripts. Bots and platform transcription process audio in a vendor's cloud, which ADR-0001 rules out, and neither covers Slack huddles, phone calls relayed to the Mac, or in-person conversations. The cost is that the app gets mixed audio without the platform's speaker metadata, so it has to separate and recognize Speakers itself.

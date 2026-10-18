# Voice chat (experimental)

Proximity voice between the two players, built on Steam's own voice API.

- **Microphone:** whatever is set in Steam → Settings → Voice. That's also where you test it or mute it.
- **Push to talk:** hold **V**. It only records while the game window is in front.
- **Distance:** full volume within 5 m, fading out by 50 m, silent when you're not in the same world.
- **CO-OP tab:** `VOICE: ON/OFF` and `VOL 100% / 60% / 30%`. The tab shows `TALKING` while you're sending.

Under the hood the bridge records and compresses with `ISteamUser::GetVoice`, sends the packets over Steam P2P on
their own channel, and plays them back through Windows `waveOut`. The mod only writes the settings and the
distance to the other player (`mirror_voice.txt`, four times a second).

`SurrounSyncBridge.exe --voice-smoke` checks that Steam voice and audio playback start on a PC.

Still to do: a key binding option, a "talking" marker on the name tag, and a jitter buffer if playback stutters on
bad connections. It hasn't had much testing between two real PCs yet.

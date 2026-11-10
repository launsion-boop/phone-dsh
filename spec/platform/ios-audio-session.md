# iOS app audio-session ownership

Status: frozen app-local API revision 2, under P08. This specifies the existing
ProbeKit to probe-app boundary. It adds no SDK, Worker, wire or persisted surface.
Android continues to use the foreground-service policy in `whitelist.json`.

## 1. Authority and owners

`examples/probe-app/ProbeKit/PhoneAudioSessionLease.swift` is the only application
owner of audio-session category and activation. The keep-alive, composer dictation
and `PhoneMediaTools.record` acquire and release through it on the main actor.
There is one keep-alive instance and at most one live microphone token.
`SilentAudioKeepAlive.shared` is that instance: its callers (the chat turn,
the DEBUG TonoLink relay and the TonoLink voice turn while a board with a wake
word is connected) start and stop it under their own owner name, and it
holds the lease's single keep-alive claim from the first owner until the last one
stops.

- `beginKeepAlive(reclaim:)` registers silent rendering before activation.
  `activateKeepAliveSession()` activates its compatible profile. A failed rendering
  start rolls back the claim with `endKeepAlive()`.
- `acquireMicrophoneUser()` returns a unique `MicrophoneToken` after successful
  configuration. A concurrent microphone request fails with the existing
  microphone-unavailable error. No failed acquisition commits a token.
- `releaseMicrophoneUser(_:)` releases only the current token. A stale, repeated
  or never-acquired release has no effect. Idle composer cancellation releases
  no token and does not touch another recording.
- `endKeepAlive()` drops only silent rendering. Deactivation occurs only after
  both claims are absent. Stopping silent rendering must preserve live recording.

## 2. Profiles and handoff

A pure keep-alive run uses playback, default mode and mixWithOthers. A microphone
request uses playAndRecord, default mode, mixWithOthers, defaultToSpeaker and
allowBluetooth. This retains existing route support and adds no Bluetooth
requirement. Input capture exists only during an explicit microphone request.

After microphone configuration, retain that mixable profile until the last owner
releases the session. Reacquiring the microphone while that profile remains owned
must not reconfigure or reactivate it. Reclaim resumes silent rendering without
forcing playback over an active microphone. Failed configuration restores the
previous owner's profile where possible and never releases that owner.

Silent rendering also resumes after an AVAudioEngine configuration change, an
audio route change (for example screen mirroring to an AirPlay receiver starting
or ending) or a 5 s watchdog finding the engine or player stopped. That resume
re-activates the keep-alive profile only while no microphone owner holds the
session; otherwise it restarts rendering without touching category or activation.

The TonoLink voice turn plays cloud TTS (16 kHz PCM) through its own
AVAudioEngine and never records (the board's microphone does). For each turn it
holds a **speaker-output** claim: `acquireSpeakerOutput()` applies the same
mixable playAndRecord profile (sticky exactly like a microphone's) and, only
while the current output is an AirPlay receiver, overrides the output to the
built-in speaker. Mirroring the screen to the TonoLink board makes the output
AirPlay, and the board discards AirPlay audio, so without the override the
phone's speech is silent (xiaozhi-link `USB_AIRPLAY_LESSONS.md`,
`VoiceAssistant.activateSpeechSession`). Any other output (speaker, headphones,
Bluetooth) is left as is. `releaseSpeakerOutput(_:)` of the last speaker token
removes the override; a stale or repeated release has no effect; deactivation
still waits for every claim (keep-alive, microphone, speaker) to be absent.

OS interruptions, media-service reset, process termination and external category
changes are not guaranteed to preserve capture. This revision does not promise
that a microphone can be first activated after entering the background.

## 3. Compatibility and evidence

All callers and ProbeKit ship in one signed application bundle. API revision 2
removes the unowned release overload and migrates every caller atomically. Mixed
old and new source or framework binaries are unsupported and fail compilation or
linking. No wire version, tool argument, error code, tool-result shape, artifact
format or UserDefaults key changes. Existing data and whole-app rollback remain
compatible.

Valid and invalid ownership fixtures run through the real lease state in
`examples/probe-app/PhoneDSHSimTests/ProbeSceneLifecycleTests.swift`. They cover
the speaker-output claim (AirPlay override and restore, shared profile, stale release, failed
configuration), both handoff orders, zero-owner deactivation, stale and double release, failed
activation and concurrent microphone rejection. Source-boundary checks are in
`Tests/PhoneDSHTests/ProbeScenePhaseWiringTests.swift`. Device acceptance must
check actual recording files, event progression, locked completion and cleanup;
requested duration and a helper's active flag alone are insufficient evidence.

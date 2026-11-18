# Fast debug channel (DEBUG builds only)

Edit → build → sign → install → relaunch → copy files took minutes per cycle. The DEBUG build now carries a
small HTTP control channel so a Mac script can inspect and drive the running app in about a second.
Contract: [spec/dev/debug-channel.md](../spec/dev/debug-channel.md) (DEV-01, developer tooling, not a product protocol).

## Use

Install a Debug build once, keep the app in the foreground (screen on), then:

```bash
S=examples/probe-app/scripts/pdsh-debug.py
python3 $S bots                       # roster with bound device keys, deviceBots.v1 / intents
python3 $S devices                    # BLE devices, link state, tools, grants
python3 $S connect "AI Passport"      # scan + connect the board
python3 $S logs voice -n 50           # tail of the trace / `status` for chat-status.log
python3 $S chat "<prompt>" --bot ID   # run a turn; returns tool calls, outputs and the answer
python3 $S approvals --bot ID         # pending approval cards
python3 $S approve --bot ID [--deny]  # resolve one
python3 $S turn --wait 60             # keep waiting for the last chat
python3 $S link "AI Passport" app.info
python3 $S grants "AI Passport"; python3 $S grant "AI Passport" app.run --revoke
python3 $S create-bot test; python3 $S delete-bot ID [ID...] [--full]
```

The script finds the phone with `xcrun devicectl` (the CoreDevice tunnel address, an `fd..` private IPv6) and
reads the per-launch token from `Documents/debug-channel.json` over devicectl; nothing is typed by hand. A
relaunch changes the token; the script re-reads it on a 401. Overrides: `PDSH_DEBUG_UDID`, `PDSH_DEBUG_HOST`,
`PDSH_DEBUG_TOKEN`.

## Safety

- Compiled only under `#if DEBUG`; check a Release build with
  `xcodebuild -configuration Release … build` then `nm -a <app>/PhoneDSHProbe.debug.dylib <app>/PhoneDSHProbe | grep -c DebugChannel`
  (expect 0) or `strings`.
- Listens only while the app is in the foreground; random token per launch; private/LAN peers only.
- It never reads API keys. `/approve` and `/link` use the same paths as the UI (card button, user-origin
  Link call).

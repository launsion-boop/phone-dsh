# pclink-pacing UI receipts

Captured on the dedicated simulator `620D518D-D125-4154-B1B7-32A65327482B`
(iPhone 17 Pro, iOS simulator) from the DEBUG build of
`examples/probe-app` at this unit. Scenes use the throwaway second app bundle
(`dev.phone-dsh.probe.pacing`) paired to a temporary DSH 0.2.2 instance with
synthetic workspaces (`work`, `work2`) and sessions named 新会话, so no user
pairing record or real session title is shown. The user's installed app
(`dev.phone-dsh.probe`) and its data were not uninstalled, cleared or unpaired.

| File | Scene |
| --- | --- |
| `drawer-light.png` / `drawer-dark.png` | Drawer: 新会话 capsule, 手机 \| PC segment below it, PC groups named by the DSH workspace titles (`work2`, `work`) |
| `workspace-picker-light.png` / `workspace-picker-dark.png` | PC new/empty-session composer: workspace chip (`work`) on the model row |
| `install-guide-light.png` / `install-guide-dark.png` | PC unpaired empty state: 连接电脑 card plus the copyable install/pairing commands |
| `pairing-guide-light.png` / `pairing-guide-dark.png` | PCPairingPage: the same install guide above the fingerprint |

The workspace menu was not opened in the static screenshots (no accessibility
automation on this host); the chip's chevron and
`PCLinkPacingSimTests`/page contract cover the selection state.

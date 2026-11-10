# pclink-qr-approval UI receipts (2026-11-10)

Captured on simulator `620D518D-D125-4154-B1B7-32A65327482B` from the
`feat/pclink-qr-approval` branch, light + dark. The app was built with a
temporary bundle id (`dev.phone-dsh.probe.qr`) and uninstalled afterwards; the
user's installed `dev.phone-dsh.probe` was not touched.

| File | Surface / state |
| --- | --- |
| `pairing-unconnected-light.png`, `pairing-unconnected-dark.png` | 「连接电脑」, idle: one install command, 扫码连接, folded 其他方式, one permission line. |
| `pairing-connecting-light.png`, `pairing-connecting-dark.png` | 「连接电脑」, waiting for a delayed `pair.confirm`: inline 正在连接 <电脑名>… + 取消配对. |
| `pairing-failed-light.png`, `pairing-failed-dark.png` | 「连接电脑」, invalid pairing input: one reason line + 重试. |
| `drawer-unpaired-light.png`, `drawer-unpaired-dark.png` | Drawer PC segment, no record: one small card + 连接电脑; no install command. |
| `connected-computer-light.png`, `connected-computer-dark.png` | 我的 › 已连接的电脑: 本机指纹, 配对方式 (扫码), 配对时间, relay, actions below the fold. |

The connected screenshot comes from a real relay pairing against a test PC peer
(on `http://127.0.0.1`), so the DSH version is "未获取（电脑离线）" after the
peer stopped; the record's pairing mode/time/fingerprint are real.

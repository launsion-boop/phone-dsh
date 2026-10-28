# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting for this repository
("Security" → "Report a vulnerability"), or contact a maintainer listed in
AUTHORS directly. We aim to acknowledge a report within three working days.

Please include: what you ran, what you expected, what happened, and the app
version (`设置 → 关于`) or commit you tested. Do not attach real API keys,
session logs or files that contain personal data; redact them first.

## What the project handles

- **API keys** live in the device Keychain and are injected by the host-side
  model gateway. The Worker never receives them. A key is only attached to the
  configured model origin and to real model-protocol paths.
- **Model traffic** goes directly from the device to the configured provider;
  nothing is proxied through a server run by this project.
- **Egress** is limited by an allow-list that the app and the Worker both
  enforce. Adding a host is an explicit user action.
- **Sessions and files** stay on the device. The app writes them under its own
  container and can export them only through a user-initiated share.

Local builds of this repository link a pinned DeepSeek Harness checkout that is
never vendored or modified; see `plugins/dsh-pin.json`.

## Scope

Reports about the pinned upstream DeepSeek Harness belong upstream
(https://github.com/deepseek-ai/deepseek-harness) unless the issue is in the
host integration in this repository.

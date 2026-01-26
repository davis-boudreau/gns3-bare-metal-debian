# Security Policy

## Supported Versions

Only the latest tagged release is supported.

## Reporting a Vulnerability

If you discover a security vulnerability:
- Do **not** open a public issue with exploit details.
- Instead, contact the maintainer privately.

## Important Notes

This project is intended for **lab environments**. The default guidance may:
- enable SSH password authentication
- create a privileged runtime user
- create a bridged L2 network (TAPs)

Review `docs/security-notes.md` before using in production-like environments.

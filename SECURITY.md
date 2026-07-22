# Security Policy

## Reporting a Vulnerability

Please report suspected vulnerabilities through [GitHub's private vulnerability reporting form](https://github.com/jungwuk-ryu/Switchyard/security/advisories/new). Do not include exploit details, credentials, private container data, or unredacted logs in a public issue.

Include the affected commit, macOS version, Apple Silicon model, impact, reproduction steps, and the smallest redacted evidence needed to investigate. We aim to acknowledge complete reports within seven days.

## Supported Versions

Switchyard is currently a pre-release project. Security fixes are made on `main`; there are no supported release branches or signed binary releases yet.

## Scope

Reports about the Swift app, runner boundary, manifest handling, source synchronization, logging, or build and release integrity belong here. Vulnerabilities in the patched Wine source should be reported privately to [`switchyard-wine`](https://github.com/jungwuk-ryu/switchyard-wine/security/advisories/new) when possible.

Apple Game Porting Toolkit components are separately licensed Apple software; the current release imports a user-provided copy. Third-party Windows applications are user-provided software. Their upstream vulnerabilities are outside Switchyard's maintenance scope, while unauthorized GPTK redistribution, component-channel integrity failures, or other boundary failures that expose third-party software are in scope.

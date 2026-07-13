# Security policy

MKV Player processes complex, attacker-controlled media and subtitle files. A
crash, sandbox escape, memory-safety issue, unsafe URL access, update-signature
failure, or security-scoped bookmark leak should be treated as a security issue.

## Supported versions

Until the first stable release, security fixes are made on the default branch.
Afterward, only the latest published minor release will receive fixes unless a
release note explicitly says otherwise.

| Version | Supported |
| --- | --- |
| Default branch / latest release | Yes |
| Older releases | No |

## Private reporting

Do not open a public issue. Use GitHub's **Report a vulnerability** action in the
repository Security tab to create a private security advisory. Include:

- affected version or commit;
- macOS version and architecture;
- impact and realistic attack scenario;
- reproduction steps and the smallest safe test file or generator;
- crash report or sanitizer output with secrets and personal paths removed;
- any suggested mitigation.

If the private advisory form is unavailable, contact a maintainer through their
public GitHub profile and ask for a private reporting channel. Do not send an
exploit or private media until a secure channel is established.

Maintainers will acknowledge a complete report within seven days, provide a
status update at least every fourteen days while it is active, coordinate a fix
and disclosure date, and credit reporters who want attribution. Please allow a
reasonable remediation window before disclosure.

## Scope notes

- Media parsing and decoding primarily occur in the pinned mpv/FFmpeg stack.
  Reports affecting an upstream project may need coordinated disclosure; the
  maintainers will help route them without publishing the report prematurely.
- The application sandbox, hardened runtime, security-scoped file access, and
  Sparkle EdDSA update verification are security boundaries and must not be
  disabled to work around a bug.
- URL streaming, plug-ins, scripts, DRM, disc menus, and downloaded executables
  are outside the intended version 1 feature set. If the app unexpectedly
  permits one, please report it.

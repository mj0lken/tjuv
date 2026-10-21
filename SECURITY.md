# Security policy

## Reporting a vulnerability

Please don't open a public issue for security problems. Report them privately through
[GitHub's vulnerability reporting](https://github.com/mj0lken/tjuv/security/advisories/new)
instead.

Useful things to include: the Tjuv version, your macOS version, what an attacker can do,
and the steps to reproduce it.

## Supported versions

Only the [latest release](https://github.com/mj0lken/tjuv/releases/latest) gets fixes.

## What's in scope

Tjuv runs as your user, with one exception: keeping the Mac armed with the lid closed
installs a narrow, `visudo`-validated `sudoers` rule (`/etc/sudoers.d/tjuv`) for `pmset`.
Anything that widens what that rule allows, lets another user or process trigger it, or
bypasses Touch ID / local authentication when disarming is a vulnerability. So is anything
that sends diagnostics off the machine without you choosing to.

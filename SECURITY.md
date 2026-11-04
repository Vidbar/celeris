# Security policy

Celeris parses untrusted input in several places — fonts (stb_truetype, HarfBuzz),
images (stb_image), text and the values hosts pass across the C-ABI — so memory
safety bugs there matter.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub:
**Security → Report a vulnerability** on this repository (a private security
advisory). Include the Celeris version or commit, the platform, and a reproduction
(a minimal C or Zig program, or the input file).

You should get an acknowledgement within a week. Fixes land on `main` and in the
next release, and the advisory is published once a release with the fix is out.

## Supported versions

Before 1.0 only the latest release receives security fixes.

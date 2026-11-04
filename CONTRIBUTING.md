# Contributing to Celeris

Thanks for helping out. A few rules keep the codebase consistent:

## Code quality

- **No duplication.** Before adding a function, struct or logic block, check
  whether something similar already exists. Prefer reusing, refactoring or
  parameterizing existing code. Helpers shared across widgets live in
  `src/framework/component.zig`.
- **Handle errors.** Use Zig's error handling (`try`, `catch`, `if (err) |e|`)
  properly; don't swallow errors or leave placeholders.

## Tests

- **Real assertions.** No empty or placeholder tests: every test verifies
  something with `std.testing.expect*`.
- **No leaks.** Use `std.testing.allocator` in tests and clean up with `defer`.
- Run the suite before sending a change:

  ```bash
  zig build test
  ```

  CI runs the same command on Windows and Linux for every pull request.

## C-ABI changes

The C header (`include/celeris.h`) and the exports in `src/c_api.zig` must match.
`zig build test` compiles and links `examples/c_smoke.c` against both, so a
mismatch fails the build. When you add an export, declare it in the header, mirror
it in `bindings/csharp` if the binding uses it, bump `CELERIS_ABI_VERSION`, and add
a line to `CHANGELOG.md`.

## Bug fixes

Every bug fix comes with a regression test that:

1. reproduces the original scenario,
2. runs as part of `zig build test`, and
3. explains in a short comment what the root cause was and how the test
   guards against it.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).

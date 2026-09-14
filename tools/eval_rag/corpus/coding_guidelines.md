# Backend Coding Guidelines

- prefer composition over inheritance
- every public function needs a doc comment
- keep functions under 40 lines
- error handling: use sum types, avoid exceptions in libraries

## Testing
- unit tests live next to the code
- integration tests run in CI nightly
- never mock what you can simulate

These guidelines reference the style used in the auth subsystem (auth_overview.md).

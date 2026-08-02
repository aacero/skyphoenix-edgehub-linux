# Contributing to SkyPhoenix EdgeHub for Linux

Thanks for your interest in contributing! This document outlines how to get involved.

## Code of Conduct

Please read and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Project Status

The project is preparing its first stable release. Bug reports, focused fixes,
tests, documentation, design feedback, and feature proposals are welcome. See
[ROADMAP.md](ROADMAP.md) for the current status and planned work.

## How to Contribute

### 1. Give Feedback

- Read the [Product Vision](docs/product/product-vision.md), [Architecture Overview](docs/architecture/overview.md), and [ADRs](docs/adr/).
- Open a [Discussion](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/discussions) with feedback, ideas, or questions.
- Vote on existing discussions to help prioritize.

### 2. Report Bugs

- Check existing issues first.
- Use the bug report template.
- Include:
  - Distribution and version
  - Desktop environment and session type (Wayland/X11)
  - Display configuration
  - Application version
  - Steps to reproduce
  - Expected vs actual behavior
  - Logs (if applicable)

### 3. Suggest Features

- Open a feature request discussion.
- Describe the use case and user story.
- Consider how it fits the [MVP Scope](docs/product/mvp-scope.md).

### 4. Submit Code

1. **Fork** the repository.
2. **Create a branch:** `feature/your-feature` or `fix/your-bug`.
3. **Write code** following our conventions.
4. **Write tests** (see [Test Strategy](docs/testing/test-strategy.md)).
5. **Run tests:** `./scripts/run_all_tests.sh`.
6. **Run lints:** from `core/`, run `cargo fmt --all -- --check` and
   `cargo clippy --all-targets --locked -- -D warnings`.
7. **Commit** with conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`.
8. **Push** and open a Pull Request.
9. **Respond to review** feedback.

### 5. Write Documentation

Documentation contributions are always welcome:

- Fix typos, clarify explanations
- Add examples and tutorials
- Improve installation guides
- Translate documentation

### 6. Test

- Test on your distribution and desktop environment.
- Report compatibility in the compatibility matrix discussions.
- Help with visual testing and UAT scenarios.

## Development Setup

### Prerequisites

- **Rust** 1.86+ (stable): https://rustup.rs
- **C++ compiler**: GCC 12+ or Clang 16+
- **CMake** 3.22+
- **Qt 6.9+** development packages

#### CachyOS / Arch Linux
```bash
sudo pacman -S --needed base-devel git rust cmake qt6-base qt6-declarative \
  qt6-svg qt6-wayland qt6-tools
```

#### Ubuntu 26.04 LTS
```bash
sudo apt install git cargo cmake make g++ qt6-base-dev qt6-declarative-dev \
  qt6-svg-dev qt6-wayland-dev qt6-tools-dev libglib2.0-dev
```

Ubuntu 24.04's native Qt 6.4 is below the project's Qt 6.9 minimum. Use the
AppImage or an upstream Qt toolchain there.

### Build
```bash
git clone https://github.com/skyphoenix-it/skyphoenix-edgehub-linux.git
cd skyphoenix-edgehub-linux
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

### Run Tests
```bash
cd core
cargo test --locked
cd ..
./scripts/run_ui_tests.sh
./scripts/run_cpp_tests.sh
```

### Format & Lint
```bash
cd core
cargo fmt --all -- --check
cargo clippy --all-targets --locked -- -D warnings
cd ..
qmllint ui/qml/
```

## Code Conventions

### Rust
- Follow [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/)
- Use `rustfmt` default configuration
- Use `clippy` with default lints, deny warnings in CI
- Document public API with rustdoc
- Prefer `Result<T, Error>` over panicking
- Use `tracing` crate for logging (not `println!`)

### C++
- Follow [Qt Coding Style](https://wiki.qt.io/Qt_Coding_Style)
- C++17 minimum
- Use Qt classes where available (QString, QVector, etc.)
- RAII, no bare `new`/`delete`
- Smart pointers over raw pointers

### QML
- Follow [QML Coding Conventions](https://doc.qt.io/qt-6/qml-codingconventions.html)
- Use `qmllint` for validation
- Component IDs: camelCase
- Property names: camelCase
- Use Qt Quick Controls 2 where possible
- Minimum touch target: 48×48 logical pixels

### Commits
- Use [Conventional Commits](https://www.conventionalcommits.org/):
  - `feat:` - new feature
  - `fix:` - bug fix
  - `docs:` - documentation
  - `test:` - tests
  - `refactor:` - code restructuring
  - `chore:` - build, CI, tooling
  - `perf:` - performance improvement

### Pull Requests
- One concern per PR
- Reference related issues
- Include test coverage
- Keep PRs small (<500 lines when possible)
- PR title uses conventional commit format

## Project Structure

```
skyphoenix-edgehub-linux/
├── app/                  # Hub C++ entry point and system bridges
├── core/                 # Rust configuration, metrics, display, and C FFI
├── ui/qml/               # Hub UI and first-party widgets
├── manager/              # Companion Manager application
├── packaging/            # AppImage, Arch, DEB, RPM, and lifecycle tooling
├── tests/                # Unit, UI, runtime, hardware, visual, and performance tests
├── docs/                 # Product, architecture, operations, and release documentation
├── scripts/              # Build, test, audit, update, and release tooling
└── assets/               # Icons, fonts, wallpapers, metadata, and desktop files
```

## Communication

- **GitHub Discussions:** General questions, ideas, feedback
- **GitHub Issues:** Bugs, feature requests (tracked)
- **Discord/Matrix:** TBD (community chat)

## Recognition

All contributors are recognized in the release notes and in the repository's
[contributors graph](https://github.com/skyphoenix-it/skyphoenix-edgehub-linux/graphs/contributors),
which GitHub maintains automatically - a hand-kept `CONTRIBUTORS.md` was promised
here for months and never existed, so the promise is now one the repo can keep.

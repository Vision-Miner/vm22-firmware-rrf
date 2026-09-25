# Build system

This directory contains the build system for the Vision Miner firmware line,
based on RepRapFirmware 3.5.4 and maintained on the branch `visionminer-3.5`.

Firmware built from this branch reports a version of the form `3.5.4-vm.N`,
where `3.5.4` is the upstream RepRapFirmware release it is based on and `N`
increases with each Vision Miner release. The version is visible in the response
to `M115` and in Duet Web Control.

Supported host platforms: Linux x86_64 and macOS on Apple silicon
(`linux-x86_64`, `darwin-arm64`). Releases are built by CI on Linux.

## Requirements

These are installed on the machine, not by the build system:

| requirement                                 | used for                                                                      |
| ------------------------------------------- | ----------------------------------------------------------------------------- |
| Eclipse CDT                                 | the build engine; validated with Eclipse 4.40.0 (2026-06)                     |
| .NET 6 runtime                              | `CrcAppender`, which appends the checksum a board requires to accept firmware |
| Python 3                                    | `.uf2` targets only (Duet 3 Mini)                                             |
| git, make, curl or wget, tar, xz, sha256sum | fetching, unpacking and building                                              |

`build.sh doctor` reports which of these are missing or of an unexpected version.

The ARM compiler and the RepRapFirmware library sources are not system packages;
`build.sh bootstrap` installs them at the versions pinned in `repos.conf`, where
each toolchain archive is pinned once per host.

### macOS on Apple silicon

- **Command Line Tools** (`xcode-select --install`) provide `git` and `make`.
  Until they are installed, `/usr/bin/git` and `/usr/bin/make` are only stubs.
  `xz` and `sha256sum` are not needed: the system `tar` unpacks `.tar.xz` by
  itself, and checksums are computed with `shasum`.
- **Rosetta 2 and the x64 .NET 6 runtime.** `CrcAppender` is vendored for
  x86_64 only, so it runs under Rosetta 2 (`softwareupdate --install-rosetta`)
  and needs the **x64** .NET 6 runtime; the arm64 runtime does not satisfy it.
  The x64 runtime is installed apart from the arm64 one, under
  `/usr/local/share/dotnet/x64`. `doctor` looks there, in the location recorded
  in `/etc/dotnet/install_location_x64`, and in `$DOTNET_ROOT_X64`; the build
  passes the one it finds to `CrcAppender` as `DOTNET_ROOT_X64`.
- **Eclipse** is found in `tools/eclipse`, on `PATH`, or as `Eclipse.app` in
  `/Applications` or `~/Applications`. `bootstrap --with-eclipse` unpacks the
  pinned `Eclipse.app` into `tools/eclipse`.
- The WiFi-module firmware (`--with-wifi-fw`) cannot be built on this host: no
  Xtensa toolchain is pinned for it.

A `release-build` on macOS runs the same checks as on Linux, but uses the Arm
compiler built for macOS. The same compiler release built for another host is
expected to produce the same code, but byte-identity with the binaries CI
publishes has not been verified; compare checksums before relying on it.

## Setting up

```sh
git clone https://github.com/Vision-Miner/RepRapFirmware.git
cd RepRapFirmware
./Tools/vm-build/build.sh doctor
./Tools/vm-build/build.sh bootstrap
./Tools/vm-build/build.sh build
```

`bootstrap` downloads ARM GCC 12.2.1, clones the five Duet3D library
repositories at their pinned commits, and installs CrcAppender. It needs roughly
1.5 GB of disk and is run once per machine.

### Where files are placed

The firmware repository is the only checkout made by hand. Everything else is
placed in a workspace directory beside it:

```
<workspace>/
├── tools/          ARM GCC, CrcAppender
├── repos/          CoreN2G, RRFLibraries, CANlib, FreeRTOS, WiFiSocketServerRTOS
└── .eclipse-ws/    Eclipse metadata
```

The workspace is the value of `$RRF_WS` when set; otherwise, when the repository
is located at `<ws>/repos/RepRapFirmware`, that `<ws>`; otherwise
`vm-rrf-workspace/` next to the repository. `build.sh doctor` prints the
resolved paths.

The workspace is kept outside the repository because Eclipse imports each
library as a separate project, and it does not support projects located inside
another project's directory, nor a workspace located inside an imported project.

Two checkouts can share one workspace by pointing `RRF_WS` at it.

## Building

```sh
./Tools/vm-build/build.sh targets              # list configured targets
./Tools/vm-build/build.sh build                # incremental build, default target
./Tools/vm-build/build.sh build Duet3_MB6XD    # a specific target
./Tools/vm-build/build.sh rebuild              # clean build, fresh Eclipse workspace
./Tools/vm-build/build.sh clean [--deps]       # remove build output
```

Binaries are written inside the repository, into a directory named after the
build configuration — for example `Duet3_MB6HC/Duet3Firmware_MB6HC.bin`. These
directories are ignored by git.

Build output is condensed to one line per action — `CXX src/Movement/DDA.cpp`,
`CC`, `AS`, `AR`, `CLEAN`, `LD`, `BIN`, `CRC` — because the makefiles Eclipse generates otherwise echo a
two-kilobyte command per source file, which buries compiler warnings. Warnings,
errors and anything else unrecognised are printed unchanged. `--verbose` (or
`V=1`) shows the raw output, and the complete log of every build is written to
`<workspace>/last-build.log` regardless.

`build` is incremental and is the normal command during development. `rebuild`
discards the Eclipse workspace first and is useful after changes to `.cproject`,
after moving between distant commits, or when a build failure has no obvious
cause. `clean --deps` additionally removes build output inside the library
repositories.

## Taking a fix from upstream

```sh
git fetch upstream
git log --oneline 3.5.4..upstream/3.5-dev
git cherry-pick <commit>
./Tools/vm-build/build.sh build
```

If a change requires a newer library, update both the `ref` and the expected
commit sha in `repos.conf` in the same commit as the code, then:

```sh
./Tools/vm-build/build.sh bootstrap --sync
./Tools/vm-build/build.sh doctor
```

`--sync` moves the library checkouts onto their pinned commits. A repository with
local modifications is reported and left untouched.

## Adding a build target

Add one line to `targets.conf`:

```
"Duet3Mini5plus|Duet3Firmware_Mini5plus|uf2|Duet 3 Mini 5+ (SAME54)"
```

The fields are the Eclipse configuration name, the artifact base name as defined
in `.cproject`, the file extensions that are published for that board, and a
description. Several examples are present as comments.

## Versions and releases

The version is stored in `src/Version.h` as `MAIN_VERSION` and is changed by
editing that file. Each release is a commit that changes the version, tagged with
the version itself. Tags carry no `v` prefix, matching the upstream Duet3D
convention (`3.5.4`, `3.6.3`).

```sh
# edit src/Version.h: MAIN_VERSION → "3.5.4-vm.2"
git commit -am "Version 3.5.4-vm.2"
git push origin visionminer-3.5
git tag 3.5.4-vm.2
git push origin 3.5.4-vm.2
```

Pushing the tag is what starts a release. The `Release` workflow checks the tag
against `src/Version.h`, builds it, and opens a **draft** release with the
firmware and its linker map attached. The description is GitHub's generated list
of changes since the previous release; write the human part into the draft and
publish it when it reads the way you want.

The same build can be reproduced locally at any time:

```sh
git checkout 3.5.4-vm.2
./Tools/vm-build/build.sh release-build
```

`release-build` stops before compiling if the working tree has uncommitted
changes, if a library is not at its pinned commit, if the compiler is not the
pinned one, or if `src/Version.h` disagrees with the tag being built.

It also sets the compilation date and time from the date of the commit, rather
than from the clock. RepRapFirmware embeds both in the binary and reports them
in `M115`, so this makes a release binary depend only on its source: building the
same tag twice produces identical files.

To confirm that a published binary corresponds to its tag, rebuild it and compare
checksums — `release-build` prints the sha256 of every artifact it produces.

Moving the line onto a newer upstream release means changing `VM_VERSION_BASE`
and the library pins in `repos.conf` together with the code.

## Troubleshooting

```sh
./Tools/vm-build/build.sh doctor        # paths, tools, library pins, current version
./Tools/vm-build/build.sh rebuild       # rebuild from a fresh Eclipse workspace
./Tools/vm-build/build.sh clean --deps  # remove all build output, including libraries
```

`doctor` exits with a non-zero status when something needs attention, so it can
also be used as a pre-flight check in scripts.

Eclipse must not be started without `-application`: doing so opens the
workspace-selection dialog and waits for input. `build.sh` always passes it.

## Reference

### Files

| file                  | purpose                                                                   |
| --------------------- | ------------------------------------------------------------------------- |
| `build.sh`            | all build commands                                                        |
| `repos.conf`          | pinned library repositories, per-host toolchain archives and version base |
| `targets.conf`        | build targets and their published artifacts                               |
| `check-version.sh`    | verifies that a tag matches `src/Version.h`                               |
| `completion/_vmbuild` | zsh completion (see below)                                                |

### Shell completion

`completion/_vmbuild` completes commands and target names in zsh. It applies when
`build.sh` is invoked through its path, so it does not interfere with other
scripts that happen to be named `build.sh`.

Copy it into any directory zsh reads completions from. The usual location for
locally installed tools is `/usr/local/share/zsh/site-functions`:

```sh
sudo install -m 644 Tools/vm-build/completion/_vmbuild /usr/local/share/zsh/site-functions/
rm -f ~/.zcompdump && exec zsh
```

`print -l $fpath` lists the directories your shell reads; a personal one works
just as well. Removing `~/.zcompdump` is what makes zsh notice the new file — it
caches the list of available completions.

### Environment variables

| variable          | effect                                               |
| ----------------- | ---------------------------------------------------- |
| `RRF_WS`          | workspace location                                   |
| `RRF_ALLOW_DIRTY` | permits `release-build` from a modified working tree |
| `DOTNET_ROOT_X64` | macOS: location of the x64 .NET 6 runtime            |
| `NO_COLOR`        | plain output                                         |

## Current status

GitHub disables Actions in a forked repository until they are enabled by hand in
Settings → Actions; until that is done, pushing a tag builds nothing.

The Xtensa toolchain has no pinned checksum, because Espressif publish none next
to the archive — `bootstrap` prints the checksum of what it downloaded so it can
be pinned deliberately. It is only used for the WiFi-module firmware, which no
current target needs.

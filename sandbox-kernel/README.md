# Sandbox kernel kit

Builds the `restrict_syscalls()` syscall filter (see `../docs/SANDBOX.md`)
into the kernel and libroot of the Haiku or Renku system you run it on. The
result is a replacement `haiku` system package. With it installed, R
Chromium's renderers drop root and also give up every syscall group except
`BASIC` and `FILE_READ`. Without it they only drop root.

Everything happens on the Haiku machine itself. You need network access and
about 3 GB free in your home folder.

```sh
unzip rchromium-sandbox-kernel.zip        # or: tar xzf ...tar.gz
cd sandbox-kernel
./build-sandbox-kernel.sh                 # fetch the source, patch, build, package
./build-sandbox-kernel.sh install         # pkgman install; takes effect at the next boot
# reboot
./build-sandbox-kernel.sh test            # runs syscall_filter_test: 9 cases, all should pass
```

Then start R Chromium as usual. Each renderer's log should no longer say
`no restrict_syscalls() on this system`.

To go back, run `./build-sandbox-kernel.sh restore` and reboot. If the new
kernel does not boot at all, hold Shift (or Space) while the machine starts,
then choose *Select safe mode options* → *Select system state* and pick the
state from before the install.

## What it does

1. Reads the active `haiku-*.hpkg` and works out which source revision it was
   built from. The package version holds `git describe`:
   `r1~beta6_hrev60072_339` means 339 commits past `hrev60072`. A stock
   nightly is a tag (`hrev59866`). A release or Renku build is that many
   commits along the first-parent line of `r1betaN` or Renku's `main`. Only
   commit history is fetched for this step, not files.
2. Fetches that one commit at depth 1. Then it applies whichever patch in
   `patches/` fits:
   - `r1beta6-and-later/`: R1/beta6, current Haiku master, Renku. This is
     the patch in RenkuOS/Source#186.
   - `r1beta5/`: a backport to R1/beta5, where the team's thread and
     dead-thread lists are a different type.
3. Configures with the system's own compiler (primary architecture only) and
   builds `<revisioned>kernel_<arch>`, `<revisioned>libroot.so` and
   `syscall_filter_test`. The revision string is set to the installed one, so
   `uname -v` does not change.
4. Copies the original package to `~/sandbox-kernel-work/out/original/`,
   then writes a copy with only `kernel_<arch>` and `lib/libroot.so`
   replaced. Its revision goes up by one and its summary is marked. What it
   *provides* is left unchanged, so `haiku_devel` and the rest still resolve.

Missing build tools (`git jam gcc gcc_syslibs_devel zlib_devel zstd_devel bison flex wget python3 nasm`) are installed with
pkgman after asking first; `--yes` skips the question.

## Options

| | |
|---|---|
| `--workdir DIR` | sources, objects and output (default `~/sandbox-kernel-work`) |
| `--source DIR` | use your own checkout of the matching revision |
| `--rev COMMIT --repo URL` | skip the revision lookup |
| `--renku` / `--haiku` | if the project guess is wrong (it checks pkgman's repositories) |
| `--jobs N` | jam parallelism |
| `--force` | build on an architecture without the filter |

`./build-sandbox-kernel.sh resolve <version>` only prints the commit. It works
on any machine with git, e.g. `resolve 'r1~beta6_hrev60072_339-1' --renku`.

## What has been checked, and what has not

- The patches apply to R1/beta5 (`hrev57937`), R1/beta6 (`hrev59866`),
  `hrev60072`, Renku `main` and Haiku master as of 2026-10-27. The kernel,
  libroot and test **compile** on all of them (cross-built on Linux).
- Booted and tested: Renku build00062 x86_64 only. On that build,
  `syscall_filter_test` passes 9/9 and R Chromium renders sandboxed.
- The R1/beta5 backport has been built but never booted.
- arm64 and riscv64 check the filter in `syscall_dispatcher()`, but neither
  has been booted with it. 32-bit x86 has no filter, so `restrict_syscalls()`
  returns `B_NOT_SUPPORTED` there.
- Haiku older than R1/beta5: no patch fits.
- A locally built system whose version does not come from a tagged tree
  cannot be resolved; pass `--rev`.

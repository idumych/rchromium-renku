# R Chromium -- arm64 (AArch64)

**English** | [日本語](README.ja.md) | [한국어](README.ko.md)

Chromium running natively on Haiku/AArch64 -- Apple Silicon and other arm64
machines -- with a BeAPI toolbar: back/forward/reload, an address field, and
bookmarks. Noto Sans CJK, Noto Sans Arabic and Noto Color Emoji are bundled,
so Korean, Japanese, Chinese and Arabic pages, and colour emoji, render
without extra fonts. It runs on the RENKU arm64 image (Haiku arm64 with the TLSDESC
loader patch); stock Haiku arm64 images cannot load it.

![R Chromium rendering news.naver.com on the Haiku arm64 desktop](docs/images/screenshot-naver.png)

## x86_64 test preview

[Preview 1](https://github.com/idumych/rchromium-renku/releases/tag/preview-1)
is an x86_64 build for RenkuOS/Haiku with extensions (Brave Shields bundled),
sandboxed renderers, and Arabic and colour emoji fonts. Install
`rchromium-154.0.8036.0-1-x86_64.hpkg` with `pkgman install`.

The optional kernel package in the same release, which adds the syscall filter
from [RenkuOS/Source#186](https://github.com/RenkuOS/Source/pull/186), is built
against **RenkuOS nightly build00062** and only fits that exact build. RenkuOS's
nightly release keeps only the latest build, so build00062 is mirrored here,
unmodified, with RenkuOS's own checksum file:
[RenkuOS-x86_64-20261025-build00062.iso](https://github.com/idumych/rchromium-renku/releases/download/preview-1/RenkuOS-x86_64-20261025-build00062.iso)
([.sha256](https://github.com/idumych/rchromium-renku/releases/download/preview-1/RenkuOS-x86_64-20261025-build00062.iso.sha256)).
The release notes explain how to install it and how to undo it.

## Install with pkgman

R Chromium is published in the `pkgman.rainygirl.com` package repository.
Open Terminal on the device:

```sh
pkgman add-repo https://pkgman.rainygirl.com/arm64
pkgman add-repo https://pkgman.rainygirl.com/arm64-system
pkgman install rchromium
```

On a **RENKU image built with the renku-arm64 patch set** the system package
already carries the fixes (it provides `haiku_rchromium_fixes`), so skip
`arm64-system`: `pkgman install rchromium` is all it takes, with no reboot.
Adding `arm64-system` there would replace the system package with one that has
no media stack.

On other arm64 systems, then **reboot**. R Chromium needs two fixes in the kernel and the runtime
loader that the RenkuOS nightly arm64 image does not carry yet (the TLSDESC
loader patch and the `query-valid-pte` kernel patch). The `arm64-system`
repository publishes a `haiku` system package with both; `pkgman install
rchromium` pulls it in as a dependency, and it takes effect on the next boot.
Until then R Chromium exits with `Troubles relocating: Bad data` or panics the
kernel.

The package is about 150 MB; keep that much free on `/boot`. It installs into
`/boot/system/apps/RChromium/`, adds **R Chromium** to
**Deskbar -> Applications**, and adds an `rchromium` command. Remove it with
`pkgman uninstall rchromium`.

If `pkgman add-repo` fails with `Operation not supported`, the image was built
without TLS support in its network kit (the RenkuOS nightly minimum image is).
Set the clock first -- that image boots at 1970-01-01 -- and use the HTTP
address instead:

```sh
date -u 091612002026        # MMDDhhmmYYYY, the current UTC time
yes | pkgman add-repo http://pkgman.rainygirl.com/arm64
yes | pkgman add-repo http://pkgman.rainygirl.com/arm64-system
pkgman install rchromium
```

and reboot afterwards. The clock is lost again on every boot of that image;
set it before starting R Chromium or every HTTPS site fails with
`ERR_CERT_DATE_INVALID`.

`yes |` answers the "overwrite?" question pkgman asks when a failed HTTPS
attempt left a repository entry behind.

## Install with the installer script

`install.sh` does the same as the commands above -- sets the clock if it is
wrong, registers both repositories (falling back to HTTP when the image has no
TLS), installs `rchromium` and tells you to reboot when the system package was
replaced. It needs nothing but `sh`, `openssl` and `pkgman`, so it also works
on the minimum image. From a checkout:

```sh
sh install.sh
```

Without a checkout, fetch it with openssl (the minimum image has no curl, wget
or python3):

```sh
printf 'GET /rainygirl/renkuos-rchromium-arm64/main/install.sh HTTP/1.0\r\nHost: raw.githubusercontent.com\r\n\r\n' | openssl s_client -quiet -connect raw.githubusercontent.com:443 -servername raw.githubusercontent.com 2>/dev/null > /tmp/i.raw
{ while IFS= read -r l; do [ "$l" = $'\r' ] && break; done; cat; } < /tmp/i.raw > /tmp/install.sh
sh /tmp/install.sh
```

The old tarball path still exists as `sh install.sh --tarball` (delegates to
`install.py`, which needs python3); it unpacks the release into
`~/config/non-packaged/apps/RChromium/` without the kernel and loader fixes.

## Run

Double-click **R Chromium** on the Desktop, or pick it from
**Deskbar -> Applications**. From Terminal:

```sh
rchromium https://news.naver.com
```

- **Back / Forward / Reload** -- icon buttons on the left; Reload turns into Stop
  while a page is loading.
- **Address field** -- type a URL and press Enter; a bare `example.com` opens
  `https://example.com`.
- **Star** -- bookmarks the current page under a date group ("Today", ...).
- **Menu** -- opens a searchable bookmarks window; double-click an entry to
  open it.

## Uninstall

```sh
pkgman uninstall rchromium
```

or `sh install.sh --uninstall`. The patched `haiku` system package stays; it
is a superset of the stock one.

## AI disclosure

This program was written with Claude.

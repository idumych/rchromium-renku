// Copyright 2026 The RENKU project
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Haiku has no seccomp-bpf, no namespaces and no broker, so the renderer
// cannot be sandboxed the way it is on Linux. What it can do is stop being
// root. Every Haiku application runs as uid 0, and the kernel does check
// POSIX credentials, so a renderer that drops to an unprivileged uid before
// it touches web content (measured on R1/beta6 hrev59866):
//
//   can no longer                         can still
//   - write or create the user's files    - read world-readable files, which
//   - signal or kill other teams            on Haiku is most of the disk
//   - list or clone other teams' areas    - write to other teams' ports, so
//   - get root back (setuid(0) fails)       send BMessages to Tracker, the
//                                           registrar or app_server
//                                         - open network sockets
//
// That is a mitigation, not a sandbox: a compromised renderer can still
// escape by messaging another application. Closing that needs a per-team
// restriction in the kernel, which Haiku does not have yet.
//
// Nothing the renderer does after this needs root: its pak, ICU and V8 files
// arrive as descriptors or are world-readable, fonts are read-only files
// (HaikuFontMgr), shared memory is a temp file in $TMPDIR or the
// world-writable /tmp, and IPC runs over the descriptors it inherited.
// --no-sandbox skips all of this, as on every platform.

#include "content/renderer/renderer_main_platform_delegate.h"

#include <grp.h>
#include <unistd.h>

#include "base/check.h"
#include "base/check_op.h"
#include "base/logging.h"

namespace content {

namespace {

// "nobody" on most systems. Haiku has no user database to look it up in,
// and needs none: the kernel only compares numbers. Nothing on a Haiku
// system is owned by this uid or group, so the renderer owns no file.
constexpr uid_t kRendererUid = 65534;
constexpr gid_t kRendererGid = 65534;

}  // namespace

RendererMainPlatformDelegate::RendererMainPlatformDelegate(
    const MainFunctionParams& parameters) {}

RendererMainPlatformDelegate::~RendererMainPlatformDelegate() = default;

void RendererMainPlatformDelegate::PlatformInitialize() {}

void RendererMainPlatformDelegate::PlatformUninitialize() {}

bool RendererMainPlatformDelegate::EnableSandbox() {
  if (geteuid() != 0) {
    // A multi-user Haiku, or a browser started by a non-root user: there is
    // nothing to drop to that would take rights away from the user, and
    // setuid() would fail anyway. Say so rather than claim a sandbox.
    LOG(WARNING) << "renderer not root (euid " << geteuid()
                 << "), keeping the user's rights";
    return true;
  }

  // Credentials are per team on Haiku, so this covers the threads the
  // renderer already has (the IO thread, the thread pool). Groups first:
  // once the uid is gone there is no right to change them. Any failure is
  // fatal -- a renderer that believes it dropped root and did not is worse
  // than none.
  PCHECK(setgroups(0, nullptr) == 0) << "setgroups";
  PCHECK(setgid(kRendererGid) == 0) << "setgid";
  PCHECK(setuid(kRendererUid) == 0) << "setuid";
  CHECK_EQ(getuid(), kRendererUid);
  CHECK_EQ(geteuid(), kRendererUid);
  CHECK_EQ(getgid(), kRendererGid);
  CHECK_EQ(getegid(), kRendererGid);
  CHECK_NE(setuid(0), 0) << "root could be regained";

  // The browser's working directory is the app directory, which the
  // renderer has no reason to keep a handle on.
  PCHECK(chdir("/") == 0);
  return true;
}

}  // namespace content

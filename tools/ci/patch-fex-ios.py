#!/usr/bin/env python3
"""Make the pinned FEX compile for the iOS-native FEXCore the app links.

FEXCore/Source/Interface/Core/Core.cpp reports two Windows-module probes
([ffs-bypass], [cb-entry]) from CompileBlock. Their buffers, IosFfsBypassLog and
IosCbEntryLog, are declared only under FEX_IOS_HOST (the arm64ec and WOW64
modules), but the reports themselves are not guarded, so the iOS build
(build/fex-ios/build.sh, no FEX_IOS_HOST) stops with "use of undeclared
identifier". Both blocks are diagnostics only; wrap them in the same guard.
Idempotent; refuses if the text it keys on is not found.

Utils/ArchHelpers/Arm64.cpp: IosLogUnimplementedCASPAL describes the faulting
region with VirtualQuery, a Windows API; the iOS build gets the report without
the region columns.

usage: patch-fex-ios.py <FEX checkout>
"""
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "FEX"


def guard(rel, start, end_after, cond, label):
    """Wrap [start, end of end_after] in #if cond ... #endif. end_after is included."""
    path = os.path.join(root, rel)
    src = open(path, encoding="utf-8").read()
    mark = "#if %s /* tools/ci/patch-fex-ios.py: %s */\n" % (cond, label)
    if mark in src:
        print("%s: %s already patched" % (rel, label))
        return
    if src.count(start) != 1 or src.count(end_after) != 1 or src.index(start) > src.index(end_after):
        sys.exit("%s: %s not found as expected; FEX changed, revisit the patch" % (rel, label))
    end = src.index(end_after) + len(end_after)
    src = src[:end] + "#endif /* %s */\n" % cond + src[end:]
    src = src.replace(start, mark + start, 1)
    open(path, "w", encoding="utf-8", newline="").write(src)
    print("%s: %s guarded by %s" % (rel, label, cond))


guard("FEXCore/Source/Interface/Core/Core.cpp",
      "  /* iOS-Madeira ml304 (task #51): REPORT CallbackPtr ENTRY ON ITS OWN",
      "                        IosCbEntryLog[4], IosCbEntryLog[5], IosCbEntryLog[7]);\n    }\n  }\n",
      "defined(FEX_IOS_HOST)", "[ffs-bypass]/[cb-entry] reports")

guard("FEXCore/Source/Utils/ArchHelpers/Arm64.cpp",
      "  MEMORY_BASIC_INFORMATION mbi {};\n",
      "                    mbi.Protect, type, mbi.State);\n",
      "defined(_WIN32)", "[caspal128] VirtualQuery report")

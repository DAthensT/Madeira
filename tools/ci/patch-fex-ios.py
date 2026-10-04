#!/usr/bin/env python3
"""Make the pinned FEX compile for the iOS-native FEXCore the app links.

FEXCore/Source/Interface/Core/Core.cpp reports two Windows-module probes
([ffs-bypass], [cb-entry]) from CompileBlock. Their buffers, IosFfsBypassLog and
IosCbEntryLog, are declared only under FEX_IOS_HOST (the arm64ec and WOW64
modules), but the reports themselves are not guarded, so the iOS build
(build/fex-ios/build.sh, no FEX_IOS_HOST) stops with "use of undeclared
identifier". Both blocks are diagnostics only; wrap them in the same guard.
Idempotent; refuses if the text it keys on is not found.
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "FEX/FEXCore/Source/Interface/Core/Core.cpp"
src = open(path, encoding="utf-8").read()
START = "  /* iOS-Madeira ml304 (task #51): REPORT CallbackPtr ENTRY ON ITS OWN"
END = "  /* iOS-Madeira: refuse to compile obviously-invalid guest RIPs."
MARK = "#ifdef FEX_IOS_HOST /* tools/ci/patch-fex-ios.py */\n"

if MARK in src:
    print("Core.cpp: already patched")
    sys.exit(0)
if src.count(START) != 1 or src.count(END) != 1 or src.index(START) > src.index(END):
    sys.exit("Core.cpp: probe blocks not found as expected; FEX changed, revisit the patch")
src = src.replace(START, MARK + START, 1)
src = src.replace(END, "#endif /* FEX_IOS_HOST */\n\n" + END, 1)
open(path, "w", encoding="utf-8", newline="").write(src)
print("Core.cpp: [ffs-bypass]/[cb-entry] reports guarded by FEX_IOS_HOST")

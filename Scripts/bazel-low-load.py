#!/usr/bin/env python3
"""Make.py Bazel wrapper. Run from the patched Telegram checkout on Apple Silicon."""
import json
import os
from pathlib import Path
import sys


def arguments(args):
    if args == ["--version"]:
        return args
    if args and args[0] == "build":
        previous = None
        result = []
        prefix = "--@build_bazel_rules_swift//swift:copt="
        for arg in args:
            if arg.startswith(prefix):
                value = arg[len(prefix):].strip('"')
                if previous == "-j":
                    arg = prefix + '"1"'
                previous = value
            result.append(arg)
        args = result + ["--jobs=1", "--//Telegram:disableExtensions",
                         "--//Telegram:disableProvisioningProfiles",
                         "--noremote_upload_local_results"]
    return ["--host_jvm_args=-XX:ActiveProcessorCount=2"] + args


if __name__ == "__main__":
    root = Path.cwd()
    version = json.loads((root / "versions.json").read_text())["bazel"].split(":")[0]
    binary = root / "build-input" / ("bazel-" + version + "-darwin-arm64")
    if not binary.is_file():
        sys.exit("Bazel binary missing. Generate the project with Make.py first.")
    os.execv(str(binary), [str(binary)] + arguments(sys.argv[1:]))

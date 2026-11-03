#!/usr/bin/env python3
"""Bounded source/build/resource checks; does not claim to compile an iOS target."""
import argparse
import ast
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MODULES = [
    "submodules/TelegramEnvelopes",
    "submodules/TelegramUI/Components/Envelopes/EnvelopeRendering",
    "submodules/TelegramUI/Components/Envelopes/EnvelopeDemoScreen",
    "submodules/TelegramUI/Components/Chat/ChatMessageEnvelopeBubbleContentNode",
]
CHECKS = []


def check(condition, message):
    if not condition:
        raise SystemExit("FAIL: " + message)
    CHECKS.append(message)


def targets(package):
    for filename in ("BUILD", "BUILD.bazel"):
        path = ROOT / package / filename
        if path.is_file():
            tree = ast.parse(path.read_text(), filename=str(path))
            result = {}
            for call in ast.walk(tree):
                if not isinstance(call, ast.Call):
                    continue
                fields = {key.arg: key.value for key in call.keywords}
                name = fields.get("name")
                if isinstance(name, ast.Constant) and isinstance(name.value, str):
                    deps = fields.get("deps")
                    result[name.value] = [node.value for node in ast.walk(deps) if isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value.startswith(("//", ":"))] if deps else []
            return result
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", help="Optional swiftc path for syntax parsing, not SDK type checking")
    args = parser.parse_args()
    modules = {Path(path).name: path for path in MODULES}
    modules.update({"SwiftSignalKit": "submodules/SSignalKit/SwiftSignalKit", "LottieSettings": "submodules/LottieSettings"})
    for name in ("ChatMessageBubbleContentNode", "ChatMessageItemCommon"):
        modules[name] = "submodules/TelegramUI/Components/Chat/" + name
    sources = []
    for path in MODULES:
        name = Path(path).name
        declared = targets(path)
        check(name in declared, name + " has a Bazel library")
        # Bazel's implicit module name includes the package path. SwiftPM's name
        # does not; model tests alone cannot catch an iOS import mismatch.
        build_tree = ast.parse((ROOT / path / "BUILD").read_text())
        explicit_names = []
        for call in ast.walk(build_tree):
            if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == "swift_library":
                fields = {field.arg: field.value for field in call.keywords}
                module = fields.get("module_name")
                if isinstance(module, ast.Constant):
                    explicit_names.append(module.value)
        check(name in explicit_names, name + " exports the module name imported by iOS")
        deps = declared[name]
        for dependency in deps:
            package, _, target = dependency.removeprefix("//").partition(":")
            target = target or Path(package).name
            check(target in targets(package), name + " dependency exists: " + dependency)
        for source in sorted((ROOT / path / "Sources").glob("*.swift")):
            sources.append(source)
            text = source.read_text()
            for imported in re.findall(r"^import (\w+)$", text, re.M):
                if imported in ("Foundation", "UIKit"):
                    continue
                package = modules.get(imported, "submodules/" + imported)
                check(any(dep.split(":")[0] == "//" + package for dep in deps), source.name + " declares " + imported)
            check(not re.search(r"\.engine\.payments|\.walletContext", text), source.name + " does not transfer real wallet funds")

    # Detect a cycle introduced by a new module, following declared local dependency edges.
    cache = {}
    def visit(label, stack, done):
        if label in done:
            return
        check(label not in stack, "dependency graph is acyclic at " + label) if label in stack else None
        stack.add(label)
        package, _, name = label.removeprefix("//").partition(":")
        name = name or Path(package).name
        declarations = cache.setdefault(package, targets(package))
        for dep in declarations.get(name, []):
            dep = "//" + package + dep if dep.startswith(":") else dep
            dep_package, _, dep_name = dep.removeprefix("//").partition(":")
            visit("//" + dep_package + ":" + (dep_name or Path(dep_package).name), stack, done)
        stack.remove(label)
        done.add(label)
    done = set()
    for path in MODULES:
        visit("//" + path + ":" + Path(path).name, set(), done)
    check(True, f"local dependency graph traversed ({len(done)} targets)")

    spec = importlib.util.spec_from_file_location("generate_strings", ROOT / "build-system/GenerateStrings/GenerateStrings.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    english = generator.parse_strings(str(ROOT / "Telegram/Telegram-iOS/en.lproj/Localizable.strings"))
    russian = generator.parse_strings(str(ROOT / "Telegram/Telegram-iOS/ru.lproj/Envelope.strings"))
    # Use the repository's actual parser, including its escaping rules.
    en_keys = [entry["key"] for entry in english if entry["key"].startswith("EnvelopeDemo.")]
    ru_keys = [entry["key"] for entry in russian]
    check(len(en_keys) == len(set(en_keys)) and set(en_keys) == set(ru_keys) and len(ru_keys) == len(set(ru_keys)), f"English/Russian keys match ({len(en_keys)} keys, no duplicates)")
    resource = "Telegram-iOS/ru.lproj/Envelope.strings"
    check(resource in (ROOT / "Telegram/BUILD").read_text(), "Russian fallback ships in AppStringResources")
    asset = ROOT / "submodules/TelegramUI/Images.xcassets/Chat/Attach Menu/EnvelopeDemo.imageset"
    contents = json.loads((asset / "Contents.json").read_text())
    for item in contents["images"]:
        check((asset / item["filename"]).read_bytes().startswith(b"%PDF-"), "vector attachment asset exists")
    with tempfile.TemporaryDirectory(prefix="envelopes-strings-") as temp:
        subprocess.run(["python3", str(ROOT / "build-system/GenerateStrings/GenerateStrings.py"), "--source", str(ROOT / "Telegram/Telegram-iOS/en.lproj/Localizable.strings"), "--outHeader", temp + "/PresentationStrings.h", "--outImplementation", temp + "/PresentationStrings.m", "--outData", temp + "/PresentationStrings.data"], check=True, stdout=subprocess.DEVNULL)
    check(True, "Telegram localization generator succeeded")
    if args.swiftc:
        sources += [ROOT / "submodules/AttachmentUI/Sources/AttachmentController.swift", ROOT / "submodules/AttachmentUI/Sources/AttachmentPanel.swift", ROOT / "submodules/TelegramUI/Sources/ChatControllerOpenAttachmentMenu.swift", ROOT / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift"]
        subprocess.run([args.swiftc, "-frontend", "-parse"] + list(map(str, sources)), check=True)
        check(True, f"Swift syntax parsed ({len(sources)} files); UIKit/SDK types remain unverified")
    print(f"PASS: {len(CHECKS)} static checks; {len(done)} local dependency targets; {len(en_keys)} bilingual strings")
    if args.swiftc:
        print(f"PASS: Swift syntax parsed in {len(sources)} files. This is not iOS SDK type checking or an app build.")


if __name__ == "__main__":
    main()

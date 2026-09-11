#!/usr/bin/env python3
"""Register a Shared/ source file with both Xcode targets.

App/, CLI/ and Tests/ are file-system synchronized groups, so files added there
are picked up automatically. Shared/ is a plain group whose members each need an
explicit file reference, a build file per target, a group child, and an entry in
each target's Sources phase. Adding a Shared file by hand means five edits in
four places, which is exactly the kind of thing that gets half done.

Usage: Scripts/add_shared_source.py NewType.swift [AnotherType.swift ...]

Idempotent: a file that is already registered is reported and left alone.
"""

import pathlib
import re
import sys

PROJECT = pathlib.Path(__file__).resolve().parent.parent / "Apple Core.xcodeproj" / "project.pbxproj"
SHARED_GROUP = "AC0000010000000000000010"
# Sources phases, in the order they appear: the test target, then the app.
TEST_SOURCES_ANCHOR = "AC0000010000000000000031 /* FilesystemAccess.swift in Sources */,"
APP_SOURCES_ANCHOR = "AC0000010000000000000032 /* FilesystemAccess.swift in Sources */,"
GROUP_ANCHOR = "AC0000010000000000000030 /* FilesystemAccess.swift */,"


def next_identifiers(text, count):
    used = sorted(set(re.findall(r"AC000001[0-9A-F]{16}", text)))
    highest = int(used[-1][8:], 16)
    return [f"AC000001{highest + n:016X}" for n in range(1, count + 1)]


def register(text, name):
    if f"path = {name}" in text:
        return text, False

    file_ref, app_build, test_build = next_identifiers(text, 3)

    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{test_build} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};\n"
        f"\t\t{app_build} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};\n",
        1,
    )
    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        f"\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n',
        1,
    )
    text = text.replace(
        GROUP_ANCHOR,
        f"{GROUP_ANCHOR}\n\t\t\t\t{file_ref} /* {name} */,",
        1,
    )
    text = text.replace(
        TEST_SOURCES_ANCHOR,
        f"{TEST_SOURCES_ANCHOR}\n\t\t\t\t{test_build} /* {name} in Sources */,",
        1,
    )
    text = text.replace(
        APP_SOURCES_ANCHOR,
        f"{APP_SOURCES_ANCHOR}\n\t\t\t\t{app_build} /* {name} in Sources */,",
        1,
    )
    return text, True


def main(names):
    if not names:
        print(__doc__)
        return 1
    text = PROJECT.read_text()
    for name in names:
        if not (PROJECT.parent.parent / "Shared" / name).exists():
            print(f"Shared/{name} does not exist")
            return 1
        text, added = register(text, name)
        print(f"{'registered' if added else 'already registered'}: Shared/{name}")
    PROJECT.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

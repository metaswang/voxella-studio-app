#!/usr/bin/env python3

import argparse
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


@dataclass(frozen=True, order=True)
class ReleaseVersion:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, value: str) -> "ReleaseVersion":
        match = VERSION_PATTERN.fullmatch(value)
        if match is None:
            raise ValueError(f"version must be X.Y.Z without leading zeros: {value}")
        return cls(*(int(component) for component in match.groups()))


@dataclass(frozen=True)
class PublishedRelease:
    version: ReleaseVersion
    build: int


def latest_published_release(appcast_path: Path) -> PublishedRelease:
    root = ET.parse(appcast_path).getroot()
    releases: list[PublishedRelease] = []
    for item in root.findall("./channel/item"):
        build_text = item.findtext(f"{{{SPARKLE_NAMESPACE}}}version")
        version_text = item.findtext(f"{{{SPARKLE_NAMESPACE}}}shortVersionString")
        if build_text is None or version_text is None:
            continue
        if not build_text.isdigit() or int(build_text) <= 0:
            raise ValueError(f"invalid published build number: {build_text}")
        releases.append(PublishedRelease(ReleaseVersion.parse(version_text), int(build_text)))
    if not releases:
        raise ValueError("appcast contains no published releases")
    return PublishedRelease(
        version=max(release.version for release in releases),
        build=max(release.build for release in releases),
    )


def planned_build(
    requested: ReleaseVersion,
    current: ReleaseVersion,
    current_build: int,
    published: PublishedRelease,
) -> int:
    if current_build <= 0:
        raise ValueError("current build number must be a positive integer")
    if requested == current:
        if current_build <= published.build:
            raise ValueError("current build number is not newer than the published appcast")
        if requested <= published.version:
            raise ValueError("current version is not newer than the published appcast")
        return current_build
    if requested <= current or requested <= published.version:
        raise ValueError("release version must be newer than the current and published versions")
    return max(current_build, published.build) + 1


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("version")

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--requested", required=True)
    plan_parser.add_argument("--current", required=True)
    plan_parser.add_argument("--current-build", required=True, type=int)
    plan_parser.add_argument("--appcast", required=True, type=Path)

    arguments = parser.parse_args()
    try:
        if arguments.command == "validate":
            ReleaseVersion.parse(arguments.version)
            return

        published = latest_published_release(arguments.appcast)
        build = planned_build(
            requested=ReleaseVersion.parse(arguments.requested),
            current=ReleaseVersion.parse(arguments.current),
            current_build=arguments.current_build,
            published=published,
        )
        print(build)
    except (ET.ParseError, OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3

import collections
import json
import plistlib
import re
import sys
from pathlib import Path


SUPPORTED_LOCALES = (
    "en",
    "ko",
    "zh-Hans",
    "zh-Hant",
    "ja",
    "ru",
    "de",
    "fr",
    "es",
    "pt-BR",
)
TRANSLATED_LOCALES = SUPPORTED_LOCALES[1:]
CATALOG_PATH = Path(
    "app/Packages/SwitchyardLocalization/Resources/Localizable.xcstrings"
)
RESOURCE_ROOT = CATALOG_PATH.parent
PLACEHOLDER_PATTERN = re.compile(
    r"%(?:\d+\$)?(?:[-+0# ']*\d*(?:\.\d+)?)?"
    r"(?:hh|h|ll|l|L|z|j|t|q)?[@diuoxXfFeEgGaAcCsSp%]"
)
GENERATION_MARKER_PATTERN = re.compile(r"ZXQ(?:PH|TERM|SEP)")
REPRESENTATIVE_KEYS = (
    "Add Container",
    "Diagnostics",
    "Move to Trash",
    "Open in Finder",
    "Settings",
)


def source_value(key, entry):
    return (
        entry.get("localizations", {})
        .get("en", {})
        .get("stringUnit", {})
        .get("value", key)
    )


def positional_placeholders(text):
    index = 0
    placeholders = []
    for match in PLACEHOLDER_PATTERN.finditer(text):
        placeholder = match.group(0)
        if placeholder == "%%":
            continue
        positional_match = re.match(r"%(\d+)\$(.*)", placeholder)
        if positional_match:
            placeholders.append(
                f"%{positional_match.group(1)}${positional_match.group(2)}"
            )
            continue
        index += 1
        placeholders.append(f"%{index}${placeholder[1:]}")
    return collections.Counter(placeholders)


def fail(errors, message):
    errors.append(message)


def main():
    if not CATALOG_PATH.is_file():
        print(f"error: localization catalog is missing: {CATALOG_PATH}", file=sys.stderr)
        return 1

    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    errors = []
    if catalog.get("sourceLanguage") != "en":
        fail(errors, "sourceLanguage must be en")

    strings = catalog.get("strings")
    if not isinstance(strings, dict) or not strings:
        fail(errors, "the catalog must contain localized strings")
        strings = {}

    for key, entry in strings.items():
        source = source_value(key, entry)
        expected_placeholders = positional_placeholders(source)
        for locale in TRANSLATED_LOCALES:
            string_unit = (
                entry.get("localizations", {})
                .get(locale, {})
                .get("stringUnit")
            )
            if not isinstance(string_unit, dict):
                fail(errors, f"{locale}: missing translation for {key!r}")
                continue
            value = string_unit.get("value")
            if not isinstance(value, str) or not value.strip():
                fail(errors, f"{locale}: empty translation for {key!r}")
                continue
            if string_unit.get("state") != "translated":
                fail(errors, f"{locale}: translation is not marked translated for {key!r}")
            if GENERATION_MARKER_PATTERN.search(value):
                fail(errors, f"{locale}: generation marker remains in {key!r}")
            actual_placeholders = positional_placeholders(value)
            if actual_placeholders != expected_placeholders:
                fail(
                    errors,
                    f"{locale}: placeholder mismatch for {key!r}: "
                    f"expected {dict(expected_placeholders)}, "
                    f"found {dict(actual_placeholders)}",
                )

    for locale in TRANSLATED_LOCALES:
        for key in REPRESENTATIVE_KEYS:
            entry = strings.get(key, {})
            value = (
                entry.get("localizations", {})
                .get(locale, {})
                .get("stringUnit", {})
                .get("value")
            )
            if value == key:
                fail(errors, f"{locale}: representative key was left in English: {key!r}")

    for locale in TRANSLATED_LOCALES:
        strings_path = RESOURCE_ROOT / f"{locale}.lproj" / "Localizable.strings"
        if not strings_path.is_file():
            fail(errors, f"{locale}: generated Localizable.strings is missing")
            continue
        try:
            with strings_path.open("rb") as strings_file:
                generated_strings = plistlib.load(strings_file)
        except Exception as error:
            fail(errors, f"{locale}: generated strings file is invalid: {error}")
            continue
        expected_strings = {
            key: entry["localizations"][locale]["stringUnit"]["value"]
            for key, entry in strings.items()
        }
        if generated_strings != expected_strings:
            missing_keys = sorted(set(expected_strings) - set(generated_strings))
            extra_keys = sorted(set(generated_strings) - set(expected_strings))
            changed_keys = sorted(
                key
                for key in set(expected_strings) & set(generated_strings)
                if expected_strings[key] != generated_strings[key]
            )
            fail(
                errors,
                f"{locale}: generated strings are out of date "
                f"(missing={len(missing_keys)}, extra={len(extra_keys)}, "
                f"changed={len(changed_keys)})",
            )

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        print(
            f"Localization validation failed with {len(errors)} error(s).",
            file=sys.stderr,
        )
        return 1

    print(
        f"Validated {len(strings)} strings across "
        f"{len(SUPPORTED_LOCALES)} supported locales."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

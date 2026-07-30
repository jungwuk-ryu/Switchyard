import AppCore
import Testing

@Test func sourceEnvironmentFileUsesTheLastValidDuplicateAssignment() {
    let values = SourceEnvironmentFile.parse(
        """
        SWITCHYARD_WINE_REVISION=old
        SWITCHYARD_WINE_REVISION=new
        """
    )

    #expect(values["SWITCHYARD_WINE_REVISION"] == "new")
}

@Test func sourceEnvironmentFileIgnoresMalformedAssignments() {
    let values = SourceEnvironmentFile.parse(
        """
        # comment
          # indented comment
        MISSING_SEPARATOR
        =missing-key
        1INVALID=value
        INVALID-NAME=value
        VALID=
        VALUE_WITH_EQUALS=https://example.invalid/file?key=value
        """
    )

    #expect(values.count == 2)
    #expect(values["VALID"] == "")
    #expect(values["VALUE_WITH_EQUALS"] == "https://example.invalid/file?key=value")
}

@Test func sourceEnvironmentFileRejectsControlCharactersWithoutDroppingOtherValues() {
    let values = SourceEnvironmentFile.parse(
        """
        NUL=value\u{0}suffix
        TAB=value\tsuffix
        DEL=value\u{7f}suffix
        INJECTED_PREFIX=value\u{b}INJECTED=value
        SAFE=value
        """
    )

    #expect(values == ["SAFE": "value"])
}

@Test func sourceEnvironmentFileAcceptsCRLFLineEndings() {
    let values = SourceEnvironmentFile.parse("FIRST=one\r\nSECOND=two\r\n")

    #expect(values == ["FIRST": "one", "SECOND": "two"])
}

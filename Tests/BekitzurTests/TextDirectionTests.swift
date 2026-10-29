import BekitzurDomain
import Testing

struct TextDirectionTests {
    private func words(_ line: String) -> [Substring] {
        line.split(separator: " ")
    }

    @Test func aLineGoesTheWayMostOfItsWordsStart() {
        // Hebrew with long English terms: by letters it's mostly English.
        #expect(TextDirection.of(words("ה-deployment של ה-service ב-staging נפל"), fallback: .leftToRight) == .rightToLeft)
        #expect(TextDirection.of(words("We were all generalists, you know"), fallback: .rightToLeft) == .leftToRight)
        #expect(TextDirection.of(words("ok אז"), fallback: .rightToLeft) == .leftToRight)
        #expect(TextDirection.of(words("20 - 30"), fallback: .rightToLeft) == .rightToLeft)
    }

    @Test func englishWordsInAHebrewLineAreOneRunOnlyWhenThereAreSeveral() {
        #expect(TextDirection.runs(words("אני פותח pull request עכשיו"), in: .rightToLeft) == [nil, nil, 0, 0, nil])
        #expect(TextDirection.runs(words("אני אחפש את ה-jira שלך"), in: .rightToLeft) == [nil, nil, nil, nil, nil])
        #expect(TextDirection.runs(words("נעשה code review ואז merge request"), in: .rightToLeft) == [nil, 0, 0, nil, 1, 1])
    }

    @Test func aHebrewPrefixJoinsTheEnglishRunAfterIt() {
        #expect(TextDirection.runs(words("של ה-code review מחר"), in: .rightToLeft) == [nil, 0, 0, nil])
    }

    @Test func aWordWithoutLettersJoinsTheRunAroundIt() {
        #expect(TextDirection.runs(words("עברנו ל-version 2.3 release אתמול"), in: .rightToLeft) == [nil, 0, 0, 0, nil])
        #expect(TextDirection.runs(words("יש 20 issues"), in: .rightToLeft) == [nil, nil, nil])
    }

    @Test func aHebrewPhraseInAnEnglishLineIsARunToo() {
        #expect(TextDirection.runs(words("the הצעת מחיר is ready"), in: .leftToRight) == [nil, 0, 0, nil, nil])
    }

    @Test func eachRunIsPlacedBackwardsSoItReadsItsOwnWay() {
        #expect(TextDirection.placement([nil, nil, 0, 0, nil]) == [0, 1, 3, 2, 4])
        #expect(TextDirection.placement([0, 0, nil, 1, 1, 1]) == [1, 0, 2, 5, 4, 3])
        #expect(TextDirection.placement([nil, nil]) == [0, 1])
        // A run broken across two lines goes on from where the first line stopped.
        #expect(TextDirection.placement([nil, 0, 0]) == [0, 2, 1])
        #expect(TextDirection.placement([0, nil]) == [0, 1])
    }
}

import Foundation

@main struct CheckHelpCenter {
    enum Failure: Error { case assertion(String) }

    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure.assertion(label) }
            count += 1
        }
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: path)
        let catalog = try OathHelpArticleCatalog(data: data)
        let all = catalog.sections(matching: "").flatMap(\.articles)
        try check(all.count == catalog.articles.count && all.count == 131, "All 131 published articles are listed")
        try check(catalog.sections(matching: "").count == 9, "All nine collections are present")
        try check(Set(all.map(\.id)).count == all.count, "Every article appears once")
        for article in catalog.articles {
            try check(catalog.sections(matching: article.title).first?.articles.first?.id == article.id,
                      "Exact article title is the first result: " + article.id)
            try check(article.url.scheme == "https" && article.url.host == "help.oathwallet.org"
                && article.url.path == "/articles/" + article.id && article.url.query == nil,
                      "Canonical article link: " + article.id)
        }
        func matches(_ query: String, _ id: String) -> Bool {
            catalog.sections(matching: query).flatMap(\.articles).contains { $0.id == id }
        }
        try check(matches("FÁCE　ID", "enable-face-id"), "Case, accent and full-width whitespace folding")
        try check(matches("faceid", "enable-face-id"), "Compound spelling searches spaced text")
        try check(matches("How do I back up my wallet?", "backup-one-wallet"), "Natural question and separated backup words")
        try check(matches("  BIP–39  passphrase ", "add-passphrase"), "Mixed punctuation and multiple terms")
        try check(matches("Wallet Connect", "connect-dapp"), "Separated brand name")
        for network in ["Stellar", "XRP", "Solana", "TRON", "NEAR", "Gram", "TON"] {
            try check(matches(network + " activation", "account-activation-and-reserves"), "Activation guidance found by network")
        }
        try check(catalog.sections(matching: "zxqvnonexistenthelpterm").isEmpty, "No matching articles")
        try check(catalog.sections(matching: " \n— ! ").flatMap(\.articles).count == all.count, "Empty query restores all sections")

        let fixture: [String: Any] = ["version": 1,
            "categories": [["id": "wallets", "title": "Wallets"], ["id": "security", "title": "Security"]],
            "articles": [
                ["id": "alpha", "categoryID": "wallets", "title": "Create wallet", "summary": "A new account", "body": "Use a unique mnemonic for recovery."],
                ["id": "beta", "categoryID": "security", "title": "Recovery", "summary": "Keep an offline copy", "body": "Store words privately."]]]
        let sample = try OathHelpArticleCatalog(data: JSONSerialization.data(withJSONObject: fixture))
        try check(sample.sections(matching: "unique mnemonic").first?.articles.first?.id == "alpha", "Body-only match")
        try check(sample.sections(matching: "offline copy").first?.articles.first?.id == "beta", "Summary match")
        try check(sample.sections(matching: "security").first?.articles.first?.id == "beta", "Category match")
        try check(sample.sections(matching: "recovery").first?.articles.first?.id == "beta", "Title ranked above body-only match")
        try check(sample.sections(matching: "unique offline").isEmpty, "All search terms must match the same article")

        func reject(_ document: [String: Any]) throws {
            do {
                _ = try OathHelpArticleCatalog(data: JSONSerialization.data(withJSONObject: document))
                throw Failure.assertion("Accepted an invalid catalog")
            } catch is OathHelpArticleCatalog.CatalogError { count += 1 }
        }
        for id in ["../other", "https://example.com", "hello?token=1", "file%2fother", ""] {
            var invalid = fixture
            var entries = fixture["articles"] as! [[String: String]]
            entries[0]["id"] = id
            invalid["articles"] = entries
            try reject(invalid)
        }
        var duplicate = fixture
        let entries = fixture["articles"] as! [[String: String]]
        duplicate["articles"] = [entries[0], entries[0]]
        try reject(duplicate)
        var unknown = fixture
        unknown["categories"] = [["id": "unknown", "title": "Unknown"]]
        try reject(unknown)

        // Shared loading is independent of wallet state and survives one page
        // leaving. The immutable catalog remains usable without a second read.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = directory.appendingPathComponent("catalog.json")
        let store = OathHelpCatalogStore(resource: resource)
        do { _ = try await store.load(); throw Failure.assertion("Missing catalog should fail") }
        catch is CocoaError { count += 1 }
        try data.write(to: resource)
        async let first = store.load()
        async let second = store.load()
        let values = try await (first, second)
        try check(values.0.articles.count == all.count && values.1.articles.count == all.count, "Concurrent load and retry after failure")
        try FileManager.default.removeItem(at: resource)
        let cached = try await store.load()
        try check(cached.articles.count == all.count, "Reopening uses the cached catalog")

        if CommandLine.arguments.count > 2 {
            let translationURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let translationData = try Data(contentsOf: translationURL)
            let document = try JSONSerialization.jsonObject(with: translationData) as! [String: Any]
            let localizations = document["localizations"] as! [String: [String: String]]
            try check(localizations.count == 56 && localizations["en"] == nil, "Every non-English app language has translations")
            for (language, text) in localizations {
                let localized = try OathHelpArticleCatalog(data: data, translationsData: translationData, language: language)
                try check(localized.language == language, "Catalog is associated with requested language")
                try check(localized.sections(matching: "").flatMap(\.articles).map(\.id) == all.map(\.id), "Translation preserves article order")
                for (original, translated) in zip(catalog.articles, localized.articles) {
                    try check(translated.title == text["article." + original.id + ".title"]
                              && translated.summary == text["article." + original.id + ".summary"], "Translated article fields: " + language + "/" + original.id)
                    try check(original.url == translated.url && original.body == translated.body, "Published link and body preserved")
                    let exact = localized.sections(matching: translated.title).first?.articles.first
                    try check(exact?.title == translated.title, "Localized title wins search: " + language + "/" + original.id)
                }
                for category in localized.categories {
                    try check(category.title == text["category." + category.id], "Section heading translated")
                    try check(localized.sections(matching: category.title).contains { $0.id == category.id }, "Translated section searchable")
                }
                try check(localized.sections(matching: "Create your first wallet").first?.articles.first?.id == "create-wallet", "English queries still work in localized catalog")
            }
            let arabic = try OathHelpArticleCatalog(data: data, translationsData: translationData, language: "ar")
            try check(arabic.sections(matching: "المحفظة").isEmpty == false, "Arabic search returns articles")
            try check(arabic.sections(matching: "النسخ الاحتياطي").contains { $0.id == "backup" }, "Arabic backup search")

            func rejectTranslations(_ changed: [String: Any], language: String = "ar") throws {
                do {
                    _ = try OathHelpArticleCatalog(data: data, translationsData: JSONSerialization.data(withJSONObject: changed), language: language)
                    throw Failure.assertion("Accepted incomplete or stale translations")
                } catch is OathHelpArticleCatalog.CatalogError { count += 1 }
            }
            var invalid = document
            invalid["source"] = ["obsolete": "Old heading"]
            try rejectTranslations(invalid)
            invalid = document
            var incomplete = localizations
            incomplete["ar"]?.removeValue(forKey: "article.create-wallet.summary")
            invalid["localizations"] = incomplete
            try rejectTranslations(invalid)
            incomplete = localizations
            incomplete["ar"]?["article.create-wallet.title"] = " \n "
            invalid["localizations"] = incomplete
            try rejectTranslations(invalid)
            try rejectTranslations(document, language: "unsupported")

            // Independent language caches must not return the last opened
            // language, including concurrent loads and returning to English.
            try data.write(to: resource)
            let translatedResource = directory.appendingPathComponent("translations.json")
            try translationData.write(to: translatedResource)
            let languageStore = OathHelpCatalogStore(resource: resource, translationsResource: translatedResource)
            async let ar = languageStore.load(language: "ar")
            async let fr = languageStore.load(language: "fr")
            let pair = try await (ar, fr)
            try check(pair.0.articles.first?.title != pair.1.articles.first?.title, "Concurrent languages stay independent")
            let english = try await languageStore.load()
            try check(english.articles.first?.title == catalog.articles.first?.title, "Switching back restores published English")
            try FileManager.default.removeItem(at: translatedResource)
            let cachedArabic = try await languageStore.load(language: "ar")
            try check(cachedArabic.articles.first?.title == pair.0.articles.first?.title, "Reopening uses the correct cached language")
        }
        print("PASS: \(count) Help Center catalog, search, link and loading checks")
    }
}

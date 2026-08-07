import SwiftUI
import MarkdownUI

/// Inline markdown for single-line contexts such as titles.
///
/// The spec limits single-line fields to simple inline marks — bold, italic,
/// underline, strikethrough, inline code — so this renders with
/// `AttributedString`'s inline parser rather than MarkdownUI's block renderer,
/// keeping the result to a single line that truncates cleanly.
struct InlineMarkdownText: View {
    let markdown: String
    var strikethrough: Bool = false

    var body: some View {
        Text(attributed)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var result: AttributedString

        // `.inlineOnlyPreservingWhitespace` keeps block syntax (e.g. a leading
        // "#") as literal text instead of restructuring a title.
        if let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = parsed
        } else {
            result = AttributedString(markdown)
        }

        if strikethrough {
            result.strikethroughStyle = .single
        }
        return result
    }
}

/// Full block markdown for the notes field: headings, lists, code blocks,
/// block quotes, and tables, styled to match the app's typography.
struct BlockMarkdownText: View {
    let markdown: String

    var body: some View {
        Markdown(markdown)
            .markdownTheme(.app)
            .textSelection(.enabled)
    }
}

extension MarkdownUI.Theme {
    /// App-wide markdown styling. Sizes track Dynamic Type via `.system` fonts
    /// so notes stay legible at accessibility sizes.
    static var app: MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text {
                ForegroundColor(.primary)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(.secondary.opacity(0.12))
            }
            .strong {
                FontWeight(.semibold)
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.8), bottom: .em(0.3))
                    .markdownTextStyle {
                        FontSize(.em(1.5))
                        FontWeight(.bold)
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.7), bottom: .em(0.3))
                    .markdownTextStyle {
                        FontSize(.em(1.3))
                        FontWeight(.semibold)
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.6), bottom: .em(0.25))
                    .markdownTextStyle {
                        FontSize(.em(1.12))
                        FontWeight(.semibold)
                    }
            }
            .codeBlock { configuration in
                ScrollView(.horizontal, showsIndicators: false) {
                    configuration.label
                        .relativeLineSpacing(.em(0.22))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.9))
                        }
                        .padding(12)
                }
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous))
                .markdownMargin(top: .em(0.5), bottom: .em(0.5))
            }
            .blockquote { configuration in
                configuration.label
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                    }
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                    }
            }
    }
}

#Preview("Inline") {
    VStack(alignment: .leading, spacing: 12) {
        InlineMarkdownText(markdown: "Call **Dana** about the *invoice*")
        InlineMarkdownText(markdown: "Fix `parseDate()` and ~~retry~~")
        InlineMarkdownText(markdown: "Done item", strikethrough: true)
    }
    .padding()
}

#Preview("Block") {
    ScrollView {
        BlockMarkdownText(markdown: """
        # Heading
        Some **bold** text with `code`.

        ## Section
        - one
        - two

        ```swift
        let x = 1
        ```

        > A quote
        """)
        .padding()
    }
}

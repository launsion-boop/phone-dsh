// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — DSH's file-type glyphs for workspace artifacts.
//
// Ported from `ui-primitives/src/FileTypeIcon.tsx` (the 28px body/fold/mark
// artwork): the same glyphs the DSH web file cards and lists draw.

import SwiftUI

enum FileTypeGlyph {
    static func assetName(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "bmp", "ico",
             "tif", "tiff", "heic", "heif":
            return "DSHFileImage"
        case "pdf":
            return "DSHFilePDF"
        case "doc", "docx", "rtf", "odt", "pages":
            return "DSHFileWord"
        case "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "ods", "ots", "numbers",
             "csv", "tsv":
            return "DSHFileExcel"
        case "ppt", "pptx", "key":
            return "DSHFilePPT"
        case "mp4", "mov", "m4v", "webm", "mkv", "avi", "mpg", "mpeg":
            return "DSHFileVideo"
        case "html", "htm":
            return "DSHFileHTML"
        case "md", "markdown", "mdx":
            return "DSHFileMarkdown"
        case "swift", "py", "js", "ts", "tsx", "jsx", "mjs", "cjs", "sh", "bash", "zsh",
             "json", "yaml", "yml", "xml", "css", "scss", "less", "c", "h", "cpp", "hpp",
             "go", "rs", "toml", "ini", "patch", "diff", "log", "kt", "java", "rb", "php",
             "lua", "sql", "graphql", "proto":
            return "DSHFileCode"
        default:
            return "DSHFileOther"
        }
    }

    /// The DSH glyph for one file path, drawn at the requested size.
    static func icon(for path: String, size: CGFloat = 20) -> some View {
        Image(assetName(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    static func folder(size: CGFloat = 20) -> some View {
        Image("DSHFileFolder")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

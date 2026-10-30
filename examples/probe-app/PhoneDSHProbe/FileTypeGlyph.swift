// SPDX-License-Identifier: MIT
// DSH FileTypeIcon and code-file classification, rendered as native assets.

import SwiftUI

enum FileTypeGlyph {
    private static let exactCodeNames = [
        ".bash_profile": "shell", ".bashrc": "shell", ".env": "env",
        ".gitattributes": "git", ".gitconfig": "git", ".gitignore": "git",
        ".gitmodules": "git", ".mailmap": "git", ".profile": "shell",
        ".zprofile": "shell", ".zshrc": "shell", "bsdmakefile": "makefile",
        "cmakelists.txt": "cmake", "commit_editmsg": "git",
        "compose.yaml": "docker", "compose.yml": "docker",
        "docker-compose.yaml": "docker", "docker-compose.yml": "docker",
        "dockerfile": "docker", "gemfile": "ruby", "gnumakefile": "makefile",
        "guardfile": "ruby", "makefile": "makefile", "npm-shrinkwrap.json": "node",
        "package-lock.json": "node", "package.json": "node", "podfile": "ruby",
        "rakefile": "ruby",
    ]

    private static let codeExtensions = [
        "bash": "shell", "c": "c", "c++": "cpp", "cc": "cpp", "cfg": "ini",
        "cjs": "javascript", "clj": "clojure", "cljc": "clojure", "cljs": "clojure",
        "cmake": "cmake", "cpp": "cpp", "cs": "csharp", "csh": "shell", "css": "css",
        "csx": "csharp", "cts": "typescript", "cxx": "cpp", "dart": "dart", "dtd": "xml",
        "edn": "clojure", "env": "env", "erl": "erlang", "es6": "javascript",
        "escript": "erlang", "ex": "elixir", "exs": "elixir", "fish": "shell",
        "gemspec": "ruby", "go": "go", "gql": "graphql", "graphql": "graphql",
        "h": "c", "h++": "cpp", "hh": "cpp", "hpp": "cpp", "hrl": "erlang",
        "hs": "haskell", "hxx": "cpp", "ini": "ini", "ipp": "cpp", "java": "java",
        "js": "javascript", "json": "json", "json5": "json", "jsonc": "json",
        "jsx": "react", "ksh": "shell", "kt": "kotlin", "kts": "kotlin",
        "lhs": "haskell", "lua": "lua", "m": "objective-c", "mak": "makefile",
        "mjs": "javascript", "mk": "makefile", "mm": "objective-c", "mts": "typescript",
        "node": "node", "pch": "objective-c", "php": "php", "php3": "php",
        "php4": "php", "php5": "php", "phps": "php", "phtml": "php", "pl": "perl",
        "plist": "xml", "pm": "perl", "pod": "perl", "proto": "protobuf",
        "ps1": "powershell", "psd1": "powershell", "psm1": "powershell", "py": "python",
        "pyi": "python", "pyw": "python", "pyx": "python", "r": "r", "rake": "ruby",
        "rb": "ruby", "rmd": "r", "rs": "rust", "sc": "scala", "scala": "scala",
        "sh": "shell", "sol": "solidity", "sql": "sql", "svelte": "svelte",
        "swift": "swift", "t": "perl", "tcsh": "shell", "toml": "toml", "tpp": "cpp",
        "ts": "typescript", "tsx": "react", "vue": "vue", "wasm": "wasm",
        "wast": "wasm", "wat": "wasm", "xml": "xml", "xsd": "xml", "xsl": "xml",
        "xslt": "xml", "yaml": "yaml", "yml": "yaml", "zig": "zig", "zsh": "shell",
    ]

    static func assetName(for path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)?.lowercased() ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        if let kind = exactCodeNames[name] { return codeAsset(kind) }
        if name.hasPrefix("dockerfile.") { return codeAsset("docker") }
        if name.hasPrefix(".env.") { return codeAsset("env") }
        for suffix in ["component.ts", "component.html", "directive.ts", "service.ts", "module.ts", "pipe.ts", "guard.ts", "interceptor.ts"] where name.hasSuffix(suffix) {
            return codeAsset("angular")
        }
        if name.hasSuffix(".dockerfile") { return codeAsset("docker") }
        if let kind = codeExtensions[ext] { return codeAsset(kind) }
        if ["changelog", "contributing", "readme"].contains(name) { return "DSHFileMarkdown" }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "bmp", "ico", "tif", "tiff", "heic", "heif": return "DSHFileImage"
        case "pdf": return "DSHFilePDF"
        case "doc", "docx", "rtf", "odt", "pages": return "DSHFileWord"
        case "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx", "xltm", "ods", "ots", "fods", "numbers", "csv", "tsv": return "DSHFileExcel"
        case "ppt", "pptx", "key": return "DSHFilePPT"
        case "mp4", "mov", "m4v", "webm", "mkv", "avi", "mpg", "mpeg": return "DSHFileVideo"
        case "html", "htm": return "DSHFileHTML"
        case "md", "markdown", "mdx": return "DSHFileMarkdown"
        case "scss", "sass", "less", "astro", "bat", "cmd": return "DSHFileCode"
        default: return "DSHFileOther"
        }
    }

    private static func codeAsset(_ kind: String) -> String {
        "DSHCode" + kind.split(separator: "-").map(\.capitalized).joined()
    }

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

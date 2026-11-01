// A tiny JSON reader for the host-side schema test.
// SPDX-License-Identifier: MIT
//
// No JSON dependency is added for one test file. `org.json` is Android-only
// (a stub on the host JVM, where `unitTests.isReturnDefaultValues = false` makes
// it throw), and the module's "zero new dependencies" rule rules out a parser
// coordinate. This reader handles exactly what a schema document contains:
// objects, arrays, strings, integers, booleans and null.

package com.phonedsh.domain.testing

/** Parses JSON into `Map<String, Any?>`, `List<Any?>`, `String`, `Long`, `Boolean` and `null`. */
internal object MiniJson {
    @Suppress("UNCHECKED_CAST")
    fun parseObject(text: String): Map<String, Any?> {
        val value = Parser(text).parseDocument()
        return value as? Map<String, Any?>
            ?: throw IllegalArgumentException("the document root is not a JSON object")
    }

    private class Parser(private val text: String) {
        private var index: Int = 0

        fun parseDocument(): Any? {
            val value = parseValue()
            skipWhitespace()
            require(index == text.length) { "trailing content at offset $index" }
            return value
        }

        private fun parseValue(): Any? {
            skipWhitespace()
            require(index < text.length) { "unexpected end of document" }
            return when (val character = text[index]) {
                '{' -> parseObjectValue()
                '[' -> parseArray()
                '"' -> parseString()
                't' -> parseKeyword("true", true)
                'f' -> parseKeyword("false", false)
                'n' -> parseKeyword("null", null)
                else -> {
                    require(character == '-' || character in '0'..'9') {
                        "unexpected character '$character' at offset $index"
                    }
                    parseNumber()
                }
            }
        }

        private fun parseObjectValue(): Map<String, Any?> {
            expect('{')
            val members = LinkedHashMap<String, Any?>()
            skipWhitespace()
            if (peek() == '}') {
                index++
                return members
            }
            while (true) {
                skipWhitespace()
                val name = parseString()
                skipWhitespace()
                expect(':')
                members[name] = parseValue()
                skipWhitespace()
                when (peek()) {
                    ',' -> index++
                    '}' -> {
                        index++
                        return members
                    }

                    else -> throw IllegalArgumentException("expected ',' or '}' at offset $index")
                }
            }
        }

        private fun parseArray(): List<Any?> {
            expect('[')
            val elements = ArrayList<Any?>()
            skipWhitespace()
            if (peek() == ']') {
                index++
                return elements
            }
            while (true) {
                elements.add(parseValue())
                skipWhitespace()
                when (peek()) {
                    ',' -> index++
                    ']' -> {
                        index++
                        return elements
                    }

                    else -> throw IllegalArgumentException("expected ',' or ']' at offset $index")
                }
            }
        }

        private fun parseString(): String {
            expect('"')
            val builder = StringBuilder()
            while (true) {
                require(index < text.length) { "unterminated string" }
                val character = text[index++]
                when (character) {
                    '"' -> return builder.toString()
                    '\\' -> {
                        require(index < text.length) { "unterminated escape" }
                        when (val escaped = text[index++]) {
                            '"', '\\', '/' -> builder.append(escaped)
                            'b' -> builder.append('\b')
                            'f' -> builder.append('\u000C')
                            'n' -> builder.append('\n')
                            'r' -> builder.append('\r')
                            't' -> builder.append('\t')
                            'u' -> {
                                require(index + 4 <= text.length) { "truncated \\u escape" }
                                val code = text.substring(index, index + 4).toInt(16)
                                index += 4
                                builder.append(code.toChar())
                            }

                            else -> throw IllegalArgumentException("bad escape '\\$escaped'")
                        }
                    }

                    else -> builder.append(character)
                }
            }
        }

        private fun parseNumber(): Long {
            val start = index
            if (peek() == '-') index++
            while (index < text.length && text[index] in '0'..'9') index++
            val isFractional = index < text.length && (text[index] == '.' || text[index] == 'e' || text[index] == 'E')
            require(!isFractional) { "the schema parser only accepts integer numbers" }
            return text.substring(start, index).toLong()
        }

        private fun parseKeyword(keyword: String, value: Boolean?): Boolean? {
            require(text.startsWith(keyword, index)) { "expected '$keyword' at offset $index" }
            index += keyword.length
            return value
        }

        private fun expect(character: Char) {
            skipWhitespace()
            require(index < text.length && text[index] == character) {
                "expected '$character' at offset $index"
            }
            index++
        }

        private fun peek(): Char {
            require(index < text.length) { "unexpected end of document" }
            return text[index]
        }

        private fun skipWhitespace() {
            while (index < text.length && text[index].isJsonWhitespace()) index++
        }

        private fun Char.isJsonWhitespace(): Boolean =
            this == ' ' || this == '\t' || this == '\n' || this == '\r'
    }
}

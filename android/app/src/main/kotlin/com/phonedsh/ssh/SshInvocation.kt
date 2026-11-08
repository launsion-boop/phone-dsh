// phone-dsh — :app / com.phonedsh.ssh: the `ssh` / internal `scp` argv grammar.
// SPDX-License-Identifier: MIT
//
// A line-for-line port of `SSHInvocation` in
// `Sources/PhoneDSHSSH/SSHExecProvider.swift`. The Worker shell parses user `scp`
// operands and sends the internal form (docs/native-ssh.md):
//
//   upload:   ["scp","--pdsh-v1","upload","file"|"recursive",alias,"default"|port,local,remote]
//   download: ["scp","--pdsh-v1","download","file"|"recursive",alias,"default"|port,remote]
//
// The canonical request vectors are spec/v1/golden/frames/exec-req-2.json (ssh)
// and exec-req-3.json (scp download); the unit tests decode those frames.

package com.phonedsh.ssh

/** One parsed `ssh` or internal `scp` request. */
internal class SshInvocation private constructor(
    val destination: String,
    val port: Int?,
    val user: String?,
    val ignoreStandardInput: Boolean,
    val operation: Operation,
) {
    sealed interface Operation {
        data class Command(val command: String) : Operation

        data class Upload(val local: String, val remote: String, val recursive: Boolean) : Operation

        data class Download(val remote: String, val recursive: Boolean) : Operation
    }

    companion object {
        const val USAGE: String =
            "Usage: ssh [-p port] [-l user] connection command; ssh --list. Non-interactive, no stdin/forwarding. " +
                "Configure connections in Settings → SSH.\n"

        fun parse(argv: List<String>): SshInvocation {
            if (argv.any { it.contains('\u0000') }) throw SshFailure("Arguments must be NUL-free")
            if (argv.firstOrNull() == "scp") return parseScp(argv)
            var index = 1
            var port: Int? = null
            var user: String? = null
            var ignoreStdin = false
            while (index < argv.size && argv[index].startsWith("-")) {
                val flag = argv[index]
                index += 1
                if (flag == "--") break
                if (flag == "-T") continue
                if (flag == "-n") {
                    ignoreStdin = true
                    continue
                }
                if (flag !in setOf("-p", "-l") || index >= argv.size) {
                    throw SshFailure(
                        "Usage: ssh [-p port] [-l user] connection command; ssh --list. " +
                            "Interactive shells and forwarding are not supported.",
                    )
                }
                if (flag == "-p") {
                    port = parsePort(argv[index])
                } else {
                    user = argv[index]
                }
                index += 1
            }
            if (index + 1 >= argv.size) throw SshFailure("Usage: ssh connection command; ssh --list")
            return SshInvocation(
                destination = argv[index],
                port = port,
                user = user,
                ignoreStandardInput = ignoreStdin,
                operation = Operation.Command(argv.drop(index + 1).joinToString(" ")),
            )
        }

        private fun parseScp(argv: List<String>): SshInvocation {
            if (argv.size < 7 || argv[1] != "--pdsh-v1") throw SshFailure("Use scp through the Worker shell")
            val recursive = argv[3] == "recursive"
            if (!recursive && argv[3] != "file") throw SshFailure("Invalid transfer mode")
            val port = if (argv[5] == "default") null else parsePort(argv[5])
            val operation = when {
                argv[2] == "upload" && argv.size == 8 -> Operation.Upload(argv[6], argv[7], recursive)
                argv[2] == "download" && argv.size == 7 -> Operation.Download(argv[6], recursive)
                else -> throw SshFailure("Invalid transfer request")
            }
            return SshInvocation(argv[4], port, null, false, operation)
        }

        private fun parsePort(text: String): Int {
            val parsed = text.toIntOrNull()
            if (parsed == null || parsed !in 1..65535) throw SshFailure("Invalid SSH port")
            return parsed
        }
    }
}

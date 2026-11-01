// phone-dsh — :dsh unit test: EXEC_EVT canonical JSON and the 0x21 frame.
// SPDX-License-Identifier: MIT
//
// The two golden event vectors are reproduced byte-for-byte: member set, member
// order (canonical JSON), base64 output data, null code/signal and the frame
// header's type byte. That is stronger than "the JSON contains exec_id", and it
// keeps the event shape pinned to exec-bridge v1 §4.1.

package com.phonedsh.dsh.exec

import com.phonedsh.wire.WireCodec
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ExecEventCodecTest {
    @Test
    fun theExitGoldenVectorIsReproducedByteForByte() {
        val golden = ExecSpec.golden("exec-evt-1.json")
        val fields = golden.getJSONObject("fields")
        val event = ExecEvent.Exit(
            execId = fields.getString("exec_id"),
            seq = fields.getLong("seq"),
            code = fields.getInt("code"),
            signal = null,
            status = ExecEvent.ExitStatus.EXITED,
            quiescent = fields.getBoolean("quiescent"),
            stdoutBytes = fields.getLong("stdout_bytes"),
            stderrBytes = fields.getLong("stderr_bytes"),
        )

        val frame = event.encode(golden.getLong("seq"))

        assertEquals(0x21, frame[2].toInt() and 0xFF)
        assertEquals(golden.getString("frame_hex"), frame.hex())
        assertEquals(
            golden.getString("payload_hex"),
            frame.copyOfRange(16, frame.size).hex(),
        )
    }

    @Test
    fun theOutputGoldenVectorIsReproducedByteForByte() {
        val golden = ExecSpec.golden("exec-evt-2.json")
        val fields = golden.getJSONObject("fields")
        val event = ExecEvent.Output(
            execId = fields.getString("exec_id"),
            seq = fields.getLong("seq"),
            stream = ExecEvent.Stream.fromWire(fields.getString("stream"))!!,
            data = fields.getString("data"),
        )

        val frame = event.encode(golden.getLong("seq"))

        assertEquals(0x21, frame[2].toInt() and 0xFF)
        assertEquals(golden.getString("frame_hex"), frame.hex())
    }

    @Test
    fun everyEventIsCanonicalAndCarriesTheExecId() {
        val events = everyEventType()

        for (event in events) {
            val fields = event.fieldsJson()
            assertEquals("event ${event.type} is not canonical", WireCodec.canonicalJson(fields), fields)
            assertEquals(event.execId, JSONObject(fields).getString("exec_id"))
            assertEquals(event.type, JSONObject(fields).getString("type"))
            assertEquals(event.seq, JSONObject(fields).getLong("seq"))
        }
    }

    @Test
    fun everyEventTypeRoundTripsThroughItsRecordedJson() {
        for (event in everyEventType()) {
            assertEquals(event, ExecEvent.parse(event.fieldsJson()))
        }
    }

    @Test
    fun theFrameRoundTripsThroughTheRustCodec() {
        val event = ExecEvent.Error(
            execId = ExecFixtures.EXEC_ID,
            seq = 0,
            code = "unsupported",
            message = "the command is not an advertised accelerator; it was not executed",
        )

        val decoded = JSONObject(WireCodec.decode(event.encode(frameSeq = 9L)))

        assertEquals(WireCodec.canonicalJson(event.fieldsJson()), WireCodec.canonicalJson(decoded.toString()))
        assertEquals("error", decoded.getString("type"))
        assertTrue(decoded.has("code"))
    }

    private fun everyEventType(): List<ExecEvent> {
        val execId = "xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0-0"
        return listOf(
            ExecEvent.Start(execId = execId, seq = 0L),
            ExecEvent.Start(execId = execId, seq = 0L, replayed = true),
            ExecEvent.Output(
                execId = execId,
                seq = 1L,
                stream = ExecEvent.Stream.STDOUT,
                data = "aGVsbG8K",
            ),
            ExecEvent.Output(
                execId = execId,
                seq = 2L,
                stream = ExecEvent.Stream.STDERR,
                data = "d2Fybg==",
            ),
            ExecEvent.Exit(
                execId = execId,
                seq = 3L,
                code = 0,
                signal = null,
                status = ExecEvent.ExitStatus.EXITED,
                quiescent = true,
                stdoutBytes = 6L,
                stderrBytes = 0L,
            ),
            ExecEvent.Exit(
                execId = execId,
                seq = 3L,
                code = null,
                signal = "SIGTERM",
                status = ExecEvent.ExitStatus.SIGNALED,
                quiescent = false,
                stdoutBytes = 0L,
                stderrBytes = 0L,
            ),
            ExecEvent.Quiescent(execId = execId, seq = 4L),
            ExecEvent.Error(execId = execId, seq = 0L, code = "unsupported", message = "refused"),
        )
    }
}

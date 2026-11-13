// phone-dsh — :platform tests: the P08 Bot notification deep-link seam.
// SPDX-License-Identifier: MIT
//
// P08 only carries the link; P09 (`spec/ui/v1/bot/ui-state.md` §4.13) owns its
// grammar and resolution. These tests pin the carriage and the default drop for
// an adapter that has not implemented a PendingIntent path yet.

package com.phonedsh.platform

import com.phonedsh.platform.testing.FakePlatform
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationDeepLinkTest {
    @Test
    fun theBotDeepLinkFormIsAcceptedAndCarriedVerbatim() {
        val link = NotificationDeepLink("phonedsh://bot/main/row/e-main-approval-a1")
        assertEquals("phonedsh://bot/main/row/e-main-approval-a1", link.uri)
        assertEquals("NotificationDeepLink(phonedsh://bot/main/row/e-main-approval-a1)", link.toString())
    }

    @Test
    fun aNonBotOrMalformedUriIsRefused() {
        for (value in listOf("", "https://example.test/bot/main", "phonedsh://other/main/row/r1", "phonedsh://bot/main/row/r 1")) {
            try {
                NotificationDeepLink(value)
                throw AssertionError("accepted a non-Bot or malformed deep link: $value")
            } catch (expected: IllegalArgumentException) {
                assertFalse("the failure must not echo the URI", expected.message!!.contains(value) && value.isNotEmpty())
            }
        }
    }

    @Test
    fun theFakeRecordsTheLinkAndTheFiveArgumentCallRecordsNone() {
        FakePlatform().use { fake ->
            val link = NotificationDeepLink("phonedsh://bot/main/routine/r1")
            fake.notify(1, "Approval", "body", ongoing = false, action = null)
            fake.notify(2, "Routine", "body", ongoing = false, action = null, deepLink = link)
            assertEquals(2, fake.notifications.size)
            assertNull(fake.notifications[0].deepLink)
            assertEquals(link, fake.notifications[1].deepLink)
        }
    }

    @Test
    fun anAdapterThatOnlyImplementsTheFiveArgumentCallStillCompilesAndDropsTheLink() {
        val adapter = CountingNotifier()
        adapter.notify(7, "Bot", "body", ongoing = false, action = null,
            deepLink = NotificationDeepLink("phonedsh://bot/main/row/r1"))
        assertEquals(1, adapter.calls)
    }

    private class CountingNotifier : Notifier {
        var calls = 0
            private set

        override val availability: NotifierAvailability = NotifierAvailability.DISABLED

        override fun notify(
            id: Int,
            title: String,
            body: String,
            ongoing: Boolean,
            action: NotificationAction?,
        ) {
            calls++
        }

        override fun cancel(id: Int) = Unit
    }
}

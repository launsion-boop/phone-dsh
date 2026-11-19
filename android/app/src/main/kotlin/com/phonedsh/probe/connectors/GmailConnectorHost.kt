// phone-dsh — :app: the process-owned Gmail connector (发现 › Gmail).
// SPDX-License-Identifier: MIT
//
// Composition root for `com.phonedsh.connectors.gmail`, one per process like iOS
// `GmailMailbox.shared`. It projects the mailbox into the page's facts and owns
// the open message (`GmailMessagePage`'s `.task(id: attempt)`), so the page only
// renders and reports taps. Mail stays in memory; nothing here logs.

package com.phonedsh.probe.connectors

import android.content.Context
import com.phonedsh.connectors.gmail.GmailAccount
import com.phonedsh.connectors.gmail.GmailApi
import com.phonedsh.connectors.gmail.GmailBody
import com.phonedsh.connectors.gmail.GmailMailbox
import com.phonedsh.connectors.gmail.GmailMailboxSnapshot
import com.phonedsh.probe.BuildConfig
import com.phonedsh.ui.UiStrings
import com.phonedsh.ui.page.GmailAccountPhase
import com.phonedsh.ui.page.GmailBodyFacts
import com.phonedsh.ui.page.GmailConnectorAction
import com.phonedsh.ui.page.GmailConnectorFacts
import com.phonedsh.ui.page.GmailMessageRow
import com.phonedsh.ui.page.GmailOpenMessageFacts
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.launch

internal class GmailConnectorHost private constructor(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mailbox: GmailMailbox
    private val open = MutableStateFlow<GmailOpenMessageFacts?>(null)
    private var openJob: Job? = null

    /**
     * The last connected address. The mailbox leaves `Connected` (→ `Disconnecting`)
     * before it asks the authorizer to revoke, so the revoke must not read the
     * current account state: it reads this remembered address instead.
     */
    @Volatile
    private var lastEmail: String? = null

    init {
        val authorizer = GoogleGmailAuthorizer(
            context = context,
            isConfigured = BuildConfig.PDSH_GMAIL_ENABLED,
            connectedEmail = { lastEmail },
        )
        mailbox = GmailMailbox(authorizer, GmailApi(), scope) { zh, en -> text(zh, en) }
        scope.launch {
            mailbox.snapshot.collect { snapshot ->
                (snapshot.account as? GmailAccount.Connected)?.let { lastEmail = it.email }
            }
        }
    }

    val facts: StateFlow<GmailConnectorFacts> = combine(mailbox.snapshot, open) { snapshot, message ->
        project(snapshot, message)
    }.stateIn(scope, SharingStarted.Eagerly, project(mailbox.snapshot.value, null))

    fun handle(action: GmailConnectorAction) {
        when (action) {
            GmailConnectorAction.Appeared -> mailbox.restore()
            GmailConnectorAction.Connect -> mailbox.connect()
            GmailConnectorAction.Disconnect -> {
                closeMessage()
                mailbox.disconnect()
            }
            is GmailConnectorAction.Search -> {
                mailbox.setQuery(action.query)
                mailbox.search()
            }
            GmailConnectorAction.LoadMore -> mailbox.search(append = true)
            is GmailConnectorAction.Open -> openMessage(action.id)
            GmailConnectorAction.RetryOpen -> open.value?.let { load(it.copy(body = null, error = null)) }
            GmailConnectorAction.CloseMessage -> closeMessage()
        }
    }

    private fun openMessage(id: String) {
        val summary = mailbox.snapshot.value.messages.firstOrNull { it.id == id } ?: return
        load(
            GmailOpenMessageFacts(
                id = summary.id,
                sender = summary.sender,
                subject = summary.subject,
                date = summary.dateMillis?.let { formatDate(it) },
            ),
        )
    }

    /** Shows [message]'s header and reads its body (`.task(id: attempt)`); retry reuses the header. */
    private fun load(message: GmailOpenMessageFacts) {
        val id = message.id
        openJob?.cancel()
        open.value = message
        openJob = scope.launch {
            try {
                val message = mailbox.read(id)
                open.value = open.value?.takeIf { it.id == id }?.copy(
                    body = when (val body = message.body) {
                        is GmailBody.Plain -> GmailBodyFacts.Plain(body.text)
                        is GmailBody.Html -> GmailBodyFacts.Html(body.html)
                        GmailBody.Unavailable -> GmailBodyFacts.Unavailable
                    },
                    error = null,
                )
            } catch (cancelled: CancellationException) {
                // A superseded read, or the connection changed under it.
                if (mailbox.snapshot.value.account !is GmailAccount.Connected) closeMessage()
            } catch (failure: Exception) {
                if (mailbox.snapshot.value.account == GmailAccount.Reconnect) {
                    closeMessage()
                } else {
                    open.value = open.value?.takeIf { it.id == id }?.copy(error = mailbox.readErrorMessage(failure))
                }
            }
        }
    }

    private fun closeMessage() {
        openJob?.cancel()
        openJob = null
        open.value = null
    }

    private fun project(snapshot: GmailMailboxSnapshot, message: GmailOpenMessageFacts?): GmailConnectorFacts {
        val account = snapshot.account
        return GmailConnectorFacts(
            phase = when (account) {
                GmailAccount.Unconfigured -> GmailAccountPhase.UNCONFIGURED
                GmailAccount.Disconnected -> GmailAccountPhase.DISCONNECTED
                GmailAccount.Connecting -> GmailAccountPhase.CONNECTING
                is GmailAccount.Connected -> GmailAccountPhase.CONNECTED
                GmailAccount.Disconnecting -> GmailAccountPhase.DISCONNECTING
                GmailAccount.Reconnect -> GmailAccountPhase.RECONNECT
            },
            email = (account as? GmailAccount.Connected)?.email,
            messages = snapshot.messages.map { GmailMessageRow(it.id, it.sender, it.subject) },
            hasNextPage = snapshot.nextPage != null,
            loading = snapshot.loading,
            notice = snapshot.notice,
            query = snapshot.query,
            openMessage = message,
        )
    }

    private fun formatDate(millis: Long): String =
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(millis))

    companion object {
        @Volatile
        private var instance: GmailConnectorHost? = null

        /** The stored language preference; the host writes it before the first action. */
        @Volatile
        var languageId: String? = null

        fun text(zh: String, en: String): String = UiStrings.settingsNativeText(languageId, zh, en)

        fun get(context: Context): GmailConnectorHost =
            instance ?: synchronized(this) {
                instance ?: GmailConnectorHost(context.applicationContext).also { instance = it }
            }
    }
}

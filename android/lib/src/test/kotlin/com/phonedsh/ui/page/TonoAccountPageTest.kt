// Tono 账号 page: the 云端任务 section (spec/v1/cloud-tasks.md §7).
// SPDX-License-Identifier: MIT
package com.phonedsh.ui.page

import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.phonedsh.ui.theme.PdshTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class TonoAccountPageTest {
    @get:Rule
    val compose = createComposeRule()

    private val footer = "开启后，你在其他已登录设备上留给这台手机的任务，会加密保存在云端，直到这台手机取走。" +
        "任务在这台手机上运行，需要权限时仍会照常询问你。"

    private fun show(facts: TonoAccountFacts, onSetCloudTasks: (Boolean) -> Unit = {}) {
        compose.setContent {
            PdshTheme {
                TonoAccountPage(
                    facts = facts,
                    onBack = {},
                    onRequestCode = {},
                    onSignIn = {},
                    onSignOut = {},
                    onSetCloudTasks = onSetCloudTasks,
                )
            }
        }
    }

    private fun scrollTo(text: String) {
        compose.onNodeWithTag(UiPageTags.TONO_ACCOUNT_LIST).performScrollToNode(hasText(text))
    }

    @Test
    fun `the cloud task switch is off by default and its status says so`() {
        val defaults = TonoAccountFacts()
        assertEquals(false, defaults.cloudTasksEnabled)
        assertEquals("未开启", defaults.cloudTasksStatus)
    }

    @Test
    fun `signed out the section shows the switch the status and the footer and a tap asks the host to turn it on`() {
        val asked = ArrayList<Boolean>()
        show(TonoAccountFacts(available = true), onSetCloudTasks = { asked += it })

        scrollTo(footer)
        compose.onNodeWithText("手机号登录").assertExists()
        compose.onNodeWithText("云端任务").assertExists()
        compose.onNodeWithText("状态").assertExists()
        compose.onNodeWithText("未开启").assertExists()
        compose.onNodeWithText(footer).assertExists()
        compose.onNodeWithTag(UiPageTags.TONO_ACCOUNT_CLOUD_TASKS_TOGGLE).assertIsOff().performClick()

        assertEquals("the page reports the tap; the host owns the value", listOf(true), asked)
        compose.onNodeWithTag(UiPageTags.TONO_ACCOUNT_CLOUD_TASKS_TOGGLE).assertIsOff()
    }

    @Test
    fun `signed in the same section shows the host's status and a tap asks to turn it off`() {
        val asked = ArrayList<Boolean>()
        show(
            TonoAccountFacts(
                available = true, signedIn = true, phoneHint = "1234",
                cloudTasksEnabled = true, cloudTasksStatus = "已开启",
            ),
            onSetCloudTasks = { asked += it },
        )

        scrollTo(footer)
        compose.onNodeWithText("当前账号").assertExists()
        compose.onNodeWithText("云端任务").assertExists()
        compose.onNodeWithText("已开启").assertExists()
        compose.onNodeWithTag(UiPageTags.TONO_ACCOUNT_CLOUD_TASKS_TOGGLE).assertIsOn().performClick()

        assertEquals(listOf(false), asked)
    }

    @Test
    fun `while a change is being applied the switch takes no tap`() {
        val asked = ArrayList<Boolean>()
        show(TonoAccountFacts(available = true, cloudTasksBusy = true), onSetCloudTasks = { asked += it })

        scrollTo(footer)
        compose.onNodeWithTag(UiPageTags.TONO_ACCOUNT_CLOUD_TASKS_TOGGLE).performClick()

        assertEquals(emptyList<Boolean>(), asked)
    }
}

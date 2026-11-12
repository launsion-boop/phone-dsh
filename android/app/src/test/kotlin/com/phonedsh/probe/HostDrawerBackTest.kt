// The drawer's dialog back-press path in the host shape (interaction.md §1 rule 9).
// SPDX-License-Identifier: MIT
//
// `HomeDrawerMotionTest` in `:lib` proves the close animation when the drawer is
// mounted standalone. This test mounts the shape the host uses: the dialog's
// gesture is forwarded to the Activity's coordinator, the coordinator consumes
// the DRAWER overlay, and the drawer stays mounted until its motion reports
// `onClose`. Robolectric + a JVM Activity is not a device test.
package com.phonedsh.probe

import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedDispatcherOwner
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.phonedsh.ui.nav.BackCoordinator
import com.phonedsh.ui.nav.HomeDrawer
import com.phonedsh.ui.nav.HomeDrawerFacts
import com.phonedsh.ui.nav.PushBackState
import com.phonedsh.ui.nav.PushOverlay
import com.phonedsh.ui.theme.PdshTheme
import java.time.Duration
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp")
class HostDrawerBackTest {
    private lateinit var activity: ComponentActivity

    @Before
    fun setUp() {
        activity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()
    }

    private fun idle() {
        shadowOf(Looper.getMainLooper()).idle()
    }

    @Test
    fun `dialog back reaches the coordinator and onClose is what ends the mount`() {
        var closed = false
        var mounted = true
        var chain by mutableStateOf(
            HostBackChain(pushBack = PushBackState(overlays = listOf(PushOverlay.DRAWER))),
        )

        activity.setContent {
            PdshTheme(darkTheme = false) {
                BackCoordinator(
                    state = chain.pushBack,
                    onStateChange = { next -> chain = chain.applyPushState(next) },
                )
                if (chain.drawerOpen || mounted) {
                    HomeDrawer(
                        facts = HomeDrawerFacts(),
                        isOpen = chain.drawerOpen,
                        onBackPressed = { activity.onBackPressedDispatcher.onBackPressed() },
                        onClose = {
                            chain = chain.closeDrawer()
                            mounted = false
                            closed = true
                        },
                    )
                }
            }
        }
        idle()

        val dialog = ShadowDialog.getLatestDialog()
        assertNotNull("the drawer dialog is mounted", dialog)
        (dialog as OnBackPressedDispatcherOwner).onBackPressedDispatcher.onBackPressed()
        idle()

        assertFalse("the coordinator consumed the DRAWER layer", chain.drawerOpen)
        // The drawer's 220 ms close animation itself is pinned by `:lib`'s
        // `HomeDrawerMotionTest` (the app test module has no Compose test clock);
        // here `onClose` is the component's end-of-motion notification, and it is
        // the only place the host mount flag is cleared.
        assertTrue("onClose is the component's end-of-motion notification", closed)
        assertFalse("the host may unmount after onClose", mounted)
    }
}

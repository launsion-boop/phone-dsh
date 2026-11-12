// SPDX-License-Identifier: MIT
package com.phonedsh.pclink

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * One real assertion: the module is on the Gradle graph, its main output is on
 * the test classpath, and JUnit runs classes in the registered package.
 */
class PackageMarkerTest {
    @Test
    fun moduleIsOnTheJvmTestClasspath() {
        assertEquals("com.phonedsh.pclink", javaClass.packageName)
        assertNotNull(
            "test class output is not on the :pclink test classpath",
            javaClass.classLoader.getResource("com/phonedsh/pclink/PackageMarkerTest.class"),
        )
    }
}

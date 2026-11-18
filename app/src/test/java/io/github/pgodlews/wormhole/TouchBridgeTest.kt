package io.github.pgodlews.wormhole

import org.junit.Assert.assertEquals
import org.junit.Test

class TouchBridgeTest {
    @Test
    fun singleFingerDown() {
        assertEquals("P 1 0.25000 0.75000", TouchBridge.encodeLine(listOf(0.25f to 0.75f), null))
    }

    @Test
    fun twoFingers() {
        assertEquals(
            "P 2 0.10000 0.20000 0.30000 0.40000",
            TouchBridge.encodeLine(listOf(0.1f to 0.2f, 0.3f to 0.4f), null)
        )
    }

    @Test
    fun lastFingerLiftedSendsItsPosition() {
        assertEquals("P 0 0.50000 0.50000", TouchBridge.encodeLine(emptyList(), 0.5f to 0.5f))
    }

    @Test
    fun liftWithFingersRemainingSendsOnlyRemaining() {
        assertEquals("P 1 0.60000 0.60000", TouchBridge.encodeLine(listOf(0.6f to 0.6f), 0.1f to 0.1f))
    }

    @Test
    fun coordinatesAreClampedToTheVideo() {
        assertEquals("P 1 0.00000 1.00000", TouchBridge.encodeLine(listOf(-0.2f to 1.3f), null))
    }
}

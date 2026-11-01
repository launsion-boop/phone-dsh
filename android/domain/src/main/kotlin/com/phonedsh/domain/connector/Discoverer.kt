// Discovery: which remote hosts are around, before any is trusted.
// SPDX-License-Identifier: MIT
//
// Discovery is a separate interface because it is a separate promise. Finding a
// device proves nothing about it: the in-tree security rule is that discovery is
// only discovery, and a discovered device must be authenticated afterwards
// (device-connector §4.4: mDNS 只做发现，发现后必须再鉴权). Folding discovery into
// [DeviceConnector] would invite callers to treat "it appeared in the list" as
// "it may be driven", which is exactly the mistake the rule forbids.
//
// The spec does not fix a discovery mechanism either — the draft adapter contract
// assigns broadcast, scanning, pairing codes and key exchange to the protocol, and
// keeps only the phone-side UI, grants and naming here. So this seam returns
// candidates and nothing else: no transport, no capability, no trust.

package com.phonedsh.domain.connector

/**
 * Finds the remote hosts a protocol can see right now.
 *
 * An empty list means "nothing was found", which is not a failure; a discovery
 * that could not run throws [ConnectorException] instead, because a page must be
 * able to tell "there are no devices" from "I could not look".
 *
 * Implementations are cheap and side-effect free with respect to trust: they never
 * pair, never authenticate and never cache a grant.
 */
interface Discoverer {
    /**
     * Returns the candidates this protocol saw, in the adapter's own preference
     * order.
     *
     * @throws ConnectorException when discovery itself could not run.
     */
    suspend fun discover(): List<Endpoint>
}

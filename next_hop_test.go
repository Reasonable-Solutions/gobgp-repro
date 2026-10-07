package table

import (
	"net/netip"
	"testing"
	"time"

	"github.com/osrg/gobgp/v4/pkg/packet/bgp"
)

// Exercise wire decoding and the UPDATE-to-RIB conversion together. Checking
// the MP_REACH constructor alone misses the loss in ProcessMessage.
func TestSOKKReceivedIPv6NextHops(t *testing.T) {
	global := netip.MustParseAddr("2001:db8::1")
	local := netip.MustParseAddr("fe80::1")
	for _, tc := range []struct {
		name      string
		nextHops  []netip.Addr
		wantLocal netip.Addr
	}{
		{"global-only", []netip.Addr{global}, netip.Addr{}},
		{"global-and-link-local", []netip.Addr{global, local}, local},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var nlris []bgp.PathNLRI
			for _, prefix := range []string{"::/0", "2001:db8:51::1/128"} {
				nlri, err := bgp.NewIPAddrPrefix(netip.MustParsePrefix(prefix))
				if err != nil {
					t.Fatal(err)
				}
				nlris = append(nlris, bgp.PathNLRI{NLRI: nlri})
			}
			attr, err := bgp.NewPathAttributeMpReachNLRI(bgp.RF_IPv6_UC, nlris, tc.nextHops...)
			if err != nil {
				t.Fatal(err)
			}
			msg := bgp.NewBGPUpdateMessage(nil, []bgp.PathAttributeInterface{attr}, nil)
			wire, err := msg.Serialize()
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := bgp.ParseBGPMessage(wire)
			if err != nil {
				t.Fatal(err)
			}
			paths := ProcessMessage(decoded, &PeerInfo{}, time.Unix(0, 0), false)
			if len(paths) != len(nlris) {
				t.Fatalf("got %d paths, want %d", len(paths), len(nlris))
			}
			for _, path := range paths {
				got := path.getPathAttr(bgp.BGP_ATTR_TYPE_MP_REACH_NLRI).(*bgp.PathAttributeMpReachNLRI)
				if got.Nexthop != global {
					t.Errorf("%s: global next hop = %v, want %v", path.GetNlri(), got.Nexthop, global)
				}
				if got.LinkLocalNexthop != tc.wantLocal {
					t.Errorf("lost link-local next hop: %s: got %v, want %v", path.GetNlri(), got.LinkLocalNexthop, tc.wantLocal)
				}
			}
		})
	}
}

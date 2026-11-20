package cfapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
)

func TestEnsureProxiedIPv4(t *testing.T) {
	const name = "web.example.com"
	const origin = "8.8.8.8"
	const proxy = `{"name":"web.example.com","type":"A","content":"8.8.8.8","proxied":true}`
	tests := []struct {
		label, records string
		wantCreate     bool
		wantError      bool
	}{
		{"new", `[]`, true, false},
		{"idempotent", `[` + proxy + `]`, false, false},
		{"existing destination", `[{"name":"web.example.com","type":"AAAA"}]`, false, true},
		{"different A", `[{"name":"web.example.com","type":"A","content":"1.1.1.1"}]`, false, true},
		{"DNS only", `[{"name":"web.example.com","type":"A","content":"8.8.8.8","proxied":false}]`, false, true},
		{"IPv4 only", `[{"name":"web.example.com","type":"A","content":"8.8.8.8","proxied":true,"settings":{"ipv4_only":true}}]`, false, true},
	}
	for _, tt := range tests {
		t.Run(tt.label, func(t *testing.T) {
			posted := make(chan CreateRequest, 1)
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/zones/z1/dns_records" {
					http.Error(w, "bad path", http.StatusNotFound)
					return
				}
				if r.Method == http.MethodGet {
					if r.URL.Query().Get("name.exact") != name {
						http.Error(w, "bad name", http.StatusBadRequest)
						return
					}
					w.Write([]byte(`{"success":true,"result":` + tt.records + `}`))
					return
				}
				var record CreateRequest
				if r.Method != http.MethodPost || json.NewDecoder(r.Body).Decode(&record) != nil {
					http.Error(w, "bad request", http.StatusBadRequest)
					return
				}
				posted <- record
				w.Write([]byte(`{"success":true,"result":` + proxy + `}`))
			}))
			defer s.Close()
			client := New("test-token")
			client.BaseURL = s.URL
			result, err := client.EnsureProxiedIPv4(context.Background(), "z1", []string{name}, netip.MustParseAddr(origin), false)
			created := len(result) == 1 && result[0].Created
			if created != tt.wantCreate || (err != nil) != tt.wantError || (len(posted) != 0) != tt.wantCreate {
				t.Fatalf("create=%v, posted=%d, err=%v", created, len(posted), err)
			}
			if created {
				record := <-posted
				if record.Type != "A" || record.Name != name || record.Content != origin || !record.Proxied || record.TTL != 1 {
					t.Errorf("unexpected record: %+v", record)
				}
			}
		})
	}
}

func TestWebProxyUpgradesManagedSingleStack(t *testing.T) {
	const name = "old.example.com"
	const recordJSON = `{"id":"r1","name":"old.example.com","type":"A","content":"8.8.8.8","proxied":true,"comment":"addipv6"}`
	for _, tt := range []struct {
		name, records string
		ipv6Only      bool
		wantUpdate    bool
		wantError     bool
	}{
		{"managed IPv6 only", recordJSON[:len(recordJSON)-1] + `,"settings":{"ipv6_only":true}}`, false, true, false},
		{"managed IPv4 only", recordJSON[:len(recordJSON)-1] + `,"settings":{"ipv4_only":true}}`, false, true, false},
		{"already dual stack", recordJSON, false, false, false},
		{"explicit IPv6-only does not narrow dual stack", recordJSON, true, false, true},
		{"unmanaged mode stays as-is", strings.Replace(recordJSON[:len(recordJSON)-1], `"comment":"addipv6"`, `"comment":"user"`, 1) + `,"settings":{"ipv6_only":true}}`, false, false, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			updates := make(chan map[string]map[string]bool, 1)
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.Method == http.MethodGet && r.URL.Query().Get("name.exact") == name:
					w.Write([]byte(`{"success":true,"result":[` + tt.records + `]}`))
				case r.Method == http.MethodPatch && r.URL.Path == "/zones/z1/dns_records/r1":
					var data map[string]map[string]bool
					if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
						http.Error(w, err.Error(), http.StatusBadRequest)
						return
					}
					updates <- data
					w.Write([]byte(`{"success":true,"result":` + recordJSON + `}`))
				default:
					http.Error(w, "unexpected request", http.StatusBadRequest)
				}
			}))
			defer s.Close()
			c := New("test-token")
			c.BaseURL = s.URL
			out, err := c.EnsureProxiedIPv4(context.Background(), "z1", []string{name}, netip.MustParseAddr("8.8.8.8"), tt.ipv6Only)
			updated := len(out) == 1 && out[0].Updated
			if (err != nil) != tt.wantError || updated != tt.wantUpdate || (len(updates) != 0) != tt.wantUpdate {
				t.Fatalf("result=%+v, patches=%d, err=%v", out, len(updates), err)
			}
			if tt.wantUpdate {
				data := <-updates
				settings := data["settings"]
				ipv4only, hasIPv4 := settings["ipv4_only"]
				ipv6only, hasIPv6 := settings["ipv6_only"]
				if len(data) != 1 || len(settings) != 2 || !hasIPv4 || !hasIPv6 || ipv4only || ipv6only {
					t.Errorf("PATCH must only clear the two address-family flags: %v", data)
				}
			}
		})
	}
}

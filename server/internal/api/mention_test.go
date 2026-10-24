package api

import (
	"context"
	"quickconect/internal/config"
	"reflect"
	"testing"
)

func TestAPIModelCandidatesExplicitAndAutomatic(t *testing.T) {
	server := &Server{}
	identity := &config.AutomationIdentity{DefaultModel: "default", ModelFallbacks: []string{"backup", "default", " "}}
	for _, tc := range []struct {
		selected string
		want     []string
	}{
		{" chosen ", []string{"chosen"}},
		{"", []string{"default", "backup"}},
	} {
		if got := server.apiModelCandidates(context.Background(), identity, tc.selected); !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("selected=%q got=%v want=%v", tc.selected, got, tc.want)
		}
	}
}

func TestMentionIdentityBoundaries(t *testing.T) {
	for _, tc := range []struct {
		text string
		want bool
	}{
		{"@helper please", true}, {"请问 @Helper?", true}, {"hello @helper", true},
		{"@helper2", false}, {"mail@helper.com", false}, {"x@helper", false},
		{"(@helper)", true}, {"@helper_name", false}, {"@Helper Smith，please", true},
	} {
		if got := mentionsIdentity(tc.text, "helper", "Helper Smith"); got != tc.want {
			t.Errorf("mentionsIdentity(%q)=%v, want %v", tc.text, got, tc.want)
		}
	}
}

package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAutomationSidecarDefaults(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(mainPath, []byte("listen: :8444\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "automation.yaml"), []byte("identities:\n  - id: brief\n    name: brief\n    mode: push\n    enabled: true\n"), 0600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(mainPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Automation.Identities) != 1 || c.Automation.Identities[0].PushTargets != "both" {
		t.Fatalf("unexpected automation config: %+v", c.Automation)
	}
}

func TestLoadInvalidAutomationSidecar(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "config.yaml")
	_ = os.WriteFile(mainPath, []byte("listen: :8444\n"), 0600)
	_ = os.WriteFile(filepath.Join(dir, "automation.yaml"), []byte("identities: ["), 0600)
	if _, err := Load(mainPath); err == nil {
		t.Fatal("invalid sidecar should fail")
	}
}

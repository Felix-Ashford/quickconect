package main

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"quickconect/internal/store"
	"testing"
)

func TestImportAutomationAvatar(t *testing.T) {
	dir := t.TempDir()
	db, media := filepath.Join(dir, "chat.db"), filepath.Join(dir, "media")
	cfg := filepath.Join(dir, "config.yaml")
	content := fmt.Sprintf("db_path: %q\nmedia_path: %q\nautomation:\n  identities:\n    - name: helper\n      display_name: Helper\n      mode: api\n      enabled: true\n", db, media)
	if err := os.WriteFile(cfg, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	var raw bytes.Buffer
	_ = png.Encode(&raw, image.NewRGBA(image.Rect(0, 0, 2, 2)))
	file := filepath.Join(dir, "photo.jpg")
	_ = os.WriteFile(file, raw.Bytes(), 0600)
	if err := importAvatar(cfg, "helper", file, "avatar-1", "image/jpeg"); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	user, _ := st.UserByName("helper")
	if user == nil || user.AvatarMediaID != "avatar-1" {
		t.Fatal("avatar association missing")
	}
	saved, err := os.ReadFile(filepath.Join(media, "avatar-1"))
	if err != nil || !bytes.Equal(saved, raw.Bytes()) {
		t.Fatal("image bytes changed")
	}
	_ = os.WriteFile(file, []byte("not an image"), 0600)
	if err := importAvatar(cfg, "helper", file, "avatar-2", "image/png"); err == nil {
		t.Fatal("invalid image accepted")
	}
}

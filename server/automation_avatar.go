package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"quickconect/internal/config"
	"quickconect/internal/store"
	"regexp"
)

// Manager uploads bytes using SFTP, then imports them through the server's
// configured media directory and database rather than hardcoding storage paths.
func setAutomationAvatar(args []string) {
	fs := flag.NewFlagSet("setautomationavatar", flag.ExitOnError)
	cfgPath := fs.String("config", "/etc/quickconect/config.yaml", "config path")
	name := fs.String("name", "", "identity name")
	file := fs.String("file", "", "uploaded image")
	id := fs.String("media-id", "", "media id")
	mime := fs.String("mime", "image/jpeg", "image MIME")
	_ = fs.Parse(args)
	if err := importAvatar(*cfgPath, *name, *file, *id, *mime); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(*id)
}
func importAvatar(cfgPath, name, file, id, mime string) error {
	if !regexp.MustCompile(`^[A-Za-z0-9_-]+$`).MatchString(id) || name == "" {
		return fmt.Errorf("invalid identity or media id")
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > 5<<20 {
		return fmt.Errorf("invalid avatar size")
	}
	// 根据内容识别，而不是信任本机文件扩展名。
	mime = http.DetectContentType(data)
	if mime != "image/png" && mime != "image/jpeg" && mime != "image/webp" {
		return fmt.Errorf("avatar must be PNG, JPEG or WebP")
	}
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer st.Close()
	display := name
	for _, identity := range cfg.Automation.Identities {
		if identity.Name == name && identity.DisplayName != "" {
			display = identity.DisplayName
		}
	}
	user, err := st.EnsureAutomationUser(name, display)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(cfg.MediaPath, 0755); err != nil {
		return err
	}
	target := filepath.Join(cfg.MediaPath, id)
	if err = os.WriteFile(target, data, 0644); err != nil {
		return err
	}
	if err = st.InsertMedia(id, user.ID, "avatar", mime, int64(len(data)), target); err != nil {
		_ = os.Remove(target)
		return err
	}
	return st.SetUserAvatar(user.ID, id)
}

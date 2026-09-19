// Package config 加载服务端 YAML 配置。
package config

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Listen      string `yaml:"listen"`       // 监听地址，如 ":8443"
	TLSEnabled  bool   `yaml:"tls_enabled"`  // 生产必须 true；本地测试可关
	TLSCert     string `yaml:"tls_cert"`
	TLSKey      string `yaml:"tls_key"`
	DBPath      string `yaml:"db_path"`      // SQLite 文件路径
	MediaPath   string `yaml:"media_path"`   // 媒体文件目录
	MediaMaxMB  int64  `yaml:"media_max_mb"` // 单文件上限
	UserQuotaGB int64  `yaml:"user_quota_gb"`
	Ntfy        Ntfy   `yaml:"ntfy"`
}

type Ntfy struct {
	Enabled         bool   `yaml:"enabled"`
	BaseURL         string `yaml:"base_url"`          // https://ntfy.sh
	CoalesceSeconds int    `yaml:"coalesce_seconds"`  // 合并节流窗口
	IncludeSender   bool   `yaml:"include_sender"`    // ping 正文是否附带发送者昵称（默认只报数量，元数据最小化）
}

// Load 读取配置文件，未填写的字段取默认值。
func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取配置 %s: %w", path, err)
	}
	c := &Config{}
	if err := yaml.Unmarshal(b, c); err != nil {
		return nil, fmt.Errorf("解析配置 %s: %w", path, err)
	}
	c.applyDefaults()
	if err := c.validate(); err != nil {
		return nil, err
	}
	return c, nil
}

// Default 返回用于本地开发/测试的默认配置。
func Default() *Config {
	c := &Config{}
	c.applyDefaults()
	return c
}

func (c *Config) applyDefaults() {
	if c.Listen == "" {
		c.Listen = ":8443"
	}
	if c.DBPath == "" {
		c.DBPath = "/var/lib/quickconect/quickconect.db"
	}
	if c.MediaPath == "" {
		c.MediaPath = "/var/lib/quickconect/media"
	}
	if c.MediaMaxMB <= 0 {
		c.MediaMaxMB = 100
	}
	if c.UserQuotaGB <= 0 {
		c.UserQuotaGB = 10
	}
	if c.Ntfy.Enabled && c.Ntfy.BaseURL == "" {
		c.Ntfy.BaseURL = "https://ntfy.sh"
	}
	if c.Ntfy.CoalesceSeconds <= 0 {
		c.Ntfy.CoalesceSeconds = 30
	}
}

func (c *Config) validate() error {
	if c.TLSEnabled && (c.TLSCert == "" || c.TLSKey == "") {
		return fmt.Errorf("启用 TLS 时必须配置 tls_cert 与 tls_key")
	}
	if !c.Ntfy.Enabled && c.Ntfy.BaseURL != "" {
		c.Ntfy.BaseURL = ""
	}
	return nil
}

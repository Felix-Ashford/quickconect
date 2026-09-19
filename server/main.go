// quickconect 服务端入口。
//
// 子命令：
//
//	quickconect serve   -config <path>    启动服务
//	quickconect adduser -config <path> -name <用户名> -display <昵称> -password <密码>
//	quickconect version                   查看版本
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"quickconect/internal/api"
	"quickconect/internal/auth"
	"quickconect/internal/config"
	"quickconect/internal/push"
	"quickconect/internal/store"
	"quickconect/internal/ws"
)

var version = "0.1.0-dev"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	args := os.Args[2:]
	switch os.Args[1] {
	case "serve":
		serve(args)
	case "adduser":
		adduser(args)
	case "version":
		fmt.Println("quickconect-server", version)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "用法: quickconect <serve|adduser|version> [参数]")
}

func logger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	cfgPath := fs.String("config", "/etc/quickconect/config.yaml", "配置文件路径")
	_ = fs.Parse(args)

	log := logger()
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Error("加载配置失败", "err", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(cfg.MediaPath, 0o755); err != nil {
		log.Error("创建媒体目录失败", "err", err)
		os.Exit(1)
	}
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Error("打开数据库失败", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	hub := ws.NewHub(log)
	pusher := push.New(st, hub, push.NtfyOptions{
		Enabled:       cfg.Ntfy.Enabled,
		BaseURL:       cfg.Ntfy.BaseURL,
		Coalesce:      time.Duration(cfg.Ntfy.CoalesceSeconds) * time.Second,
		IncludeSender: cfg.Ntfy.IncludeSender,
	}, log)

	srv := &http.Server{
		Addr:    cfg.Listen,
		Handler: api.New(st, hub, pusher, cfg, log),
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		log.Info("收到退出信号，正在关闭…")
		_ = srv.Shutdown(context.Background())
	}()

	log.Info("启动", "listen", cfg.Listen, "tls", cfg.TLSEnabled, "db", cfg.DBPath, "version", version)
	if cfg.TLSEnabled {
		err = srv.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
	} else {
		log.Warn("TLS 未启用（仅限本地测试）")
		err = srv.ListenAndServe()
	}
	if err != nil && err != http.ErrServerClosed {
		log.Error("服务退出", "err", err)
		os.Exit(1)
	}
	log.Info("已退出")
}

func adduser(args []string) {
	fs := flag.NewFlagSet("adduser", flag.ExitOnError)
	cfgPath := fs.String("config", "/etc/quickconect/config.yaml", "配置文件路径")
	name := fs.String("name", "", "用户名（登录用，小写字母数字）")
	display := fs.String("display", "", "昵称（聊天中显示）")
	password := fs.String("password", "", "密码")
	_ = fs.Parse(args)

	if *name == "" || *password == "" {
		fmt.Fprintln(os.Stderr, "必须提供 -name 和 -password")
		os.Exit(2)
	}
	if *display == "" {
		*display = *name
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "加载配置失败:", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(filepath.Dir(cfg.DBPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "创建数据目录失败:", err)
		os.Exit(1)
	}
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "打开数据库失败:", err)
		os.Exit(1)
	}
	defer st.Close()

	hash, err := auth.HashPassword(*password)
	if err != nil {
		fmt.Fprintln(os.Stderr, "密码处理失败:", err)
		os.Exit(1)
	}
	u, err := st.CreateUser(*name, *display, hash)
	if err != nil {
		fmt.Fprintln(os.Stderr, "创建用户失败:", err)
		os.Exit(1)
	}
	fmt.Printf("已创建用户: id=%d name=%s display=%s\n", u.ID, u.Name, u.DisplayName)
}

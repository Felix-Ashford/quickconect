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
	"strings"
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
	case "listusers":
		listusers(args)
	case "deleteuser":
		deleteuser(args)
	case "version":
		fmt.Println("quickconect-server", version)
	case "setautomationavatar":
		setAutomationAvatar(args)
	default:
		usage()
		os.Exit(2)
	}
}

func deleteuser(args []string) {
	fs := flag.NewFlagSet("deleteuser", flag.ExitOnError)
	cfgPath := fs.String("config", "/etc/quickconect/config.yaml", "配置文件路径")
	name := fs.String("name", "", "用户名")
	confirm := fs.Bool("confirm", false, "确认删除")
	_ = fs.Parse(args)
	if *name == "" || !*confirm {
		fmt.Fprintln(os.Stderr, "删除用户需要提供 -name 和 -confirm")
		os.Exit(2)
	}
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "加载配置失败:", err)
		os.Exit(1)
	}
	for _, identity := range cfg.Automation.Identities {
		if identity.Name == *name {
			fmt.Fprintln(os.Stderr, "不能删除自动化身份，请先从 automation.yaml 移除该身份")
			os.Exit(1)
		}
	}
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "打开数据库失败:", err)
		os.Exit(1)
	}
	defer st.Close()
	u, err := st.UserByName(*name)
	if err != nil {
		fmt.Fprintln(os.Stderr, "查询用户失败:", err)
		os.Exit(1)
	}
	if u == nil {
		fmt.Fprintln(os.Stderr, "用户不存在:", *name)
		os.Exit(1)
	}
	if err := st.DeleteUser(u.ID); err != nil {
		fmt.Fprintln(os.Stderr, "删除用户失败:", err)
		os.Exit(1)
	}
	fmt.Printf("已删除用户 id=%d name=%s\n", u.ID, u.Name)
}

func listusers(args []string) {
	fs := flag.NewFlagSet("listusers", flag.ExitOnError)
	cfgPath := fs.String("config", "/etc/quickconect/config.yaml", "配置文件路径")
	_ = fs.Parse(args)
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "load config failed:", err)
		os.Exit(1)
	}
	st, err := store.Open(cfg.DBPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open database failed:", err)
		os.Exit(1)
	}
	defer st.Close()
	users, err := st.ListUsers()
	if err != nil {
		fmt.Fprintln(os.Stderr, "list users failed:", err)
		os.Exit(1)
	}
	for _, u := range users {
		fmt.Printf("%d\t%s\t%s\n", u.ID, u.Name, u.DisplayName)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "用法: quickconect <serve|adduser|listusers|deleteuser|version> [参数]")
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
	for i := range cfg.Automation.Identities {
		identity := &cfg.Automation.Identities[i]
		if !identity.Enabled || identity.Name == "" {
			continue
		}
		if identity.DisplayName == "" {
			identity.DisplayName = identity.Name
		}
		u, err := st.EnsureAutomationUser(identity.Name, identity.DisplayName)
		if err != nil {
			log.Error("automation identity initialization failed", "name", identity.Name, "err", err)
			os.Exit(1)
		}
		if err := st.SetUserAvatar(u.ID, identity.AvatarMediaID); err != nil {
			log.Error("automation avatar failed", "err", err)
			os.Exit(1)
		}
	}

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
	passwordFile := fs.String("password-file", "", "从临时文件读取密码")
	_ = fs.Parse(args)

	if *password == "" && *passwordFile != "" {
		b, err := os.ReadFile(*passwordFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, "读取密码文件失败:", err)
			os.Exit(1)
		}
		*password = strings.TrimSpace(string(b))
	}
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

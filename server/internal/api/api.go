// Package api 组装全部 HTTP 路由与处理函数。
package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"quickconect/internal/auth"
	"quickconect/internal/config"
	"quickconect/internal/push"
	"quickconect/internal/store"
	"quickconect/internal/ws"
)

type Server struct {
	store   *store.Store
	hub     *ws.Hub
	push    *push.Coalescer
	cfg     *config.Config
	log     *slog.Logger
	limiter *auth.Limiter
}

// allowedMessageTypes 允许的消息类型（payload 结构由客户端约定，服务端透传 JSON）。
var allowedMessageTypes = map[string]bool{
	"text": true, "image": true, "file": true, "voice": true, "sticker": true,
}

// New 构建路由与中间件。
func New(s *store.Store, hub *ws.Hub, pusher *push.Coalescer, cfg *config.Config, log *slog.Logger) http.Handler {
	a := &Server{store: s, hub: hub, push: pusher, cfg: cfg, log: log, limiter: auth.NewLimiter()}
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	})
	mux.HandleFunc("POST /api/auth/login", a.login)
	mux.HandleFunc("GET /api/ws", func(w http.ResponseWriter, r *http.Request) {
		hub.ServeWS(w, r, s)
	})

	authed := func(next http.Handler) http.Handler {
		return auth.Middleware(s, next)
	}
	mux.Handle("POST /api/auth/logout", authed(http.HandlerFunc(a.logout)))
	mux.Handle("GET /api/me", authed(http.HandlerFunc(a.me)))
	mux.Handle("GET /api/device", authed(http.HandlerFunc(a.device)))
	mux.Handle("GET /api/users", authed(http.HandlerFunc(a.users)))
	mux.Handle("GET /api/conversations", authed(http.HandlerFunc(a.listConversations)))
	mux.Handle("POST /api/conversations", authed(http.HandlerFunc(a.openDM)))
	mux.Handle("GET /api/conversations/{id}/messages", authed(http.HandlerFunc(a.getMessages)))
	mux.Handle("POST /api/conversations/{id}/messages", authed(http.HandlerFunc(a.sendMessage)))
	mux.Handle("POST /api/conversations/{id}/read", authed(http.HandlerFunc(a.markRead)))
	mux.Handle("POST /api/media", authed(http.HandlerFunc(a.uploadMedia)))
	mux.Handle("GET /api/media/{id}", authed(http.HandlerFunc(a.downloadMedia)))

	return logRequests(log, mux)
}

func logRequests(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		// 静态访问不刷屏：只记录异常慢的请求
		if d := time.Since(start); d > 5*time.Second {
			log.Info("慢请求", "method", r.Method, "path", r.URL.Path, "took", d.String())
		}
	})
}

// ---------- 通用工具 ----------

// timeZero 零值时间：媒体下载不需要 Last-Modified 语义。
func timeZero() time.Time { return time.Time{} }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func readJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<20))
	if err := dec.Decode(dst); err != nil {
		fail(w, http.StatusBadRequest, "请求体不是合法 JSON")
		return err
	}
	return nil
}

func pathID(w http.ResponseWriter, r *http.Request) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		fail(w, http.StatusBadRequest, "路径 ID 不合法")
		return 0, err
	}
	return id, nil
}

// ---------- 鉴权 ----------

func (a *Server) login(w http.ResponseWriter, r *http.Request) {
	if a.limiter.Blocked(r) {
		fail(w, http.StatusTooManyRequests, "失败次数过多，请稍后再试")
		return
	}
	var req struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceName string `json:"device_name"`
		Platform   string `json:"platform"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	if req.Username == "" || req.Password == "" {
		fail(w, http.StatusBadRequest, "用户名和密码不能为空")
		return
	}
	user, err := a.store.UserByName(req.Username)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if user == nil || !auth.CheckPassword(user.PasswordHash, req.Password) {
		a.limiter.RecordFailure(r)
		fail(w, http.StatusUnauthorized, "用户名或密码错误")
		return
	}
	a.limiter.ResetSuccess(r)

	token, err := auth.NewToken()
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	topic, err := auth.NewPushTopic()
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if req.DeviceName == "" {
		req.DeviceName = "未知设备"
	}
	dev, err := a.store.CreateDevice(user.ID, req.DeviceName, req.Platform, auth.HashToken(token), topic)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	a.log.Info("登录", "user", user.Name, "device", req.DeviceName, "device_id", dev.ID)
	writeJSON(w, http.StatusOK, map[string]any{
		"token":      token,
		"user":       user,
		"push_topic": topic,
	})
}

func (a *Server) logout(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	if err := a.store.DeleteDevice(dev.ID); err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *Server) me(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	u, err := a.store.UserByID(dev.UserID)
	if err != nil || u == nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	writeJSON(w, http.StatusOK, u)
}

// device 返回当前设备信息（含推送铃主题，客户端设置页用它生成订阅二维码）。
func (a *Server) device(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"id":         dev.ID,
		"name":       dev.Name,
		"platform":   dev.Platform,
		"push_topic": dev.PushTopic,
	})
}

func (a *Server) users(w http.ResponseWriter, _ *http.Request) {
	us, err := a.store.ListUsers()
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	writeJSON(w, http.StatusOK, us)
}

// ---------- 会话与消息 ----------

func (a *Server) openDM(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	var req struct {
		PeerID int64 `json:"peer_id"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	peer, err := a.store.UserByID(req.PeerID)
	if err != nil || peer == nil {
		fail(w, http.StatusBadRequest, "对方用户不存在")
		return
	}
	if peer.ID == dev.UserID {
		fail(w, http.StatusBadRequest, "不能和自己开私聊")
		return
	}
	convID, err := a.store.GetOrCreateDM(dev.UserID, peer.ID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	members, _ := a.store.ConvMembers(convID)
	writeJSON(w, http.StatusOK, map[string]any{
		"id": convID, "type": "dm", "members": members,
	})
}

func (a *Server) listConversations(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	convs, err := a.store.ListConversations(dev.UserID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if convs == nil {
		convs = []store.ConvSummary{}
	}
	writeJSON(w, http.StatusOK, convs)
}

func (a *Server) getMessages(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	convID, err := pathID(w, r)
	if err != nil {
		return
	}
	if ok, _ := a.store.IsMember(convID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "不是会话成员")
		return
	}
	afterSeq, _ := strconv.ParseInt(r.URL.Query().Get("after_seq"), 10, 64)
	limit := 100
	if v, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && v > 0 && v <= 500 {
		limit = v
	}
	msgs, hasMore, err := a.store.MessagesAfter(convID, afterSeq, limit)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if msgs == nil {
		msgs = []store.Message{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs, "has_more": hasMore})
}

func (a *Server) sendMessage(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	convID, err := pathID(w, r)
	if err != nil {
		return
	}
	var req struct {
		ClientMsgID string          `json:"client_msg_id"`
		Type        string          `json:"type"`
		Payload     json.RawMessage `json:"payload"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	if req.ClientMsgID == "" {
		fail(w, http.StatusBadRequest, "缺少 client_msg_id")
		return
	}
	if !allowedMessageTypes[req.Type] {
		fail(w, http.StatusBadRequest, "不支持的消息类型")
		return
	}
	if !json.Valid(req.Payload) {
		fail(w, http.StatusBadRequest, "payload 不是合法 JSON")
		return
	}
	if ok, _ := a.store.IsMember(convID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "不是会话成员")
		return
	}
	sender, _ := a.store.UserByID(dev.UserID)
	msg, err := a.store.InsertMessage(convID, dev.UserID, req.Type, req.Payload, req.ClientMsgID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	msg.SenderName = sender.DisplayName

	memberIDs, _ := a.store.ConvMemberIDs(convID)
	a.hub.BroadcastToUsers(memberIDs, map[string]any{"type": "message.new", "message": msg})
	a.push.Notify(dev.UserID, sender.DisplayName, memberIDs)
	writeJSON(w, http.StatusOK, msg)
}

func (a *Server) markRead(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	convID, err := pathID(w, r)
	if err != nil {
		return
	}
	var req struct {
		Seq int64 `json:"seq"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	if ok, _ := a.store.IsMember(convID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "不是会话成员")
		return
	}
	if err := a.store.MarkRead(convID, dev.UserID, req.Seq); err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- 媒体 ----------

func (a *Server) uploadMedia(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	maxBytes := a.cfg.MediaMaxMB << 20
	quotaBytes := a.cfg.UserQuotaGB << 30

	if r.ContentLength > maxBytes {
		fail(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("文件超过 %dMB 上限", a.cfg.MediaMaxMB))
		return
	}
	mr, err := r.MultipartReader()
	if err != nil {
		fail(w, http.StatusBadRequest, "需要 multipart 编码")
		return
	}

	kind, mime := "file", "application/octet-stream"
	var tmpPath string
	var size int64
	var mediaID string
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			a.cleanupTmp(tmpPath)
			fail(w, http.StatusBadRequest, "multipart 解析失败")
			return
		}
		switch part.FormName() {
		case "kind":
			b, _ := io.ReadAll(io.LimitReader(part, 64))
			if k := strings.TrimSpace(string(b)); k != "" {
				kind = k
			}
		case "mime":
			b, _ := io.ReadAll(io.LimitReader(part, 128))
			if m := strings.TrimSpace(string(b)); m != "" {
				mime = m
			}
		case "file":
			// 先落临时文件，配额校验通过后再移入正式路径
			mediaID = store.NewMediaID()
			tmpPath = filepath.Join(a.cfg.MediaPath, "tmp_"+mediaID)
			if err := os.MkdirAll(a.cfg.MediaPath, 0o755); err != nil {
				fail(w, http.StatusInternalServerError, "服务器错误")
				return
			}
			f, err := os.Create(tmpPath)
			if err != nil {
				fail(w, http.StatusInternalServerError, "服务器错误")
				return
			}
			n, err := io.Copy(f, io.LimitReader(part, maxBytes+1))
			f.Close()
			if err != nil {
				a.cleanupTmp(tmpPath)
				fail(w, http.StatusInternalServerError, "服务器错误")
				return
			}
			if n > maxBytes {
				a.cleanupTmp(tmpPath)
				fail(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("文件超过 %dMB 上限", a.cfg.MediaMaxMB))
				return
			}
			size = n
		}
	}
	if mediaID == "" || tmpPath == "" {
		a.cleanupTmp(tmpPath)
		fail(w, http.StatusBadRequest, "缺少 file 字段")
		return
	}

	usage, err := a.store.MediaUsage(dev.UserID)
	if err != nil {
		a.cleanupTmp(tmpPath)
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if usage+size > quotaBytes {
		a.cleanupTmp(tmpPath)
		fail(w, http.StatusRequestEntityTooLarge, "存储配额已满，请清理大文件")
		return
	}

	finalPath := filepath.Join(a.cfg.MediaPath, mediaID[:2], mediaID[2:4], mediaID)
	if err := os.MkdirAll(filepath.Dir(finalPath), 0o755); err != nil {
		a.cleanupTmp(tmpPath)
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		a.cleanupTmp(tmpPath)
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if err := a.store.InsertMedia(mediaID, dev.UserID, kind, mime, size, finalPath); err != nil {
		_ = os.Remove(finalPath)
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	a.log.Info("媒体上传", "user_id", dev.UserID, "kind", kind, "size", size)
	writeJSON(w, http.StatusOK, store.Media{ID: mediaID, Kind: kind, Mime: mime, Size: size})
}

func (a *Server) cleanupTmp(p string) {
	if p != "" {
		_ = os.Remove(p)
	}
}

func (a *Server) downloadMedia(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	m, err := a.store.MediaByID(id)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	if m == nil {
		fail(w, http.StatusNotFound, "媒体不存在")
		return
	}
	f, err := os.Open(m.Path)
	if err != nil {
		fail(w, http.StatusNotFound, "媒体文件缺失")
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", m.Mime)
	http.ServeContent(w, r, "", timeZero(), f)
}

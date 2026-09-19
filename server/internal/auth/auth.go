// Package auth 密码哈希、设备令牌、Bearer 鉴权与登录限速。
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"

	"quickconect/internal/store"
)

// HashPassword 生成 bcrypt 哈希。
func HashPassword(plain string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	return string(b), err
}

// CheckPassword 校验密码。
func CheckPassword(hash, plain string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}

// NewToken 生成 256 位随机设备令牌（base64url）。
func NewToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// HashToken 令牌入库只存 SHA-256。
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// NewPushTopic 生成不可猜测的 ntfy 主题：qc_ + 24 字节随机 base32 小写。
func NewPushTopic() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	const alphabet = "abcdefghijklmnopqrstuvwxyz234567"
	out := make([]byte, 0, len(b)*2)
	// 每字节拆两个 4bit，映射到 base32 字母表，保证只含小写字母与数字
	for _, v := range b {
		out = append(out, alphabet[int(v>>4)%32], alphabet[int(v&0x0f)%32])
	}
	return "qc_" + string(out), nil
}

// ctxKey 私有上下文键类型。
type ctxKey int

const deviceKey ctxKey = 1

// DeviceFrom 取出鉴权中间件放入的设备信息。
func DeviceFrom(ctx context.Context) *store.Device {
	d, _ := ctx.Value(deviceKey).(*store.Device)
	return d
}

// Middleware 校验 Bearer 令牌并把设备信息注入请求上下文。
func Middleware(s *store.Store, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(h, "Bearer ")
		if !ok || token == "" {
			http.Error(w, `{"error":"未认证"}`, http.StatusUnauthorized)
			return
		}
		dev, err := s.DeviceByTokenHash(HashToken(token))
		if err != nil {
			http.Error(w, `{"error":"服务器错误"}`, http.StatusInternalServerError)
			return
		}
		if dev == nil {
			http.Error(w, `{"error":"令牌无效"}`, http.StatusUnauthorized)
			return
		}
		s.TouchDevice(dev.ID)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deviceKey, dev)))
	})
}

// TokenFromQuery 供 WebSocket 升级请求使用（浏览器兼容取法，原生客户端同样适用）。
func TokenFromQuery(r *http.Request) string {
	return r.URL.Query().Get("token")
}

// Limiter 极简登录限速：每 IP 在一个滑动窗口内最多 10 次失败，成功登录即清零。
type Limiter struct {
	mu     sync.Mutex
	fails  map[string]*ipFails
	limit  int
	window time.Duration
}

type ipFails struct {
	count    int
	windowAt time.Time
}

func NewLimiter() *Limiter {
	return &Limiter{fails: map[string]*ipFails{}, limit: 10, window: time.Minute}
}

func (l *Limiter) ip(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// Blocked 报告该 IP 当前是否已被限速封禁。
func (l *Limiter) Blocked(r *http.Request) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w, ok := l.fails[l.ip(r)]
	if !ok {
		return false
	}
	if time.Since(w.windowAt) > l.window {
		return false
	}
	return w.count >= l.limit
}

// RecordFailure 记录一次失败。
func (l *Limiter) RecordFailure(r *http.Request) {
	l.mu.Lock()
	defer l.mu.Unlock()
	w := l.fails[l.ip(r)]
	if w == nil {
		w = &ipFails{}
		l.fails[l.ip(r)] = w
	}
	if time.Since(w.windowAt) > l.window {
		w.count, w.windowAt = 0, time.Now()
	}
	w.count++
}

// ResetSuccess 成功登录后清零该 IP 计数。
func (l *Limiter) ResetSuccess(r *http.Request) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.fails, l.ip(r))
}

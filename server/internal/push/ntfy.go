// Package push 实现 ntfy.sh「推送铃」：App 被系统挂起/杀掉时，
// 用一条不含消息内容的计数 ping 经 APNs/FCM 把用户拉回 App。
//
// 隐私边界：默认正文只有「您有 N 条新消息」，不含内容与发送者昵称
// （include_sender=true 时才附带昵称）。
package push

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"quickconect/internal/store"
	"quickconect/internal/ws"
)

type pending struct {
	count      int
	lastSender string
	timer      *time.Timer
}

type Coalescer struct {
	mu      sync.Mutex
	pending map[int64]*pending

	store *store.Store
	hub   *ws.Hub
	cfg   NtfyOptions
	httpc *http.Client
	log   *slog.Logger
}

type NtfyOptions struct {
	Enabled       bool
	BaseURL       string
	Coalesce      time.Duration
	IncludeSender bool
}

func New(s *store.Store, hub *ws.Hub, opts NtfyOptions, log *slog.Logger) *Coalescer {
	return &Coalescer{
		pending: map[int64]*pending{},
		store:   s,
		hub:     hub,
		cfg:     opts,
		httpc:   &http.Client{Timeout: 10 * time.Second},
		log:     log,
	}
}

// Notify 在消息写入后调用。在线用户不 ping（他们已通过 WS 实时收到）。
func (c *Coalescer) Notify(senderID int64, senderName string, recipientIDs []int64) {
	if !c.cfg.Enabled {
		return
	}
	for _, uid := range recipientIDs {
		if uid == senderID || c.hub.IsOnline(uid) {
			continue
		}
		c.add(uid, senderName)
	}
}

func (c *Coalescer) add(userID int64, senderName string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, ok := c.pending[userID]
	if !ok {
		p = &pending{}
		c.pending[userID] = p
		p.timer = time.AfterFunc(c.cfg.Coalesce, func() { c.flush(userID) })
	}
	p.count++
	p.lastSender = senderName
}

func (c *Coalescer) flush(userID int64) {
	c.mu.Lock()
	p, ok := c.pending[userID]
	if !ok {
		c.mu.Unlock()
		return
	}
	count, sender := p.count, p.lastSender
	delete(c.pending, userID)
	c.mu.Unlock()

	topics, err := c.store.PushTopicsForUser(userID)
	if err != nil {
		c.log.Error("查询推送主题失败", "user_id", userID, "err", err)
		return
	}
	text := fmt.Sprintf("您有 %d 条新消息", count)
	if c.cfg.IncludeSender && sender != "" {
		text = fmt.Sprintf("%s 发来 %d 条新消息", sender, count)
	}
	for _, topic := range topics {
		if err := c.publish(topic, text); err != nil {
			c.log.Warn("ntfy ping 失败", "user_id", userID, "err", err)
		}
	}
}

func (c *Coalescer) publish(topic, text string) error {
	body, _ := json.Marshal(map[string]string{
		"topic":   topic,
		"title":   "QuickConect",
		"message": text,
		"tags":    "speech_balloon",
	})
	resp, err := c.httpc.Post(c.cfg.BaseURL+"/", "application/json", bytes.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy 返回 %s", resp.Status)
	}
	return nil
}

// PublishTest 向该用户已注册的全部推送主题发一条测试 ping。
// 走的是与真实消息完全相同的路径，因此「测试收到」即代表真推送可用。
func (c *Coalescer) PublishTest(userID int64) error {
	if !c.cfg.Enabled {
		return fmt.Errorf("服务器未启用推送铃")
	}
	topics, err := c.store.PushTopicsForUser(userID)
	if err != nil {
		return err
	}
	if len(topics) == 0 {
		return fmt.Errorf("本机尚未注册推送主题，请重新登录后再试")
	}
	var firstErr error
	for _, topic := range topics {
		if err := c.publish(topic, "推送铃配置成功！收到这条说明通知链路正常。"); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// Package ws 维护 WebSocket 长连接：按用户聚合连接、广播事件、心跳保活。
//
// 心跳协议：客户端每 ~25s 发 {"type":"ping"}，服务端回 {"type":"pong"}；
// 服务端另发协议级 ping（30s），读超时 90s 无任何帧即断开。
package ws

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"quickconect/internal/auth"
	"quickconect/internal/store"
)

const (
	writeWait  = 10 * time.Second
	pongWait   = 90 * time.Second
	pingPeriod = 30 * time.Second
	sendBuffer = 64
)

type client struct {
	conn     *websocket.Conn
	send     chan []byte
	userID   int64
	deviceID int64
}

// Hub 持有所有在线连接（ userID -> 该用户的连接集合，支持多端同时在线）。
type Hub struct {
	mu    sync.RWMutex
	conns map[int64]map[*client]bool
	log   *slog.Logger
}

func NewHub(log *slog.Logger) *Hub {
	return &Hub{conns: map[int64]map[*client]bool{}, log: log}
}

func (h *Hub) IsOnline(userID int64) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.conns[userID]) > 0
}

// BroadcastToUsers 向给定用户的全部在线连接推送事件；发送缓冲满则丢弃该事件
// （客户端随后会通过游标对账补齐，绝不在这里做锁内修改或 close，避免竞态）。
func (h *Hub) BroadcastToUsers(userIDs []int64, event any) {
	data, err := json.Marshal(event)
	if err != nil {
		h.log.Error("事件序列化失败", "err", err)
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	seen := map[*client]bool{}
	for _, uid := range userIDs {
		for c := range h.conns[uid] {
			if seen[c] {
				continue
			}
			seen[c] = true
			select {
			case c.send <- data:
			default:
				h.log.Warn("发送缓冲满，丢弃事件（等待客户端对账）", "user_id", uid)
			}
		}
	}
}

// ServeWS 处理 /api/ws 升级（token 走查询参数）。
func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request, s *store.Store) {
	token := auth.TokenFromQuery(r)
	if token == "" {
		http.Error(w, `{"error":"缺少 token"}`, http.StatusUnauthorized)
		return
	}
	dev, err := s.DeviceByTokenHash(auth.HashToken(token))
	if err != nil || dev == nil {
		http.Error(w, `{"error":"令牌无效"}`, http.StatusUnauthorized)
		return
	}

	upgrader := websocket.Upgrader{
		// 自有原生客户端，无浏览器同源约束
		CheckOrigin: func(*http.Request) bool { return true },
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &client{conn: conn, send: make(chan []byte, sendBuffer), userID: dev.UserID, deviceID: dev.ID}

	h.mu.Lock()
	if h.conns[dev.UserID] == nil {
		h.conns[dev.UserID] = map[*client]bool{}
	}
	h.conns[dev.UserID][c] = true
	h.mu.Unlock()
	h.log.Info("WS 连接", "user_id", dev.UserID, "device", dev.Name)

	defer h.remove(c)
	go h.writePump(c)
	h.readPump(c, s)
}

func (h *Hub) remove(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set := h.conns[c.userID]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.conns, c.userID)
		}
	}
	close(c.send)
}

func (h *Hub) readPump(c *client, s *store.Store) {
	defer c.conn.Close()
	c.conn.SetReadLimit(1 << 20) // 1MB，仅心跳文本
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		s.TouchDevice(c.deviceID)
		var msg struct{ Type string `json:"type"` }
		if json.Unmarshal(data, &msg) == nil && msg.Type == "ping" {
			select {
			case c.send <- []byte(`{"type":"pong"}`):
			default:
			}
		}
	}
}

func (h *Hub) writePump(c *client) {
	ticker := time.NewTicker(pingPeriod)
	defer ticker.Stop()
	for {
		select {
		case data, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
				return
			}
		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

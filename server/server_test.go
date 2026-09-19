package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"mime/multipart"
	"net"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"quickconect/internal/api"
	"quickconect/internal/auth"
	"quickconect/internal/config"
	"quickconect/internal/push"
	"quickconect/internal/store"
	"quickconect/internal/ws"
)

// startTestServer 起一个内存配置的完整服务（无 TLS、随机端口），返回基地址与存储句柄。
func startTestServer(t *testing.T) (string, *store.Store) {
	t.Helper()
	dir := t.TempDir()
	cfg := config.Default()
	cfg.Listen = "127.0.0.1:0"
	cfg.DBPath = filepath.Join(dir, "test.db")
	cfg.MediaPath = filepath.Join(dir, "media")
	cfg.MediaMaxMB = 1
	cfg.Ntfy.Enabled = false

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		t.Fatalf("打开测试数据库: %v", err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := ws.NewHub(log)
	pusher := push.New(st, hub, push.NtfyOptions{}, log)
	srv := &http.Server{Handler: api.New(st, hub, pusher, cfg, log)}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("监听端口: %v", err)
	}
	go srv.Serve(ln)
	t.Cleanup(func() {
		srv.Close()
		st.Close()
	})
	return "http://" + ln.Addr().String(), st
}

var httpClient = &http.Client{Timeout: 5 * time.Second}

type apiResp struct {
	status int
	body   []byte
}

func call(t *testing.T, method, url, token string, body any) apiResp {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("编码请求: %v", err)
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, url, rd)
	if err != nil {
		t.Fatalf("构造请求: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return apiResp{status: resp.StatusCode, body: b}
}

func decode(t *testing.T, r apiResp, dst any) {
	t.Helper()
	if err := json.Unmarshal(r.body, dst); err != nil {
		t.Fatalf("解码响应 %s: %v", r.body, err)
	}
}

func login(t *testing.T, base, username string) string {
	t.Helper()
	var out struct {
		Token     string `json:"token"`
		PushTopic string `json:"push_topic"`
	}
	r := call(t, "POST", base+"/api/auth/login", "", map[string]string{
		"username": username, "password": "pw-" + username,
		"device_name": "test-" + username, "platform": "test",
	})
	if r.status != 200 {
		t.Fatalf("登录 %s 失败: %d %s", username, r.status, r.body)
	}
	decode(t, r, &out)
	if out.PushTopic == "" {
		t.Fatalf("登录响应应包含 push_topic")
	}
	return out.Token
}

func TestEndToEnd(t *testing.T) {
	base, st := startTestServer(t)

	// 建两个用户
	ha, _ := auth.HashPassword("pw-alice")
	alice, err := st.CreateUser("alice", "Alice", ha)
	if err != nil {
		t.Fatalf("建 alice: %v", err)
	}
	hb, _ := auth.HashPassword("pw-bob")
	bob, err := st.CreateUser("bob", "Bob", hb)
	if err != nil {
		t.Fatalf("建 bob: %v", err)
	}
	_ = alice

	tokenA := login(t, base, "alice")
	tokenB := login(t, base, "bob")

	// 未认证应被拒
	if r := call(t, "GET", base+"/api/me", "", nil); r.status != 401 {
		t.Fatalf("无令牌应 401，得到 %d", r.status)
	}
	// 错误密码应被拒
	if r := call(t, "POST", base+"/api/auth/login", "", map[string]string{"username": "alice", "password": "wrong"}); r.status != 401 {
		t.Fatalf("错误密码应 401，得到 %d", r.status)
	}

	// /api/me
	var me struct {
		Name string `json:"name"`
	}
	decode(t, call(t, "GET", base+"/api/me", tokenA, nil), &me)
	if me.Name != "alice" {
		t.Fatalf("me.name = %s", me.Name)
	}

	// /api/device：当前设备信息含推送铃主题
	var dev struct {
		Name      string `json:"name"`
		PushTopic string `json:"push_topic"`
	}
	decode(t, call(t, "GET", base+"/api/device", tokenA, nil), &dev)
	if dev.Name != "test-alice" || dev.PushTopic == "" {
		t.Fatalf("device 信息异常: %+v", dev)
	}

	// 用户名册
	var users []store.User
	decode(t, call(t, "GET", base+"/api/users", tokenA, nil), &users)
	if len(users) != 2 {
		t.Fatalf("应有 2 个用户，得到 %d", len(users))
	}

	// 开私聊（幂等）
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", tokenA, map[string]int64{"peer_id": bob.ID}), &conv)
	var conv2 struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", tokenA, map[string]int64{"peer_id": bob.ID}), &conv2)
	if conv.ID == 0 || conv.ID != conv2.ID {
		t.Fatalf("开私聊应幂等: %d vs %d", conv.ID, conv2.ID)
	}
	msgURL := fmt.Sprintf("%s/api/conversations/%d/messages", base, conv.ID)

	// 发两条消息；重发第一条应幂等
	var m1 store.Message
	decode(t, call(t, "POST", msgURL, tokenA, map[string]any{
		"client_msg_id": "m1", "type": "text", "payload": map[string]string{"text": "你好"},
	}), &m1)
	if m1.Seq != 1 {
		t.Fatalf("第一条 seq = %d", m1.Seq)
	}
	var m1again store.Message
	decode(t, call(t, "POST", msgURL, tokenA, map[string]any{
		"client_msg_id": "m1", "type": "text", "payload": map[string]string{"text": "你好"},
	}), &m1again)
	if m1again.ID != m1.ID {
		t.Fatalf("幂等重发应返回同一消息: %s vs %s", m1again.ID, m1.ID)
	}
	var m2 store.Message
	decode(t, call(t, "POST", msgURL, tokenA, map[string]any{
		"client_msg_id": "m2", "type": "text", "payload": map[string]string{"text": "在吗"},
	}), &m2)
	if m2.Seq != 2 {
		t.Fatalf("第二条 seq = %d", m2.Seq)
	}

	// bob 在线：WS 应实时收到第三条
	wsURL := "ws://" + base[len("http://"):] + "/api/ws?token=" + tokenB
	wsConn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("WS 连接: %v", err)
	}
	defer wsConn.Close()
	time.Sleep(200 * time.Millisecond) // 等服务端登记连接

	var m3 store.Message
	decode(t, call(t, "POST", msgURL, tokenA, map[string]any{
		"client_msg_id": "m3", "type": "text", "payload": map[string]string{"text": "ws-实时"},
	}), &m3)
	if m3.Seq != 3 {
		t.Fatalf("第三条 seq = %d", m3.Seq)
	}
	wsConn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, frame, err := wsConn.ReadMessage()
	if err != nil {
		t.Fatalf("读取 WS 事件: %v", err)
	}
	var event struct {
		Type    string         `json:"type"`
		Message store.Message  `json:"message"`
	}
	if err := json.Unmarshal(frame, &event); err != nil {
		t.Fatalf("WS 帧解析: %v", err)
	}
	if event.Type != "message.new" || event.Message.ID != m3.ID || event.Message.SenderName != "Alice" {
		t.Fatalf("WS 事件不符: %+v", event)
	}

	// bob 增量拉取：3 条、升序
	var page struct {
		Messages []store.Message `json:"messages"`
		HasMore  bool            `json:"has_more"`
	}
	decode(t, call(t, "GET", msgURL+"?after_seq=0", tokenB, nil), &page)
	if len(page.Messages) != 3 || page.Messages[0].Seq != 1 || page.Messages[2].Seq != 3 {
		t.Fatalf("增量拉取结果异常: %+v", page)
	}
	// after_seq=2 只剩第 3 条
	decode(t, call(t, "GET", msgURL+"?after_seq=2", tokenB, nil), &page)
	if len(page.Messages) != 1 || page.Messages[0].Seq != 3 {
		t.Fatalf("after_seq=2 应只剩 1 条: %+v", page)
	}

	// 未读数：alice 0（自己发的），bob 3；bob 标记已读后归零
	var convsA, convsB []store.ConvSummary
	decode(t, call(t, "GET", base+"/api/conversations", tokenA, nil), &convsA)
	decode(t, call(t, "GET", base+"/api/conversations", tokenB, nil), &convsB)
	if convsA[0].Unread != 0 || convsB[0].Unread != 3 {
		t.Fatalf("未读数异常: alice=%d bob=%d", convsA[0].Unread, convsB[0].Unread)
	}
	if r := call(t, "POST", fmt.Sprintf("%s/api/conversations/%d/read", base, conv.ID), tokenB, map[string]int64{"seq": 3}); r.status != 204 {
		t.Fatalf("标记已读: %d", r.status)
	}
	decode(t, call(t, "GET", base+"/api/conversations", tokenB, nil), &convsB)
	if convsB[0].Unread != 0 {
		t.Fatalf("已读后未读应为 0，得到 %d", convsB[0].Unread)
	}

	// 媒体：上传 → 下载比对；超限应 413
	var up struct {
		MediaID string `json:"media_id"`
		Size    int64  `json:"size"`
	}
	decode(t, uploadMedia(t, base, tokenA, "hello-media", "text/plain"), &up)
	if up.Size != int64(len("hello-media")) || up.MediaID == "" {
		t.Fatalf("上传结果异常: %+v", up)
	}
	dl := downloadMedia(t, base, tokenA, up.MediaID)
	if dl.status != 200 || string(dl.body) != "hello-media" {
		t.Fatalf("下载内容不符: %d %q", dl.status, dl.body)
	}
	big := bytes.Repeat([]byte("x"), 2<<20) // 2MB > 1MB 上限
	if r := uploadMedia(t, base, tokenA, string(big), "application/octet-stream"); r.status != 413 {
		t.Fatalf("超限上传应 413，得到 %d", r.status)
	}

	// 注销后令牌失效
	if r := call(t, "POST", base+"/api/auth/logout", tokenA, nil); r.status != 204 {
		t.Fatalf("注销: %d", r.status)
	}
	if r := call(t, "GET", base+"/api/me", tokenA, nil); r.status != 401 {
		t.Fatalf("注销后应 401，得到 %d", r.status)
	}
}

func uploadMedia(t *testing.T, base, token, content, mime string) apiResp {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	_ = mw.WriteField("kind", "file")
	_ = mw.WriteField("mime", mime)
	fw, _ := mw.CreateFormFile("file", "test.bin")
	fw.Write([]byte(content))
	mw.Close()
	req, _ := http.NewRequest("POST", base+"/api/media", &buf)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatalf("上传: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return apiResp{status: resp.StatusCode, body: b}
}

func downloadMedia(t *testing.T, base, token, id string) apiResp {
	t.Helper()
	req, _ := http.NewRequest("GET", base+"/api/media/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := httpClient.Do(req)
	if err != nil {
		t.Fatalf("下载: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return apiResp{status: resp.StatusCode, body: b}
}

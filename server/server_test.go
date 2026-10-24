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
	"net/http/httptest"
	"path/filepath"
	"strings"
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
func startTestServer(t *testing.T, identities ...config.AutomationIdentity) (string, *store.Store) {
	t.Helper()
	dir := t.TempDir()
	cfg := config.Default()
	cfg.Listen = "127.0.0.1:0"
	cfg.DBPath = filepath.Join(dir, "test.db")
	cfg.MediaPath = filepath.Join(dir, "media")
	cfg.MediaMaxMB = 1
	cfg.Ntfy.Enabled = false
	cfg.Automation.Identities = identities

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		t.Fatalf("打开测试数据库: %v", err)
	}
	for _, identity := range identities {
		if identity.Enabled {
			display := identity.DisplayName
			if display == "" {
				display = identity.Name
			}
			if _, err := st.EnsureAutomationUser(identity.Name, display); err != nil {
				t.Fatal(err)
			}
		}
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

func TestDeletedPeerCannotChat(t *testing.T) {
	base, st := startTestServer(t)
	users := make(map[string]int64)
	for _, name := range []string{"alice", "bob", "carol"} {
		hash, _ := auth.HashPassword("pw-" + name)
		u, err := st.CreateUser(name, name, hash)
		if err != nil {
			t.Fatal(err)
		}
		users[name] = u.ID
	}
	token := login(t, base, "alice")
	conv, err := st.GetOrCreateDM(users["alice"], users["bob"])
	if err != nil {
		t.Fatal(err)
	}
	_, err = st.InsertMessage(conv, users["alice"], "text", []byte(`{"text":"history"}`), "before-delete")
	if err != nil {
		t.Fatal(err)
	}
	if err := st.DeleteUser(users["bob"]); err != nil {
		t.Fatal(err)
	}
	var directory []store.User
	decode(t, call(t, "GET", base+"/api/users", token, nil), &directory)
	if len(directory) != 2 {
		t.Fatalf("deleted user still in directory: %+v", directory)
	}
	var conversations []store.ConvSummary
	decode(t, call(t, "GET", base+"/api/conversations", token, nil), &conversations)
	if len(conversations) != 0 {
		t.Fatal("deleted peer conversation still selectable")
	}
	if r := call(t, "POST", base+"/api/conversations", token, map[string]any{"peer_id": users["bob"]}); r.status != 400 {
		t.Fatalf("opening deleted user: %d %s", r.status, r.body)
	}
	if r := call(t, "POST", fmt.Sprintf("%s/api/conversations/%d/messages", base, conv), token, map[string]any{"client_msg_id": "after-delete", "type": "text", "payload": map[string]any{"text": "blocked"}}); r.status != 403 {
		t.Fatalf("sending to deleted user: %d %s", r.status, r.body)
	}
	history, _, err := st.MessagesAfter(conv, 0, 100)
	if err != nil || len(history) != 1 {
		t.Fatalf("history not preserved: %v %v", history, err)
	}
	if r := call(t, "POST", base+"/api/conversations", token, map[string]any{"peer_id": users["carol"]}); r.status != 200 {
		t.Fatalf("active user conversation failed: %d %s", r.status, r.body)
	}
}

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

	// /api/push/test：测试推送复用真实链路。
	// 测试环境 ntfy 未启用时应明确报错（而不是静默成功），
	// 保证「测试按钮说通、实际推不到」这种假象不会出现。
	if got := call(t, "POST", base+"/api/push/test", tokenA, nil).status; got != http.StatusBadGateway {
		t.Fatalf("未启用推送铃时 push/test 应返回 502，得到 %d", got)
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
		Type    string        `json:"type"`
		Message store.Message `json:"message"`
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

func TestAutomationConfigAndWebhook(t *testing.T) {
	base, st := startTestServer(t, config.AutomationIdentity{ID: "brief", Name: "brief", DisplayName: "Brief", Mode: "push", Enabled: true, WebhookToken: "test-secret"})
	ha, _ := auth.HashPassword("pw-alice")
	alice, err := st.CreateUser("alice", "Alice", ha)
	if err != nil {
		t.Fatal(err)
	}
	hb, _ := auth.HashPassword("pw-bob")
	bob, err := st.CreateUser("bob", "Bob", hb)
	if err != nil {
		t.Fatal(err)
	}
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	bad := call(t, "POST", base+"/api/automation/brief/webhook", "wrong", map[string]any{"client_msg_id": "bad", "user_id": alice.ID, "type": "text", "payload": map[string]string{"text": "no"}})
	if bad.status != http.StatusUnauthorized {
		t.Fatalf("bad token status=%d", bad.status)
	}
	good := call(t, "POST", base+"/api/automation/brief/webhook", "test-secret", map[string]any{"client_msg_id": "good", "user_id": alice.ID, "type": "text", "payload": map[string]string{"text": "hello"}})
	if good.status != http.StatusOK {
		t.Fatalf("webhook status=%d body=%s", good.status, good.body)
	}
	var pushed store.Message
	decode(t, good, &pushed)
	if pushed.SenderName != "Brief" || pushed.Seq != 1 {
		t.Fatalf("unexpected pushed message: %+v", pushed)
	}
	dup := call(t, "POST", base+"/api/automation/brief/webhook", "test-secret", map[string]any{"client_msg_id": "good", "user_id": alice.ID, "type": "text", "payload": map[string]string{"text": "hello"}})
	if dup.status != http.StatusOK {
		t.Fatalf("duplicate status=%d", dup.status)
	}
}

func TestPushTargetsAndAutomationThreads(t *testing.T) {
	base, st := startTestServer(t, config.AutomationIdentity{ID: "brief", Name: "brief", DisplayName: "Brief", Mode: "push", Enabled: true, WebhookToken: "secret", PushTargets: "user, conversation"}, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: "https://example.invalid", AllowedUsers: []int64{3}, PrivateDirectory: true})
	ha, _ := auth.HashPassword("pw-alice")
	alice, _ := st.CreateUser("alice", "Alice", ha)
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	token := login(t, base, "alice")
	for i := 0; i < 2; i++ {
		r := call(t, "POST", base+"/api/automation/helper/threads", token, map[string]string{"title": fmt.Sprintf("Thread %d", i+1)})
		if r.status != http.StatusCreated {
			t.Fatalf("thread create status=%d body=%s", r.status, r.body)
		}
	}
	listed := call(t, "GET", base+"/api/automation/helper/threads", token, nil)
	var threads []store.AutomationThread
	decode(t, listed, &threads)
	if listed.status != http.StatusOK || len(threads) != 2 || threads[0].ConversationID == threads[1].ConversationID {
		t.Fatalf("thread isolation failed status=%d threads=%+v", listed.status, threads)
	}
	bobToken := login(t, base, "bob")
	if r := call(t, "GET", base+"/api/automation/helper/threads", bobToken, nil); r.status != http.StatusForbidden {
		t.Fatalf("disallowed thread list status=%d", r.status)
	}
	// Both configured target forms are accepted by a comma-separated policy.
	userPush := call(t, "POST", base+"/api/automation/brief/webhook", "secret", map[string]any{"client_msg_id": "to-user", "user_id": alice.ID, "type": "text", "payload": map[string]string{"text": "hello"}})
	if userPush.status != http.StatusOK {
		t.Fatalf("user target rejected: %d %s", userPush.status, userPush.body)
	}
	_ = bob
}

func TestAutomationAPIFallback(t *testing.T) {
	var calls int
	modelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			http.Error(w, "temporary", http.StatusBadGateway)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "fallback answer"}}}})
	}))
	defer modelServer.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: modelServer.URL, DefaultModel: "first", ModelFallbacks: []string{"second"}})
	ha, _ := auth.HashPassword("pw-alice")
	alice, _ := st.CreateUser("alice", "Alice", ha)
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	_ = call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": alice.ID})
	// API mode requires a second member; use a separate user and open a DM.
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	r := call(t, "POST", base+"/api/automation/helper/invoke", token, map[string]any{"conversation_id": conv.ID, "prompt": "hello", "client_msg_id": "ai-1"})
	if r.status != http.StatusOK || calls != 2 {
		t.Fatalf("invoke status=%d calls=%d body=%s", r.status, calls, r.body)
	}
	var msg store.Message
	decode(t, r, &msg)
	if msg.SenderName != "Helper" {
		t.Fatalf("sender=%s", msg.SenderName)
	}
}

func TestAutomationMentionTrigger(t *testing.T) {
	modelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "mention answer"}}}})
	}))
	defer modelServer.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: modelServer.URL, DefaultModel: "test", MentionEnabled: true})
	ha, _ := auth.HashPassword("pw-alice")
	alice, _ := st.CreateUser("alice", "Alice", ha)
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	r := call(t, "POST", fmt.Sprintf("%s/api/conversations/%d/messages", base, conv.ID), token, map[string]any{"client_msg_id": "mention-1", "type": "text", "payload": map[string]string{"text": "@helper please answer"}})
	if r.status != http.StatusOK {
		t.Fatalf("send mention status=%d body=%s", r.status, r.body)
	}
	var found bool
	for i := 0; i < 20; i++ {
		time.Sleep(25 * time.Millisecond)
		msgs, _, _ := st.MessagesAfter(conv.ID, 0, 20)
		for _, msg := range msgs {
			if msg.SenderName == "Helper" {
				found = true
			}
		}
		if found {
			break
		}
	}
	if !found {
		t.Fatal("mention did not produce an automation reply")
	}
	if ok, _ := st.IsMember(conv.ID, alice.ID); !ok {
		t.Fatal("sender is no longer a member")
	}
}

func TestAutomationMentionDiscoversModels(t *testing.T) {
	calledModel := make(chan string, 1)
	modelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/v1/models" {
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]string{"id": "discovered-model"}}})
			return
		}
		var request struct {
			Model string `json:"model"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		calledModel <- request.Model
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "discovered answer"}}}})
	}))
	defer modelServer.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: modelServer.URL, MentionEnabled: true})
	ha, _ := auth.HashPassword("pw-alice")
	_, _ = st.CreateUser("alice", "Alice", ha)
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	r := call(t, "POST", fmt.Sprintf("%s/api/conversations/%d/messages", base, conv.ID), token, map[string]any{"client_msg_id": "mention-discovery-1", "type": "text", "payload": map[string]string{"text": "@helper discover"}})
	if r.status != http.StatusOK {
		t.Fatalf("send mention status=%d body=%s", r.status, r.body)
	}
	var found bool
	for i := 0; i < 30; i++ {
		time.Sleep(25 * time.Millisecond)
		messages, _, _ := st.MessagesAfter(conv.ID, 0, 20)
		for _, message := range messages {
			if message.SenderName == "Helper" {
				found = true
			}
		}
		if found {
			break
		}
	}
	if !found {
		t.Fatal("mention did not use discovered model")
	}
	select {
	case model := <-calledModel:
		if model != "discovered-model" {
			t.Fatalf("discovered model was not selected: %q", model)
		}
	default:
		t.Fatal("model endpoint was not called")
	}
}

func TestAutomationFailureVisibleAndContextRecovers(t *testing.T) {
	captured := make(chan []string, 1)
	attempt := 0
	modelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempt++
		if attempt == 1 {
			http.Error(w, "provider-secret-diagnostic", http.StatusUnauthorized)
			return
		}
		var request struct {
			Messages []struct {
				Content string `json:"content"`
			} `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&request)
		var texts []string
		for _, message := range request.Messages {
			texts = append(texts, message.Content)
		}
		captured <- texts
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "recovered answer"}}}})
	}))
	defer modelServer.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: modelServer.URL, DefaultModel: "test", MentionEnabled: true})
	ha, _ := auth.HashPassword("pw-alice")
	_, _ = st.CreateUser("alice", "Alice", ha)
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	url := fmt.Sprintf("%s/api/conversations/%d/messages", base, conv.ID)
	decode(t, call(t, "POST", url, token, map[string]any{"client_msg_id": "failed-mention", "type": "text", "payload": map[string]string{"text": "@helper first"}}), new(store.Message))
	errorMessage := waitAutomationMessage(t, st, conv.ID, 1)
	var errorPayload struct {
		Error bool   `json:"error"`
		Text  string `json:"text"`
	}
	if err := json.Unmarshal(errorMessage.Payload, &errorPayload); err != nil || !errorPayload.Error || errorPayload.Text == "" {
		t.Fatalf("missing friendly failure message: %s", errorMessage.Payload)
	}
	if bytes.Contains(errorMessage.Payload, []byte("provider-secret-diagnostic")) {
		t.Fatal("provider diagnostic leaked to the chat")
	}
	decode(t, call(t, "POST", url, token, map[string]any{"client_msg_id": "recovered-mention", "type": "text", "payload": map[string]string{"text": "@helper second"}}), new(store.Message))
	answer := waitAutomationMessage(t, st, conv.ID, errorMessage.Seq)
	if !bytes.Contains(answer.Payload, []byte("recovered answer")) {
		t.Fatalf("did not recover: %s", answer.Payload)
	}
	texts := <-captured
	if len(texts) != 3 || !strings.HasSuffix(texts[1], "@helper first") || !strings.HasSuffix(texts[2], "@helper second") || !strings.Contains(texts[1], "Alice") {
		t.Fatalf("failure polluted context or latest prompt was duplicated: %q", texts)
	}
}

func TestAgentContextWithExplicitModel(t *testing.T) {
	type modelRequest struct {
		Model    string              `json:"model"`
		Messages []map[string]string `json:"messages"`
	}
	captured := make(chan modelRequest, 2)
	modelServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request modelRequest
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		captured <- request
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "agent answer"}}}})
	}))
	defer modelServer.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "agent", Enabled: true, Endpoint: modelServer.URL, DefaultModel: "explicit-model", MentionEnabled: true, MemoryEnabled: true})
	ha, _ := auth.HashPassword("pw-alice")
	alice, _ := st.CreateUser("alice", "Alice", ha)
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	check := func(prompt string) {
		t.Helper()
		select {
		case request := <-captured:
			if request.Model != "explicit-model" || len(request.Messages) < 2 || request.Messages[0]["role"] != "system" {
				t.Fatalf("missing model or agent context: %+v", request)
			}
			var meta struct {
				UserID         int64   `json:"user_id"`
				ConversationID int64   `json:"conversation_id"`
				Recipients     []int64 `json:"recipient_user_ids"`
				Memory         bool    `json:"memory_enabled"`
			}
			if err := json.Unmarshal([]byte(strings.TrimPrefix(request.Messages[0]["content"], "QuickConect agent context: ")), &meta); err != nil || meta.UserID != alice.ID || meta.ConversationID != conv.ID || len(meta.Recipients) != 2 || !meta.Memory {
				t.Fatalf("incorrect agent metadata: %+v", request.Messages[0])
			}
			count := 0
			for _, message := range request.Messages {
				if message["content"] == prompt {
					count++
					if message["name"] != fmt.Sprintf("user_%d", alice.ID) {
						t.Fatalf("missing sender identity: %+v", message)
					}
				}
			}
			if count != 1 {
				t.Fatalf("prompt duplicated %d times: %+v", count, request.Messages)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("agent endpoint was not called")
		}
	}
	r := call(t, "POST", base+"/api/automation/helper/invoke", token, map[string]any{"conversation_id": conv.ID, "prompt": "manual question", "model": "explicit-model", "client_msg_id": "agent-manual"})
	if r.status != http.StatusOK {
		t.Fatalf("invoke status=%d body=%s", r.status, r.body)
	}
	check("manual question")
	decode(t, call(t, "POST", fmt.Sprintf("%s/api/conversations/%d/messages", base, conv.ID), token, map[string]any{"client_msg_id": "agent-mention", "type": "text", "payload": map[string]string{"text": "@helper follow up"}}), new(store.Message))
	_ = waitAutomationMessage(t, st, conv.ID, 2)
	check("@helper follow up")
}

func TestAgentMissingEndpointShowsError(t *testing.T) {
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "agent", Enabled: true, MentionEnabled: true})
	ha, _ := auth.HashPassword("pw-alice")
	_, _ = st.CreateUser("alice", "Alice", ha)
	hb, _ := auth.HashPassword("pw-bob")
	bob, _ := st.CreateUser("bob", "Bob", hb)
	token := login(t, base, "alice")
	var conv struct {
		ID int64 `json:"id"`
	}
	decode(t, call(t, "POST", base+"/api/conversations", token, map[string]int64{"peer_id": bob.ID}), &conv)
	decode(t, call(t, "POST", fmt.Sprintf("%s/api/conversations/%d/messages", base, conv.ID), token, map[string]any{"client_msg_id": "agent-missing-endpoint", "type": "text", "payload": map[string]string{"text": "@helper hello"}}), new(store.Message))
	message := waitAutomationMessage(t, st, conv.ID, 1)
	var payload struct {
		Error bool `json:"error"`
	}
	if json.Unmarshal(message.Payload, &payload) != nil || !payload.Error {
		t.Fatalf("missing agent error: %s", message.Payload)
	}
}

func waitAutomationMessage(t *testing.T, st *store.Store, convID, afterSeq int64) store.Message {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		messages, _, err := st.MessagesAfter(convID, afterSeq, 20)
		if err != nil {
			t.Fatal(err)
		}
		for _, message := range messages {
			if message.SenderName == "Helper" {
				return message
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("automation response did not appear")
	return store.Message{}
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

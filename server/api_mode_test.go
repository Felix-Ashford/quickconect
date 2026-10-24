package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"quickconect/internal/auth"
	"quickconect/internal/config"
	"quickconect/internal/store"
	"strings"
	"testing"
	"time"
)

func createTestPeople(t *testing.T, st *store.Store) (store.User, store.User) {
	t.Helper()
	hash, _ := auth.HashPassword("pw-alice")
	alice, err := st.CreateUser("alice", "Alice", hash)
	if err != nil {
		t.Fatal(err)
	}
	hash, _ = auth.HashPassword("pw-bob")
	bob, err := st.CreateUser("bob", "Bob", hash)
	if err != nil {
		t.Fatal(err)
	}
	return alice, bob
}

func TestMessageRevisionPermissionsAndOfflineChanges(t *testing.T) {
	base, st := startTestServer(t)
	alice, bob := createTestPeople(t, st)
	a := login(t, base, "alice")
	b := login(t, base, "bob")
	conv, _ := st.GetOrCreateDM(alice.ID, bob.ID)
	m, err := st.InsertMessage(conv, alice.ID, "text", []byte(`{"text":"old","format":"markdown"}`), "rev-question")
	if err != nil {
		t.Fatal(err)
	}
	url := fmt.Sprintf("%s/api/conversations/%d/messages/%s", base, conv, m.ID)
	if r := call(t, "PUT", url, b, map[string]string{"text": "attack"}); r.status != 403 {
		t.Fatalf("other author edit: %d %s", r.status, r.body)
	}
	var edited store.Message
	r := call(t, "PUT", url, a, map[string]string{"text": "new"})
	decode(t, r, &edited)
	if r.status != 200 || edited.ID != m.ID || edited.Seq != m.Seq || edited.Revision <= 0 {
		t.Fatalf("bad edit: %d %+v", r.status, edited)
	}
	changesURL := fmt.Sprintf("%s/api/conversations/%d/changes?after_revision=0", base, conv)
	var batch struct {
		Messages []store.Message `json:"messages"`
		Next     int64           `json:"next_revision"`
		More     bool            `json:"has_more"`
	}
	decode(t, call(t, "GET", changesURL, b, nil), &batch)
	if len(batch.Messages) != 1 || batch.Next != edited.Revision || batch.More {
		t.Fatalf("bad offline changes: %+v", batch)
	}
	var retracted store.Message
	decode(t, call(t, "DELETE", url, a, nil), &retracted)
	if retracted.Revision <= edited.Revision || bytes.Contains(retracted.Payload, []byte("new")) || !bytes.Contains(retracted.Payload, []byte("retracted")) {
		t.Fatalf("bad tombstone: %+v", retracted)
	}
	decode(t, call(t, "GET", changesURL, b, nil), &batch)
	if len(batch.Messages) != 1 || batch.Messages[0].Revision != retracted.Revision {
		t.Fatal("changes must return latest message state")
	}
	history, _, _ := st.MessagesAfter(conv, 0, 20)
	if len(history) != 1 || history[0].Revision != retracted.Revision {
		t.Fatalf("full history missing revisions: %+v", history)
	}
}

func TestAPIAutomationModelCatalog(t *testing.T) {
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/models" {
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]string{"id": "listed"}, map[string]string{"id": "configured"}}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "ok"}}}})
	}))
	defer model.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: model.URL, DefaultModel: "configured", ModelFallbacks: []string{"backup"}})
	createTestPeople(t, st)
	token := login(t, base, "alice")
	var catalog struct {
		Models []string `json:"models"`
	}
	decode(t, call(t, "GET", base+"/api/automation/helper/models", token, nil), &catalog)
	if len(catalog.Models) != 3 || catalog.Models[0] != "configured" || catalog.Models[1] != "backup" || catalog.Models[2] != "listed" {
		t.Fatalf("unexpected model catalog: %+v", catalog)
	}
}

func TestAPICharacterContextAndThreadPrompts(t *testing.T) {
	captured := make(chan []map[string]string, 10)
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []map[string]string `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		captured <- req.Messages
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "answer"}}}})
	}))
	defer model.Close()
	mention := "MENTION PROMPT"
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: model.URL, DefaultModel: "model", ContextMaxChars: 60000, MentionSystemPrompt: &mention, DirectSystemPrompt: "DIRECT DEFAULT", PrivateDirectory: true, MentionEnabled: true})
	alice, bob := createTestPeople(t, st)
	a := login(t, base, "alice")
	b := login(t, base, "bob")
	conv, _ := st.GetOrCreateDM(alice.ID, bob.ID)
	for i := 0; i < 65; i++ {
		payload, _ := json.Marshal(map[string]string{"text": fmt.Sprintf("history-%02d %s", i, strings.Repeat("中", 300))})
		if _, err := st.InsertMessage(conv, alice.ID, "text", payload, fmt.Sprintf("history-%d", i)); err != nil {
			t.Fatal(err)
		}
	}
	r := call(t, "POST", base+"/api/automation/helper/invoke", a, map[string]any{"conversation_id": conv, "prompt": "@helper current", "client_msg_id": "ctx-test"})
	if r.status != 200 {
		t.Fatalf("invoke: %d %s", r.status, r.body)
	}
	msgs := <-captured
	if msgs[0]["content"] != mention || len(msgs) < 65 {
		t.Fatalf("30-message cap or prompt mix: %d", len(msgs))
	}
	used := 0
	for _, m := range msgs[1:] {
		used += len([]rune(m["content"]))
		if !strings.Contains(m["content"], "Alice") || !strings.Contains(m["content"], "时间:") {
			t.Fatal("missing sender/time metadata")
		}
	}
	if used > 60000 {
		t.Fatalf("budget exceeded %d", used)
	}
	var thread store.AutomationThread
	decode(t, call(t, "POST", base+"/api/automation/helper/threads", a, map[string]string{"title": "manual"}), &thread)
	threadURL := fmt.Sprintf("%s/api/automation/helper/threads/%d", base, thread.ConversationID)
	for _, p := range []any{"OVERRIDE", "", nil} {
		response := call(t, "PUT", threadURL, a, map[string]any{"system_prompt": p})
		if response.status != 200 {
			t.Fatalf("prompt patch: %d %s", response.status, response.body)
		}
		response = call(t, "POST", base+"/api/automation/helper/invoke", a, map[string]any{"conversation_id": thread.ConversationID, "prompt": "question", "client_msg_id": fmt.Sprintf("prompt-%v", p)})
		if response.status != 200 {
			t.Fatalf("invoke private: %d %s", response.status, response.body)
		}
		context := <-captured
		if p == "" {
			if context[0]["role"] == "system" {
				t.Fatal("explicit empty must remove default prompt")
			}
		} else {
			want := "DIRECT DEFAULT"
			if p != nil {
				want = p.(string)
			}
			if context[0]["content"] != want {
				t.Fatalf("wrong prompt: %+v", context)
			}
		}
	}
	if r := call(t, "PUT", threadURL, b, map[string]any{"system_prompt": "attack"}); r.status != 403 {
		t.Fatalf("cross-user settings: %d", r.status)
	}
	var directory []store.AutomationThread
	decode(t, call(t, "GET", base+"/api/automation/helper/threads", b, nil), &directory)
	if len(directory) != 0 {
		t.Fatal("directory leaked across users")
	}
}

func TestAPIDirectWithoutMentionAndAutomaticTitle(t *testing.T) {
	captured := make(chan []map[string]string, 10)
	titlePrompt := "CUSTOM TITLE INSTRUCTION"
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []map[string]string `json:"messages"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		answer := "direct answer"
		if len(req.Messages) > 0 && req.Messages[0]["content"] == titlePrompt {
			answer = "AI summary"
		} else {
			captured <- req.Messages
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": answer}}}})
	}))
	defer model.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api", Enabled: true, Endpoint: model.URL, DefaultModel: "model", MentionEnabled: false, PrivateDirectory: true, TitleSystemPrompt: &titlePrompt})
	alice, _ := createTestPeople(t, st)
	token := login(t, base, "alice")
	var thread store.AutomationThread
	decode(t, call(t, "POST", base+"/api/automation/helper/threads", token, map[string]string{}), &thread)
	url := fmt.Sprintf("%s/api/conversations/%d/messages", base, thread.ConversationID)
	var question store.Message
	decode(t, call(t, "POST", url, token, map[string]any{"client_msg_id": "direct-q", "type": "text", "payload": map[string]string{"text": "hello"}}), &question)
	_ = waitAutomationMessage(t, st, thread.ConversationID, 1)
	<-captured
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		threads, _ := st.AutomationThreads("helper", alice.ID)
		if len(threads) > 0 && threads[0].Title == "AI summary" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	threads, _ := st.AutomationThreads("helper", alice.ID)
	if threads[0].Title != "AI summary" {
		t.Fatal("AI title not generated")
	}
	edited := call(t, "PUT", url+"/"+question.ID, token, map[string]string{"text": "edited question"})
	if edited.status != 200 {
		t.Fatal("edit failed")
	}
	before, _, _ := st.MessagesAfter(thread.ConversationID, 0, 20)
	time.Sleep(30 * time.Millisecond)
	after, _, _ := st.MessagesAfter(thread.ConversationID, 0, 20)
	if len(after) != len(before) {
		t.Fatal("edit automatically generated a reply")
	}
	_, _ = st.InsertMessage(thread.ConversationID, alice.ID, "text", []byte(`{"text":"later question"}`), "later-q")
	response := call(t, "POST", base+"/api/automation/helper/regenerate", token, map[string]any{"conversation_id": thread.ConversationID, "message_id": question.ID, "client_msg_id": "regen-id"})
	if response.status != 200 {
		t.Fatalf("regenerate: %d %s", response.status, response.body)
	}
	context := <-captured
	if len(context) != 1 || !strings.Contains(context[0]["content"], "edited question") || strings.Contains(context[0]["content"], "later question") {
		t.Fatalf("regeneration included later questions/answers or stale text: %+v", context)
	}
}

func TestAPIAutomationThreadDeletionIsPrivateAndComplete(t *testing.T) {
	base, st := startTestServer(t, config.AutomationIdentity{
		ID: "helper", Name: "helper", DisplayName: "Helper", Mode: "api",
		Enabled: true, PrivateDirectory: true,
	})
	createTestPeople(t, st)
	alice := login(t, base, "alice")
	bob := login(t, base, "bob")
	var thread store.AutomationThread
	decode(t, call(t, "POST", base+"/api/automation/helper/threads", alice, map[string]string{"title": "private"}), &thread)
	messageURL := fmt.Sprintf("%s/api/conversations/%d/messages", base, thread.ConversationID)
	response := call(t, "POST", messageURL, alice, map[string]any{"client_msg_id": "thread-message", "type": "text", "payload": map[string]string{"text": "private history"}})
	if response.status != http.StatusCreated && response.status != http.StatusOK {
		t.Fatalf("insert thread message: %d %s", response.status, response.body)
	}
	threadURL := fmt.Sprintf("%s/api/automation/helper/threads/%d", base, thread.ConversationID)
	if response := call(t, "DELETE", threadURL, bob, nil); response.status != http.StatusNotFound {
		t.Fatalf("another user must not delete the thread: %d %s", response.status, response.body)
	}
	if response := call(t, "DELETE", threadURL, alice, nil); response.status != http.StatusNoContent {
		t.Fatalf("owner delete: %d %s", response.status, response.body)
	}
	var threads []store.AutomationThread
	decode(t, call(t, "GET", base+"/api/automation/helper/threads", alice, nil), &threads)
	if len(threads) != 0 {
		t.Fatalf("deleted thread remains in directory: %+v", threads)
	}
	messages, _, err := st.MessagesAfter(thread.ConversationID, 0, 20)
	if err != nil || len(messages) != 0 {
		t.Fatalf("deleted history remains: %+v, %v", messages, err)
	}
}

func TestAPICharacterBudgetAndExcludedRevisions(t *testing.T) {
	captured := make(chan []map[string]string, 1)
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Messages []map[string]string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		captured <- req.Messages
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "ok"}}}})
	}))
	defer model.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", Mode: "api", Enabled: true, Endpoint: model.URL, DefaultModel: "model", ContextMaxChars: 60000})
	alice, bob := createTestPeople(t, st)
	token := login(t, base, "alice")
	conv, _ := st.GetOrCreateDM(alice.ID, bob.ID)
	for i := 0; i < 90; i++ {
		p, _ := json.Marshal(map[string]string{"text": fmt.Sprintf("history-%02d %s", i, strings.Repeat("中", 1000))})
		_, err := st.InsertMessage(conv, alice.ID, "text", p, fmt.Sprint(i))
		if err != nil {
			t.Fatal(err)
		}
	}
	m, _ := st.InsertMessage(conv, alice.ID, "text", []byte(`{"text":"original secret"}`), "edit")
	text := "latest edited text"
	_, _ = st.ReviseMessage(conv, alice.ID, m.ID, &text)
	m, _ = st.InsertMessage(conv, alice.ID, "text", []byte(`{"text":"retracted secret"}`), "retract")
	_, _ = st.ReviseMessage(conv, alice.ID, m.ID, nil)
	_, _ = st.InsertMessage(conv, alice.ID, "text", []byte(`{"text":"error text","error":true}`), "error")
	res := call(t, "POST", base+"/api/automation/helper/invoke", token, map[string]any{"conversation_id": conv, "prompt": "@helper current question", "client_msg_id": "answer"})
	if res.status != 200 {
		t.Fatalf("invoke: %d %s", res.status, res.body)
	}
	context := <-captured
	used := 0
	combined := ""
	for _, entry := range context {
		if entry["role"] == "system" {
			continue
		}
		used += len([]rune(entry["content"]))
		combined += entry["content"]
		if !strings.Contains(entry["content"], "用户ID:") || !strings.Contains(entry["content"], "时间:") {
			t.Fatal("metadata lost")
		}
	}
	if used > 60000 || used < 58000 {
		t.Fatalf("incorrect Unicode budget: %d", used)
	}
	for _, excluded := range []string{"history-00", "original secret", "retracted secret", "error text"} {
		if strings.Contains(combined, excluded) {
			t.Fatalf("excluded text found: %s", excluded)
		}
	}
	if !strings.Contains(combined, "latest edited text") || !strings.Contains(combined, "history-89") {
		t.Fatal("recent edited history missing")
	}
}

func TestAPIDisabledDirectoryRejectsExistingThreadCalls(t *testing.T) {
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", Mode: "api", Enabled: true})
	alice, _ := createTestPeople(t, st)
	token := login(t, base, "alice")
	user, _ := st.UserByName("helper")
	conv, _ := st.CreatePrivateConversation(alice.ID, user.ID)
	_, _ = st.CreateAutomationThread("helper", alice.ID, conv, "existing", "")
	m, _ := st.InsertMessage(conv, alice.ID, "text", []byte(`{"text":"question"}`), "question")
	for _, tc := range []struct {
		method, path string
		body         any
	}{
		{"GET", "/api/automation/helper/threads", nil},
		{"POST", "/api/automation/helper/threads", map[string]string{}},
		{"PUT", fmt.Sprintf("/api/automation/helper/threads/%d", conv), map[string]string{"title": "new"}},
		{"POST", "/api/automation/helper/invoke", map[string]any{"conversation_id": conv, "prompt": "question", "client_msg_id": "invoke"}},
		{"POST", "/api/automation/helper/regenerate", map[string]any{"conversation_id": conv, "message_id": m.ID, "client_msg_id": "regen"}},
		{"POST", "/api/conversations", map[string]any{"peer_id": user.ID}},
		{"GET", fmt.Sprintf("/api/conversations/%d/messages", conv), nil},
		{"POST", fmt.Sprintf("/api/conversations/%d/messages", conv), map[string]any{"client_msg_id": "blocked", "type": "text", "payload": map[string]string{"text": "blocked"}}},
		{"GET", fmt.Sprintf("/api/conversations/%d/changes", conv), nil},
		{"PUT", fmt.Sprintf("/api/conversations/%d/messages/%s", conv, m.ID), map[string]string{"text": "changed"}},
	} {
		res := call(t, tc.method, base+tc.path, token, tc.body)
		if res.status != 403 {
			t.Errorf("%s %s: %d %s", tc.method, tc.path, res.status, res.body)
		}
	}
	var conversations []store.ConvSummary
	decode(t, call(t, "GET", base+"/api/conversations", token, nil), &conversations)
	if len(conversations) != 0 {
		t.Fatal("disabled private conversation leaked into directory")
	}
}

func TestAPISelectedModelDoesNotSilentlyFallBack(t *testing.T) {
	called := make(chan string, 10)
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Model string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		called <- req.Model
		if req.Model != "backup" {
			http.Error(w, "unavailable", 503)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "fallback answer"}}}})
	}))
	defer model.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", Mode: "api", Enabled: true, Endpoint: model.URL, DefaultModel: "default", ModelFallbacks: []string{"backup"}, PrivateDirectory: true})
	createTestPeople(t, st)
	token := login(t, base, "alice")
	var thread store.AutomationThread
	decode(t, call(t, "POST", base+"/api/automation/helper/threads", token, map[string]string{"model": "chosen"}), &thread)
	request := map[string]any{"conversation_id": thread.ConversationID, "prompt": "hello", "client_msg_id": "selected-model"}
	res := call(t, "POST", base+"/api/automation/helper/invoke", token, request)
	if res.status != 502 {
		t.Fatalf("selected model: %d %s", res.status, res.body)
	}
	if got := <-called; got != "chosen" {
		t.Fatalf("wrong model: %s", got)
	}
	if len(called) != 0 {
		t.Fatal("explicit selection silently fell back")
	}
	url := fmt.Sprintf("%s/api/automation/helper/threads/%d", base, thread.ConversationID)
	if res := call(t, "PUT", url, token, map[string]string{"model": ""}); res.status != 200 {
		t.Fatal("cannot select automatic mode")
	}
	request["client_msg_id"] = "automatic-model"
	res = call(t, "POST", base+"/api/automation/helper/invoke", token, request)
	if res.status != 200 {
		t.Fatalf("automatic model: %d %s", res.status, res.body)
	}
	if first, second := <-called, <-called; first != "default" || second != "backup" {
		t.Fatalf("wrong fallback order: %s, %s", first, second)
	}
}

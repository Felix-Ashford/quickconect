package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"quickconect/internal/config"
	"quickconect/internal/store"
)

func TestContextVisibilityDeletionAndRegeneration(t *testing.T) {
	captured := make(chan string, 10)
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Messages []map[string]string }
		_ = json.NewDecoder(r.Body).Decode(&req)
		text := ""
		for _, entry := range req.Messages {
			text += entry["content"]
		}
		captured <- text
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": "fresh answer"}}}})
	}))
	defer model.Close()
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", Mode: "api", Enabled: true, Endpoint: model.URL, DefaultModel: "test", PrivateDirectory: true})
	alice, _ := createTestPeople(t, st)
	token, other := login(t, base, "alice"), login(t, base, "bob")
	ai, _ := st.UserByName("helper")
	var thread store.AutomationThread
	decode(t, call(t, "POST", base+"/api/automation/helper/threads", token, map[string]string{"title": "manual"}), &thread)
	q, _ := st.InsertMessage(thread.ConversationID, alice.ID, "text", []byte(`{"text":"question secret"}`), "q")
	// 老版本回复缺少 reply_to，仍可与原问题关联。
	old, _ := st.InsertMessage(thread.ConversationID, ai.ID, "text", []byte(`{"text":"legacy reply secret"}`), "old")
	url := fmt.Sprintf("%s/api/automation/helper/threads/%d", base, thread.ConversationID)
	read := func() map[string]struct {
		Included  bool
		Partial   bool
		Reason    string
		CanDelete bool `json:"can_delete"`
	} {
		t.Helper()
		var response struct {
			Messages map[string]struct {
				Included  bool
				Partial   bool
				Reason    string
				CanDelete bool `json:"can_delete"`
			}
		}
		result := call(t, "GET", url+"/context", token, nil)
		if result.status != 200 {
			t.Fatalf("visibility %d %s", result.status, result.body)
		}
		decode(t, result, &response)
		return response.Messages
	}
	if !read()[old.ID].Included {
		t.Fatal("initial reply excluded")
	}
	if res := call(t, "DELETE", url+"/messages/"+old.ID, token, nil); res.status != 409 {
		t.Fatal("active reply deleted")
	}
	if res := call(t, "GET", url+"/context", other, nil); res.status != 403 {
		t.Fatal("visibility leaked to other account")
	}
	var fresh store.Message
	decode(t, call(t, "POST", base+"/api/automation/helper/regenerate", token, map[string]any{"conversation_id": thread.ConversationID, "message_id": q.ID, "client_msg_id": "regen"}), &fresh)
	if strings.Contains(<-captured, "legacy reply secret") {
		t.Fatal("regeneration included answer after question")
	}
	states := read()
	if states[old.ID].Included || states[old.ID].Reason != "已被重新生成的回复替代" || !states[old.ID].CanDelete || !states[fresh.ID].Included || states[fresh.ID].CanDelete {
		t.Fatalf("wrong regeneration state %+v", states)
	}
	response := call(t, "POST", base+"/api/automation/helper/invoke", token, map[string]any{"conversation_id": thread.ConversationID, "prompt": "next question", "client_msg_id": "invoke"})
	if response.status != 200 {
		t.Fatal("followup failed")
	}
	if strings.Contains(<-captured, "legacy reply secret") {
		t.Fatal("excluded reply reached real model")
	}
	if res := call(t, "DELETE", url+"/messages/"+old.ID, other, nil); res.status != 403 {
		t.Fatal("cross account delete")
	}
	var deleted store.Message
	decode(t, call(t, "DELETE", url+"/messages/"+old.ID, token, nil), &deleted)
	if !strings.Contains(string(deleted.Payload), "deleted") || strings.Contains(string(deleted.Payload), "legacy reply secret") || deleted.Revision == 0 {
		t.Fatal("missing deletion tombstone")
	}
	changes, _, _, err := st.MessageChanges(thread.ConversationID, 0, 200)
	if err != nil || len(changes) == 0 {
		t.Fatal("deletion missing from offline sync")
	}
	call(t, "DELETE", fmt.Sprintf("%s/api/conversations/%d/messages/%s", base, thread.ConversationID, q.ID), token, nil)
	states = read()
	if states[q.ID].Included || states[fresh.ID].Included || states[fresh.ID].Reason != "原问题已撤回或删除" {
		t.Fatal("retracted question reply still included")
	}
	if res := call(t, "DELETE", url+"/messages/"+q.ID, token, nil); res.status != 409 {
		t.Fatal("human message must use existing retract action, not AI deletion")
	}
	if states[q.ID].CanDelete || !states[fresh.ID].CanDelete || states[old.ID].CanDelete {
		t.Fatal("deletion eligibility does not match message type and current state")
	}
	decode(t, call(t, "DELETE", url+"/messages/"+fresh.ID, token, nil), &deleted)
	if read()[old.ID].Included {
		t.Fatal("deleting newer answer resurrected old answer")
	}
}

func TestContextVisibilityBudgetMarksPartial(t *testing.T) {
	base, st := startTestServer(t, config.AutomationIdentity{ID: "helper", Name: "helper", Mode: "api", Enabled: true, PrivateDirectory: true, ContextMaxChars: 200})
	alice, _ := createTestPeople(t, st)
	token := login(t, base, "alice")
	var thread store.AutomationThread
	decode(t, call(t, "POST", base+"/api/automation/helper/threads", token, map[string]string{}), &thread)
	first, _ := st.InsertMessage(thread.ConversationID, alice.ID, "text", []byte(`{"text":"very old"}`), "first")
	raw, _ := json.Marshal(map[string]string{"text": strings.Repeat("中", 400)})
	last, _ := st.InsertMessage(thread.ConversationID, alice.ID, "text", raw, "last")
	var response struct {
		Messages map[string]struct {
			Included bool
			Partial  bool
			Reason   string
		}
	}
	decode(t, call(t, "GET", fmt.Sprintf("%s/api/automation/helper/threads/%d/context", base, thread.ConversationID), token, nil), &response)
	if response.Messages[first.ID].Included || !response.Messages[last.ID].Included || !response.Messages[last.ID].Partial {
		t.Fatalf("budget state %+v", response.Messages)
	}
}

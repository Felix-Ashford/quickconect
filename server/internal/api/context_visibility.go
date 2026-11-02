package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"quickconect/internal/auth"
	"quickconect/internal/config"
	"quickconect/internal/store"
)

type contextVisibility struct {
	Included  bool   `json:"included"`
	Partial   bool   `json:"partial,omitempty"`
	Reason    string `json:"reason,omitempty"`
	CanDelete bool   `json:"can_delete,omitempty"`
}
type contextEntry struct {
	id, role, content string
}

// 同一份计划同时用于真实模型请求和客户端标记，避免两套预算规则漂移。
func (a *Server) contextPlan(identity *config.AutomationIdentity, conv, sender int64, prompt string, throughSeq int64) ([]map[string]string, map[string]contextVisibility, error) {
	history := []store.Message{}
	for cursor := int64(0); ; {
		batch, _, err := a.store.MessagesAfter(conv, cursor, 500)
		if err != nil {
			return nil, nil, err
		}
		for _, m := range batch {
			if throughSeq == 0 || m.Seq <= throughSeq {
				history = append(history, m)
			}
		}
		if len(batch) < 500 || (throughSeq > 0 && batch[len(batch)-1].Seq >= throughSeq) {
			break
		}
		cursor = batch[len(batch)-1].Seq
	}
	user, err := a.store.UserByName(identity.Name)
	if err != nil {
		return nil, nil, err
	}
	aiID := int64(0)
	if user != nil {
		aiID = user.ID
	}
	payloads := map[string]map[string]any{}
	byID := map[string]store.Message{}
	replies := map[string]string{}
	latest := map[string]string{}
	lastQuestion := ""
	thread, err := a.store.AutomationThreadForUser(identity.Name, sender, conv)
	if err != nil {
		return nil, nil, err
	}
	for _, m := range history {
		p := map[string]any{}
		_ = json.Unmarshal(m.Payload, &p)
		payloads[m.ID], byID[m.ID] = p, m
		if m.SenderID != aiID {
			lastQuestion = m.ID
			continue
		}
		question, _ := p["reply_to"].(string)
		// 老版本独立对话的回复没有关联字段，保守关联最近的用户消息。
		if question == "" && thread != nil && p["context_standalone"] != true {
			question = lastQuestion
		}
		replies[m.ID] = question
		// 删除最新回复也不能让已被替代的旧回复重新进入上下文。
		if p["error"] != true && question != "" {
			latest[question] = m.ID
		}
	}
	states := map[string]contextVisibility{}
	entries := []contextEntry{}
	latestMatches := false
	for _, m := range history {
		p := payloads[m.ID]
		reason := ""
		switch {
		case p["deleted"] == true:
			reason = "已删除"
		case p["retracted"] == true:
			reason = "消息已撤回"
		case p["error"] == true:
			reason = "调用失败提示"
		}
		if reason == "" && m.SenderID == aiID {
			qid := replies[m.ID]
			if qid != "" {
				question, exists := byID[qid]
				qp := payloads[qid]
				switch {
				case !exists || qp["deleted"] == true || qp["retracted"] == true:
					reason = "原问题已撤回或删除"
				case latest[qid] != m.ID:
					reason = "已被重新生成的回复替代"
				default:
					if revision, ok := p["question_revision"].(float64); ok && int64(revision) != question.Revision {
						reason = "原问题已修改"
					}
				}
			}
		}
		if reason != "" {
			states[m.ID] = contextVisibility{Reason: reason}
			continue
		}
		body, _ := p["text"].(string)
		if body == "" {
			body = fmt.Sprintf("[%s] %v", m.Type, p["name"])
		}
		role := "user"
		if m.SenderID == aiID {
			role = "assistant"
		}
		content := fmt.Sprintf("[发送者: %s; 用户ID: %d; 时间: %s]\n%s", m.SenderName, m.SenderID, time.Unix(m.CreatedAt, 0).UTC().Format(time.RFC3339), body)
		entries = append(entries, contextEntry{m.ID, role, content})
		states[m.ID] = contextVisibility{Reason: "超出上下文字符预算"}
		latestMatches = role == "user" && m.SenderID == sender && body == prompt
	}
	if prompt != "" && !latestMatches {
		name := fmt.Sprint(sender)
		if u, _ := a.store.UserByID(sender); u != nil {
			name = u.DisplayName
		}
		entries = append(entries, contextEntry{role: "user", content: fmt.Sprintf("[当前提问者: %s; 用户ID: %d; 时间: %s]\n%s", name, sender, time.Now().UTC().Format(time.RFC3339), prompt)})
	}
	budget := identity.ContextMaxChars
	if budget <= 0 {
		budget = 60000
	}
	kept := []map[string]string{}
	for i := len(entries) - 1; i >= 0 && budget > 0; i-- {
		entry := entries[i]
		size := len([]rune(entry.content))
		state := contextVisibility{Included: true}
		if size > budget {
			header, body, found := strings.Cut(entry.content, "\n")
			headerSize := len([]rune(header)) + 1
			if !found || budget <= headerSize {
				break
			}
			entry.content = header + "\n" + truncateTail(body, budget-headerSize)
			size = budget
			state.Partial, state.Reason = true, "超出字符预算，仅保留末尾部分"
		}
		budget -= size
		if entry.id != "" {
			states[entry.id] = state
		}
		kept = append(kept, map[string]string{"role": entry.role, "content": entry.content})
	}
	for i, j := 0, len(kept)-1; i < j; i, j = i+1, j-1 {
		kept[i], kept[j] = kept[j], kept[i]
	}
	if thread != nil {
		for _, m := range history {
			state := states[m.ID]
			state.CanDelete = m.SenderID == aiID && !state.Included && payloads[m.ID]["deleted"] != true
			states[m.ID] = state
		}
	}
	return kept, states, nil
}

func (a *Server) ownedAPIThread(w http.ResponseWriter, r *http.Request) (*config.AutomationIdentity, int64, int64, bool) {
	identity := a.automationIdentity(r.PathValue("id"), "api")
	sender := auth.DeviceFrom(r.Context()).UserID
	conv, err := strconv.ParseInt(r.PathValue("conversationId"), 10, 64)
	if identity == nil || err != nil || conv <= 0 {
		fail(w, 404, "thread unavailable")
		return nil, 0, 0, false
	}
	if !identity.PrivateDirectory || (len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, sender)) {
		fail(w, 403, "not allowed")
		return nil, 0, 0, false
	}
	thread, err := a.store.AutomationThreadForUser(identity.Name, sender, conv)
	if err != nil {
		fail(w, 500, "cannot read thread")
		return nil, 0, 0, false
	}
	if thread == nil {
		fail(w, 403, "not your private thread")
		return nil, 0, 0, false
	}
	return identity, conv, sender, true
}

func (a *Server) automationContextVisibility(w http.ResponseWriter, r *http.Request) {
	identity, conv, sender, ok := a.ownedAPIThread(w, r)
	if !ok {
		return
	}
	_, states, err := a.contextPlan(identity, conv, sender, "", 0)
	if err != nil {
		fail(w, 500, "cannot read context")
		return
	}
	writeJSON(w, 200, map[string]any{"messages": states, "basis": "next_request_without_new_prompt"})
}

func (a *Server) deleteExcludedAutomationMessage(w http.ResponseWriter, r *http.Request) {
	identity, conv, sender, ok := a.ownedAPIThread(w, r)
	if !ok {
		return
	}
	_, states, err := a.contextPlan(identity, conv, sender, "", 0)
	if err != nil {
		fail(w, 500, "cannot read context")
		return
	}
	id := r.PathValue("messageId")
	state, exists := states[id]
	if !exists {
		fail(w, 404, "message unavailable")
		return
	}
	if !state.CanDelete {
		fail(w, 409, "only excluded AI replies can be deleted; refresh first")
		return
	}
	m, err := a.store.DeletePrivateThreadMessage(conv, sender, id)
	if err != nil {
		fail(w, 500, "cannot delete message")
		return
	}
	members, _ := a.store.ConvMemberIDs(conv)
	a.hub.BroadcastToUsers(members, map[string]any{"type": "message.updated", "message": m})
	writeJSON(w, 200, m)
}

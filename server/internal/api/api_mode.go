package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"quickconect/internal/auth"
	"quickconect/internal/config"
	"quickconect/internal/store"
)

func (a *Server) editMessage(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Text string `json:"text"`
	}
	if readJSON(w, r, &req) != nil {
		return
	}
	if strings.TrimSpace(req.Text) == "" || len([]rune(req.Text)) > 1000000 {
		fail(w, 400, "invalid message text")
		return
	}
	a.reviseMessage(w, r, &req.Text)
}
func (a *Server) retractMessage(w http.ResponseWriter, r *http.Request) { a.reviseMessage(w, r, nil) }
func (a *Server) reviseMessage(w http.ResponseWriter, r *http.Request, text *string) {
	dev := auth.DeviceFrom(r.Context())
	conv, err := pathID(w, r)
	if err != nil {
		return
	}
	if ok, _ := a.store.CanChat(conv, dev.UserID); !ok {
		fail(w, 403, "conversation unavailable")
		return
	}
	if a.automationConversationDisabled(conv, dev.UserID) {
		fail(w, 403, "automation conversations are disabled")
		return
	}
	m, err := a.store.ReviseMessage(conv, dev.UserID, r.PathValue("messageId"), text)
	if err != nil {
		code := 500
		if errors.Is(err, store.ErrForbidden) {
			code = 403
		} else if errors.Is(err, store.ErrNotFound) {
			code = 404
		} else if errors.Is(err, store.ErrInvalidMessage) {
			code = 400
		}
		fail(w, code, err.Error())
		return
	}
	members, _ := a.store.ConvMemberIDs(conv)
	a.hub.BroadcastToUsers(members, map[string]any{"type": "message.updated", "message": m})
	writeJSON(w, 200, m)
}
func (a *Server) messageChanges(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	conv, err := pathID(w, r)
	if err != nil {
		return
	}
	if ok, _ := a.store.CanChat(conv, dev.UserID); !ok {
		fail(w, 403, "conversation unavailable")
		return
	}
	if a.automationConversationDisabled(conv, dev.UserID) {
		fail(w, 403, "automation conversations are disabled")
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after_revision"), 10, 64)
	if after < 0 {
		after = 0
	}
	messages, next, more, err := a.store.MessageChanges(conv, after, 200)
	if err != nil {
		fail(w, 500, "cannot read revisions")
		return
	}
	writeJSON(w, 200, map[string]any{"messages": messages, "next_revision": next, "has_more": more})
}

func (a *Server) regenerateMessage(w http.ResponseWriter, r *http.Request) {
	identity := a.automationIdentity(r.PathValue("id"), "api")
	if identity == nil {
		fail(w, 404, "identity unavailable")
		return
	}
	dev := auth.DeviceFrom(r.Context())
	if len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, dev.UserID) {
		fail(w, 403, "user is not allowed")
		return
	}
	var req struct {
		ConversationID int64  `json:"conversation_id"`
		MessageID      string `json:"message_id"`
		ClientMsgID    string `json:"client_msg_id"`
	}
	if readJSON(w, r, &req) != nil {
		return
	}
	if req.ClientMsgID == "" {
		fail(w, 400, "client_msg_id required")
		return
	}
	if ok, _ := a.store.CanChat(req.ConversationID, dev.UserID); !ok {
		fail(w, 403, "conversation unavailable")
		return
	}
	if a.automationConversationDisabled(req.ConversationID, dev.UserID) {
		fail(w, 403, "automation conversations are disabled")
		return
	}
	question, err := a.store.MessageByID(req.ConversationID, req.MessageID)
	if err != nil || question == nil {
		fail(w, 404, "message not found")
		return
	}
	if question.SenderID != dev.UserID {
		fail(w, 403, "only your own question can be regenerated")
		return
	}
	var p struct {
		Text      string `json:"text"`
		Retracted bool   `json:"retracted"`
	}
	_ = json.Unmarshal(question.Payload, &p)
	if question.Type != "text" || p.Retracted || strings.TrimSpace(p.Text) == "" {
		fail(w, 400, "question unavailable")
		return
	}
	thread, err := a.store.AutomationThreadForUser(identity.Name, dev.UserID, req.ConversationID)
	if err != nil {
		fail(w, 500, "cannot read thread")
		return
	}
	if thread == nil && (!identity.MentionEnabled || !mentionsIdentity(p.Text, identity.Name, identity.DisplayName)) {
		fail(w, 400, "question does not mention identity")
		return
	}
	if thread != nil && !identity.PrivateDirectory {
		fail(w, 403, "private conversations are disabled")
		return
	}
	selectedModel := ""
	if thread != nil {
		selectedModel = thread.SelectedModel
	}
	models := a.apiModelCandidates(r.Context(), identity, selectedModel)
	if len(models) == 0 {
		fail(w, 400, "no model available")
		return
	}
	answer, model, err := a.callAPIModelThrough(r.Context(), identity, req.ConversationID, dev.UserID, p.Text, models, question.Seq)
	if err != nil {
		a.log.Warn("regenerate failed", "err", err)
		fail(w, 502, "all configured models failed")
		return
	}
	user, err := a.store.EnsureAutomationUser(identity.Name, identity.DisplayName)
	if err != nil {
		fail(w, 500, "identity unavailable")
		return
	}
	payload, _ := json.Marshal(map[string]any{"text": answer, "format": "markdown", "format_version": 1, "model": model, "reply_to": question.ID})
	m, err := a.store.InsertMessage(req.ConversationID, user.ID, "text", payload, req.ClientMsgID)
	if err != nil {
		fail(w, 500, "cannot save reply")
		return
	}
	m.SenderName = user.DisplayName
	m.SenderAvatarMediaID = user.AvatarMediaID
	members, _ := a.store.ConvMemberIDs(req.ConversationID)
	a.hub.BroadcastToUsers(members, map[string]any{"type": "message.new", "message": m})
	a.push.Notify(user.ID, user.DisplayName, members)
	writeJSON(w, 200, m)
}

func apiEndpoint(endpoint string) string {
	endpoint = strings.TrimRight(strings.TrimSpace(endpoint), "/")
	if strings.HasSuffix(endpoint, "/v1") {
		return endpoint + "/chat/completions"
	}
	if strings.HasSuffix(endpoint, "/chat/completions") {
		return endpoint
	}
	return endpoint + "/v1/chat/completions"
}

// An explicit choice is deterministic; only automatic mode uses fallbacks.
func (a *Server) apiModelCandidates(ctx context.Context, identity *config.AutomationIdentity, selected string) []string {
	if selected = strings.TrimSpace(selected); selected != "" {
		return []string{selected}
	}
	models := []string{}
	seen := map[string]bool{}
	for _, model := range append([]string{identity.DefaultModel}, identity.ModelFallbacks...) {
		model = strings.TrimSpace(model)
		if model != "" && !seen[model] {
			models = append(models, model)
			seen[model] = true
		}
	}
	if len(models) == 0 {
		models = a.availableModels(ctx, identity)
	}
	return models
}
func truncateTail(text string, budget int) string {
	runes := []rune(text)
	if budget <= 0 {
		return ""
	}
	if len(runes) > budget {
		return string(runes[len(runes)-budget:])
	}
	return text
}

// apiContext keeps complete metadata and recent bodies under one Unicode budget.
func (a *Server) apiContext(identity *config.AutomationIdentity, conv, sender int64, prompt string) ([]map[string]string, error) {
	return a.apiContextThrough(identity, conv, sender, prompt, 0)
}

func (a *Server) apiContextThrough(identity *config.AutomationIdentity, conv, sender int64, prompt string, throughSeq int64) ([]map[string]string, error) {
	budget := identity.ContextMaxChars
	if budget <= 0 {
		budget = 60000
	}
	thread, err := a.store.AutomationThreadForUser(identity.Name, sender, conv)
	if err != nil {
		return nil, err
	}
	system := identity.DirectSystemPrompt
	if thread == nil {
		system = config.DefaultMentionPrompt
		if identity.MentionSystemPrompt != nil {
			system = *identity.MentionSystemPrompt
		}
	} else {
		if !identity.PrivateDirectory {
			return nil, fmt.Errorf("private conversations are disabled")
		}
		if err = a.store.EnrichThread(thread); err != nil {
			return nil, err
		}
		if thread.SystemPrompt != nil {
			system = *thread.SystemPrompt
		}
	}
	messages := []map[string]string{}
	if system != "" {
		messages = append(messages, map[string]string{"role": "system", "content": system})
	}
	history, err := a.store.ContextHistoryThrough(conv, budget, throughSeq)
	if err != nil {
		return nil, err
	}
	user, _ := a.store.UserByName(identity.Name)
	entries := []map[string]string{}
	latestMatches := false
	for i, m := range history {
		var p map[string]any
		_ = json.Unmarshal(m.Payload, &p)
		body, _ := p["text"].(string)
		if body == "" {
			body = fmt.Sprintf("[%s] %v", m.Type, p["name"])
		}
		role := "user"
		if user != nil && m.SenderID == user.ID {
			role = "assistant"
		}
		content := fmt.Sprintf("[发送者: %s; 用户ID: %d; 时间: %s]\n%s", m.SenderName, m.SenderID, time.Unix(m.CreatedAt, 0).UTC().Format(time.RFC3339), body)
		entries = append(entries, map[string]string{"role": role, "content": content})
		if i == len(history)-1 && role == "user" && m.SenderID == sender && body == prompt {
			latestMatches = true
		}
	}
	if !latestMatches {
		senderUser, _ := a.store.UserByID(sender)
		name := fmt.Sprint(sender)
		if senderUser != nil {
			name = senderUser.DisplayName
		}
		entries = append(entries, map[string]string{"role": "user", "content": fmt.Sprintf("[当前提问者: %s; 用户ID: %d; 时间: %s]\n%s", name, sender, time.Now().UTC().Format(time.RFC3339), prompt)})
	}
	kept := []map[string]string{}
	remaining := budget
	for i := len(entries) - 1; i >= 0 && remaining > 0; i-- {
		entry := entries[i]
		n := len([]rune(entry["content"]))
		if n > remaining {
			header, body, found := strings.Cut(entry["content"], "\n")
			headerSize := len([]rune(header)) + 1
			if !found || remaining <= headerSize {
				break
			}
			entry["content"] = header + "\n" + truncateTail(body, remaining-headerSize)
			n = remaining
		}
		kept = append(kept, entry)
		remaining -= n
	}
	for i := len(kept) - 1; i >= 0; i-- {
		messages = append(messages, kept[i])
	}
	return messages, nil
}

// Model discovery happens only when requested, keeping the contact directory fast.
func (a *Server) listAutomationModels(w http.ResponseWriter, r *http.Request) {
	identity := a.automationIdentity(r.PathValue("id"), "api", "agent")
	if identity == nil {
		fail(w, 404, "identity unavailable")
		return
	}
	dev := auth.DeviceFrom(r.Context())
	if len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, dev.UserID) {
		fail(w, 403, "user is not allowed")
		return
	}
	models := []string{identity.DefaultModel}
	models = append(models, identity.ModelFallbacks...)
	if identity.Mode == "api" {
		ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel()
		models = append(models, a.availableModels(ctx, identity)...)
	}
	unique := []string{}
	seen := map[string]bool{}
	for _, model := range models {
		model = strings.TrimSpace(model)
		if model != "" && !seen[model] {
			seen[model] = true
			unique = append(unique, model)
		}
	}
	writeJSON(w, 200, map[string]any{"models": unique})
}

func (a *Server) callAPIModel(ctx context.Context, identity *config.AutomationIdentity, conv, sender int64, prompt string, models []string) (string, string, error) {
	return a.callAPIModelThrough(ctx, identity, conv, sender, prompt, models, 0)
}

func (a *Server) callAPIModelThrough(ctx context.Context, identity *config.AutomationIdentity, conv, sender int64, prompt string, models []string, throughSeq int64) (string, string, error) {
	if strings.TrimSpace(identity.Endpoint) == "" {
		return "", "", fmt.Errorf("missing API endpoint")
	}
	messages, err := a.apiContextThrough(identity, conv, sender, prompt, throughSeq)
	if err != nil {
		return "", "", err
	}
	return a.requestAPI(ctx, identity, messages, models)
}
func (a *Server) requestAPI(ctx context.Context, identity *config.AutomationIdentity, messages []map[string]string, models []string) (string, string, error) {
	client := &http.Client{Timeout: 45 * time.Second}
	var last error
	seen := map[string]bool{}
	for _, model := range models {
		model = strings.TrimSpace(model)
		if model == "" || seen[model] {
			continue
		}
		seen[model] = true
		raw, _ := json.Marshal(map[string]any{"model": model, "messages": messages})
		req, err := http.NewRequestWithContext(ctx, "POST", apiEndpoint(identity.Endpoint), bytes.NewReader(raw))
		if err != nil {
			last = err
			continue
		}
		req.Header.Set("Content-Type", "application/json")
		if identity.APIKey != "" {
			req.Header.Set("Authorization", "Bearer "+identity.APIKey)
		}
		resp, err := client.Do(req)
		if err != nil {
			last = err
			continue
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
		resp.Body.Close()
		if err != nil {
			last = err
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			last = fmt.Errorf("model %s returned %s: %s", model, resp.Status, compactAutomationError(body))
			continue
		}
		var out struct {
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if json.Unmarshal(body, &out) == nil && len(out.Choices) > 0 && strings.TrimSpace(out.Choices[0].Message.Content) != "" {
			return out.Choices[0].Message.Content, model, nil
		}
		last = fmt.Errorf("model %s returned no content", model)
	}
	if last == nil {
		last = fmt.Errorf("no model configured")
	}
	return "", "", last
}
func (a *Server) summarizeThread(ctx context.Context, id *config.AutomationIdentity, conv, sender int64, prompt, answer string, models []string) {
	thread, err := a.store.AutomationThreadForUser(id.Name, sender, conv)
	if err != nil || thread == nil || thread.Title != "" {
		return
	}
	if a.store.EnrichThread(thread) != nil || thread.TitleManual {
		return
	}
	titlePrompt := config.DefaultTitlePrompt
	if id.TitleSystemPrompt != nil {
		titlePrompt = *id.TitleSystemPrompt
	}
	messages := []map[string]string{}
	if titlePrompt != "" {
		messages = append(messages, map[string]string{"role": "system", "content": titlePrompt})
	}
	messages = append(messages, map[string]string{"role": "user", "content": truncateTail(prompt+"\n"+answer, 4000)})
	title, _, err := a.requestAPI(ctx, id, messages, models)
	if err != nil {
		a.log.Warn("thread title failed", "err", err)
		return
	}
	title = strings.Trim(strings.TrimSpace(title), "\"'\n ")
	if r := []rune(title); len(r) > 80 {
		title = string(r[:80])
	}
	if title != "" {
		if a.store.SetAutomaticTitle(thread.ID, title) == nil {
			members, _ := a.store.ConvMemberIDs(conv)
			a.hub.BroadcastToUsers(members, map[string]any{"type": "automation.thread.updated", "conversation_id": conv})
		}
	}
}

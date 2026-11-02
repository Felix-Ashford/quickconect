// Package api 组装全部 HTTP 路由与处理函数。
package api

import (
	"bytes"
	"context"
	"crypto/subtle"
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
	"unicode"
	"unicode/utf8"

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
	mux.Handle("PUT /api/me/avatar", authed(http.HandlerFunc(a.setAvatar)))
	mux.Handle("GET /api/device", authed(http.HandlerFunc(a.device)))
	mux.Handle("POST /api/push/test", authed(http.HandlerFunc(a.pushTest)))
	mux.Handle("GET /api/users", authed(http.HandlerFunc(a.users)))
	mux.Handle("GET /api/conversations", authed(http.HandlerFunc(a.listConversations)))
	mux.Handle("POST /api/conversations", authed(http.HandlerFunc(a.openDM)))
	mux.Handle("GET /api/conversations/{id}/messages", authed(http.HandlerFunc(a.getMessages)))
	mux.Handle("POST /api/conversations/{id}/messages", authed(http.HandlerFunc(a.sendMessage)))
	mux.Handle("POST /api/conversations/{id}/read", authed(http.HandlerFunc(a.markRead)))
	mux.Handle("POST /api/media", authed(http.HandlerFunc(a.uploadMedia)))
	mux.Handle("GET /api/media/{id}", authed(http.HandlerFunc(a.downloadMedia)))
	mux.HandleFunc("POST /api/automation/{id}/webhook", a.automationWebhook)
	mux.Handle("GET /api/automation", authed(http.HandlerFunc(a.listAutomations)))
	mux.Handle("GET /api/automation/{id}/models", authed(http.HandlerFunc(a.listAutomationModels)))
	mux.Handle("GET /api/automation/{id}/threads", authed(http.HandlerFunc(a.listAutomationThreads)))
	mux.Handle("POST /api/automation/{id}/threads", authed(http.HandlerFunc(a.createAutomationThread)))
	mux.Handle("POST /api/automation/{id}/invoke", authed(http.HandlerFunc(a.invokeAutomation)))
	mux.Handle("PUT /api/automation/{id}/threads/{conversationId}", authed(http.HandlerFunc(a.updateAutomationThread)))
	mux.Handle("DELETE /api/automation/{id}/threads/{conversationId}", authed(http.HandlerFunc(a.deleteAutomationThread)))
	mux.Handle("GET /api/automation/{id}/threads/{conversationId}/context", authed(http.HandlerFunc(a.automationContextVisibility)))
	mux.Handle("DELETE /api/automation/{id}/threads/{conversationId}/messages/{messageId}", authed(http.HandlerFunc(a.deleteExcludedAutomationMessage)))
	mux.Handle("PUT /api/conversations/{id}/messages/{messageId}", authed(http.HandlerFunc(a.editMessage)))
	mux.Handle("DELETE /api/conversations/{id}/messages/{messageId}", authed(http.HandlerFunc(a.retractMessage)))
	mux.Handle("GET /api/conversations/{id}/changes", authed(http.HandlerFunc(a.messageChanges)))
	mux.Handle("POST /api/automation/{id}/regenerate", authed(http.HandlerFunc(a.regenerateMessage)))

	return logRequests(log, mux)
}

func (a *Server) automationWebhook(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var identity *config.AutomationIdentity
	for i := range a.cfg.Automation.Identities {
		candidate := &a.cfg.Automation.Identities[i]
		if candidate.ID == id || candidate.Name == id {
			identity = candidate
			break
		}
	}
	if identity == nil || !identity.Enabled || identity.Mode != "push" {
		fail(w, http.StatusNotFound, "automation identity unavailable")
		return
	}
	token := r.Header.Get("Authorization")
	if !strings.HasPrefix(token, "Bearer ") || identity.WebhookToken == "" || subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(token, "Bearer ")), []byte(identity.WebhookToken)) != 1 {
		fail(w, http.StatusUnauthorized, "invalid automation token")
		return
	}
	var req struct {
		ClientMsgID    string          `json:"client_msg_id"`
		ConversationID int64           `json:"conversation_id"`
		UserID         int64           `json:"user_id"`
		Type           string          `json:"type"`
		Payload        json.RawMessage `json:"payload"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	if req.ClientMsgID == "" || !allowedMessageTypes[req.Type] || !json.Valid(req.Payload) {
		fail(w, http.StatusBadRequest, "invalid push message")
		return
	}
	if req.ConversationID == 0 && req.UserID == 0 {
		fail(w, http.StatusBadRequest, "conversation_id or user_id is required")
		return
	}
	if req.ConversationID < 0 || req.UserID < 0 || (req.ConversationID > 0 && req.UserID > 0) {
		fail(w, http.StatusBadRequest, "choose exactly one target")
		return
	}
	if !pushTargetAllowed(identity.PushTargets, req.UserID > 0) {
		fail(w, http.StatusForbidden, "push target is disabled")
		return
	}
	if req.UserID != 0 && !containsID(identity.AllowedUsers, req.UserID) && len(identity.AllowedUsers) > 0 {
		fail(w, http.StatusForbidden, "user is not allowed")
		return
	}
	identityUser, err := a.store.UserByName(identity.Name)
	if err != nil || identityUser == nil {
		fail(w, http.StatusInternalServerError, "automation identity is not initialized")
		return
	}
	if req.UserID > 0 {
		u, err := a.store.UserByID(req.UserID)
		if err != nil || u == nil || u.ID == identityUser.ID {
			fail(w, http.StatusBadRequest, "invalid target user")
			return
		}
	} else {
		members, err := a.store.ConvMemberIDs(req.ConversationID)
		if err != nil || len(members) == 0 {
			fail(w, http.StatusBadRequest, "invalid target conversation")
			return
		}
		if len(identity.AllowedUsers) > 0 {
			for _, member := range members {
				if member == identityUser.ID {
					continue
				}
				if !containsID(identity.AllowedUsers, member) {
					fail(w, http.StatusForbidden, "conversation includes a user who is not allowed")
					return
				}
			}
		}
	}
	if req.ConversationID == 0 {
		if req.UserID == 0 {
			fail(w, http.StatusBadRequest, "conversation_id or user_id is required")
			return
		}
		req.ConversationID, err = a.store.GetOrCreateDM(identityUser.ID, req.UserID)
		if err != nil {
			fail(w, http.StatusInternalServerError, "cannot create target conversation")
			return
		}
	}
	if req.UserID != 0 {
		if ok, _ := a.store.IsMember(req.ConversationID, req.UserID); !ok {
			fail(w, http.StatusForbidden, "user is not a conversation member")
			return
		}
	}
	msg, err := a.store.InsertMessage(req.ConversationID, identityUser.ID, req.Type, req.Payload, req.ClientMsgID)
	if err != nil {
		fail(w, http.StatusConflict, "message already exists or cannot be inserted")
		return
	}
	msg.SenderName = identityUser.DisplayName
	msg.SenderAvatarMediaID = identityUser.AvatarMediaID
	memberIDs, _ := a.store.ConvMemberIDs(req.ConversationID)
	a.hub.BroadcastToUsers(memberIDs, map[string]any{"type": "message.new", "message": msg})
	a.push.Notify(identityUser.ID, identityUser.DisplayName, memberIDs)
	writeJSON(w, http.StatusOK, msg)
}

func (a *Server) automationIdentity(id string, modes ...string) *config.AutomationIdentity {
	for i := range a.cfg.Automation.Identities {
		item := &a.cfg.Automation.Identities[i]
		if (item.ID == id || item.Name == id) && item.Enabled {
			if len(modes) == 0 {
				return item
			}
			for _, mode := range modes {
				if item.Mode == mode {
					return item
				}
			}
		}
	}
	return nil
}

func (a *Server) listAutomations(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	type publicIdentity struct {
		UserID              int64    `json:"user_id"`
		AvatarMediaID       string   `json:"avatar_media_id"`
		ContextMaxChars     int      `json:"context_max_chars"`
		DefaultSystemPrompt string   `json:"default_system_prompt"`
		MentionEnabled      bool     `json:"mention_enabled"`
		ID                  string   `json:"id"`
		Name                string   `json:"name"`
		DisplayName         string   `json:"display_name"`
		Mode                string   `json:"mode"`
		Models              []string `json:"models"`
		DefaultModel        string   `json:"default_model"`
		PrivateDirectory    bool     `json:"private_directory"`
	}
	items := []publicIdentity{}
	for i := range a.cfg.Automation.Identities {
		id := a.cfg.Automation.Identities[i]
		if !id.Enabled || (id.Mode != "api" && id.Mode != "agent") || (len(id.AllowedUsers) > 0 && !containsID(id.AllowedUsers, dev.UserID)) {
			continue
		}
		models := append([]string{}, id.ModelFallbacks...)
		if id.DefaultModel != "" {
			models = append([]string{id.DefaultModel}, models...)
		}
		u, err := a.store.EnsureAutomationUser(id.Name, id.DisplayName)
		if err != nil {
			continue
		}
		if id.AvatarMediaID != u.AvatarMediaID {
			if a.store.SetUserAvatar(u.ID, id.AvatarMediaID) == nil {
				u.AvatarMediaID = id.AvatarMediaID
			}
		}
		items = append(items, publicIdentity{ID: id.ID, Name: id.Name, DisplayName: id.DisplayName, Mode: id.Mode, Models: models, DefaultModel: id.DefaultModel, PrivateDirectory: id.PrivateDirectory, UserID: u.ID, AvatarMediaID: u.AvatarMediaID, ContextMaxChars: id.ContextMaxChars, DefaultSystemPrompt: id.DirectSystemPrompt, MentionEnabled: id.MentionEnabled})
	}
	writeJSON(w, http.StatusOK, items)
}

func (a *Server) listAutomationThreads(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	id := a.automationIdentity(r.PathValue("id"), "api", "agent")
	if id == nil {
		fail(w, http.StatusNotFound, "automation identity unavailable")
		return
	}
	if len(id.AllowedUsers) > 0 && !containsID(id.AllowedUsers, dev.UserID) {
		fail(w, http.StatusForbidden, "user is not allowed")
		return
	}
	if !id.PrivateDirectory {
		fail(w, http.StatusForbidden, "private conversations are disabled")
		return
	}
	threads, err := a.store.AutomationThreads(id.Name, dev.UserID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "cannot list automation threads")
		return
	}
	for i := range threads {
		if err := a.store.EnrichThread(&threads[i]); err != nil {
			fail(w, 500, "cannot read thread settings")
			return
		}
	}
	writeJSON(w, http.StatusOK, threads)
}

func (a *Server) createAutomationThread(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	id := a.automationIdentity(r.PathValue("id"), "api", "agent")
	if id == nil {
		fail(w, http.StatusNotFound, "automation identity unavailable")
		return
	}
	if len(id.AllowedUsers) > 0 && !containsID(id.AllowedUsers, dev.UserID) {
		fail(w, http.StatusForbidden, "user is not allowed")
		return
	}
	if !id.PrivateDirectory {
		fail(w, http.StatusForbidden, "private conversations are disabled")
		return
	}
	var req struct {
		Title string `json:"title"`
		Model string `json:"model"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	identityUser, err := a.store.EnsureAutomationUser(id.Name, id.DisplayName)
	if err != nil {
		fail(w, http.StatusInternalServerError, "automation identity is not initialized")
		return
	}
	convID, err := a.store.CreatePrivateConversation(dev.UserID, identityUser.ID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "cannot create automation conversation")
		return
	}
	thread, err := a.store.CreateAutomationThread(id.Name, dev.UserID, convID, strings.TrimSpace(req.Title), strings.TrimSpace(req.Model))
	if err != nil {
		fail(w, http.StatusInternalServerError, "cannot create automation thread")
		return
	}
	thread.TitleManual = thread.Title != ""
	if err = a.store.SaveThreadSettings(thread); err != nil {
		fail(w, 500, "cannot save settings")
		return
	}
	writeJSON(w, http.StatusCreated, thread)
}

func (a *Server) updateAutomationThread(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	id := a.automationIdentity(r.PathValue("id"), "api", "agent")
	if id == nil {
		fail(w, http.StatusNotFound, "automation identity unavailable")
		return
	}
	if len(id.AllowedUsers) > 0 && !containsID(id.AllowedUsers, dev.UserID) {
		fail(w, http.StatusForbidden, "user is not allowed")
		return
	}
	if !id.PrivateDirectory {
		fail(w, http.StatusForbidden, "private conversations are disabled")
		return
	}
	convID, err := strconv.ParseInt(r.PathValue("conversationId"), 10, 64)
	if err != nil || convID <= 0 {
		fail(w, http.StatusBadRequest, "invalid conversation")
		return
	}
	if ok, _ := a.store.IsMember(convID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "not a conversation member")
		return
	}
	var req map[string]json.RawMessage
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	thread, threadErr := a.store.AutomationThreadForUser(id.Name, dev.UserID, convID)
	if threadErr != nil || thread == nil {
		fail(w, http.StatusNotFound, "automation thread not found")
		return
	}
	if err = a.store.EnrichThread(thread); err != nil {
		fail(w, 500, "cannot read thread settings")
		return
	}
	if raw, ok := req["title"]; ok {
		var title string
		if json.Unmarshal(raw, &title) != nil {
			fail(w, 400, "invalid title")
			return
		}
		thread.Title = strings.TrimSpace(title)
		thread.TitleManual = true
	}
	if raw, ok := req["model"]; ok {
		if json.Unmarshal(raw, &thread.SelectedModel) != nil {
			fail(w, 400, "invalid model")
			return
		}
		thread.SelectedModel = strings.TrimSpace(thread.SelectedModel)
		if thread.SelectedModel == "" {
			thread.SelectedModels = []string{}
		} else {
			thread.SelectedModels = []string{thread.SelectedModel}
		}
	}
	if raw, ok := req["models"]; ok {
		var models []string
		if json.Unmarshal(raw, &models) != nil || len(models) > 64 {
			fail(w, 400, "invalid models")
			return
		}
		thread.SelectedModels = uniqueModels(models)
		thread.SelectedModel = ""
		if len(thread.SelectedModels) > 0 {
			thread.SelectedModel = thread.SelectedModels[0]
		}
	}
	if raw, ok := req["system_prompt"]; ok {
		if json.Unmarshal(raw, &thread.SystemPrompt) != nil {
			fail(w, 400, "invalid system prompt")
			return
		}
	}
	if err := a.store.SaveThreadSettings(*thread); err != nil {
		fail(w, http.StatusInternalServerError, "cannot update automation thread")
		return
	}
	members, _ := a.store.ConvMemberIDs(convID)
	a.hub.BroadcastToUsers(members, map[string]any{"type": "automation.thread.updated", "conversation_id": convID})
	writeJSON(w, http.StatusOK, thread)
}

func (a *Server) deleteAutomationThread(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	id := a.automationIdentity(r.PathValue("id"), "api", "agent")
	if id == nil {
		fail(w, http.StatusNotFound, "automation identity unavailable")
		return
	}
	if len(id.AllowedUsers) > 0 && !containsID(id.AllowedUsers, dev.UserID) {
		fail(w, http.StatusForbidden, "user is not allowed")
		return
	}
	if !id.PrivateDirectory {
		fail(w, http.StatusForbidden, "private conversations are disabled")
		return
	}
	convID, err := strconv.ParseInt(r.PathValue("conversationId"), 10, 64)
	if err != nil || convID <= 0 {
		fail(w, http.StatusBadRequest, "invalid conversation")
		return
	}
	members, _ := a.store.ConvMemberIDs(convID)
	if err := a.store.DeleteAutomationThread(id.Name, dev.UserID, convID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			fail(w, http.StatusNotFound, "automation thread not found")
		} else {
			fail(w, http.StatusInternalServerError, "cannot delete automation thread")
		}
		return
	}
	a.hub.BroadcastToUsers(members, map[string]any{"type": "automation.thread.deleted", "conversation_id": convID})
	w.WriteHeader(http.StatusNoContent)
}

func containsID(ids []int64, id int64) bool {
	for _, candidate := range ids {
		if candidate == id {
			return true
		}
	}
	return false
}

func pushTargetAllowed(configured string, userTarget bool) bool {
	configured = strings.TrimSpace(strings.ToLower(configured))
	if configured == "" || configured == "both" {
		return true
	}
	for _, item := range strings.Split(configured, ",") {
		item = strings.TrimSpace(item)
		if (userTarget && item == "user") || (!userTarget && item == "conversation") {
			return true
		}
	}
	return false
}

func (a *Server) invokeAutomation(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var identity *config.AutomationIdentity
	for i := range a.cfg.Automation.Identities {
		if a.cfg.Automation.Identities[i].ID == id || a.cfg.Automation.Identities[i].Name == id {
			identity = &a.cfg.Automation.Identities[i]
			break
		}
	}
	if identity == nil || !identity.Enabled || (identity.Mode != "api" && identity.Mode != "agent") {
		fail(w, http.StatusNotFound, "automation identity unavailable")
		return
	}
	dev := auth.DeviceFrom(r.Context())
	if len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, dev.UserID) {
		fail(w, http.StatusForbidden, "user is not allowed")
		return
	}
	var req struct {
		ConversationID int64  `json:"conversation_id"`
		Prompt         string `json:"prompt"`
		Model          string `json:"model"`
		ClientMsgID    string `json:"client_msg_id"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	if req.ConversationID <= 0 || strings.TrimSpace(req.Prompt) == "" || req.ClientMsgID == "" {
		fail(w, http.StatusBadRequest, "conversation_id, prompt and client_msg_id are required")
		return
	}
	if ok, _ := a.store.CanChat(req.ConversationID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "not a conversation member")
		return
	}
	thread, threadErr := a.store.AutomationThreadForUser(identity.Name, dev.UserID, req.ConversationID)
	if threadErr != nil {
		fail(w, 500, "cannot read thread")
		return
	}
	if a.automationConversationDisabled(req.ConversationID, dev.UserID) {
		fail(w, 403, "automation conversations are disabled")
		return
	}
	if thread != nil {
		if !identity.PrivateDirectory {
			fail(w, 403, "private conversations are disabled")
			return
		}
		if strings.TrimSpace(req.Model) == "" && len(thread.SelectedModels) == 0 {
			req.Model = thread.SelectedModel
		}
	}
	identityUser, err := a.store.EnsureAutomationUser(identity.Name, identity.DisplayName)
	if err != nil {
		fail(w, http.StatusInternalServerError, "automation identity is not initialized")
		return
	}
	models := make([]string, 0, 1+len(identity.ModelFallbacks))
	if strings.TrimSpace(req.Model) != "" {
		models = append(models, strings.TrimSpace(req.Model))
	} else if strings.TrimSpace(identity.DefaultModel) != "" {
		models = append(models, strings.TrimSpace(identity.DefaultModel))
	}
	for _, model := range identity.ModelFallbacks {
		if strings.TrimSpace(model) != "" {
			models = append(models, strings.TrimSpace(model))
		}
	}
	if identity.Mode == "api" {
		if thread != nil && strings.TrimSpace(req.Model) == "" {
			models = a.apiModelCandidatesForThread(r.Context(), identity, thread)
		} else {
			models = a.apiModelCandidates(r.Context(), identity, req.Model)
		}
	}
	if len(models) == 0 && identity.Mode == "agent" {
		models = append(models, "default")
	}
	if len(models) == 0 {
		fail(w, http.StatusBadRequest, "no model configured")
		return
	}
	answer, usedModel, callErr := a.callCompatibleModel(r.Context(), identity, req.ConversationID, dev.UserID, req.Prompt, models)
	if callErr != nil {
		a.log.Warn("automation model failed", "identity", identity.Name, "err", callErr)
		fail(w, http.StatusBadGateway, "all configured models failed")
		return
	}
	// 此入口的 prompt 不一定持久化，不能把回复误关联到更早的用户消息。
	payload, _ := json.Marshal(map[string]any{"text": answer, "format": "markdown", "format_version": 1, "model": usedModel, "context_standalone": true})
	msg, err := a.store.InsertMessage(req.ConversationID, identityUser.ID, "text", payload, req.ClientMsgID)
	if err != nil {
		fail(w, http.StatusConflict, "message already exists or cannot be inserted")
		return
	}
	msg.SenderName = identityUser.DisplayName
	msg.SenderAvatarMediaID = identityUser.AvatarMediaID
	memberIDs, _ := a.store.ConvMemberIDs(req.ConversationID)
	a.hub.BroadcastToUsers(memberIDs, map[string]any{"type": "message.new", "message": msg})
	a.push.Notify(identityUser.ID, identityUser.DisplayName, memberIDs)
	writeJSON(w, http.StatusOK, msg)
}

func (a *Server) callCompatibleModel(ctx context.Context, identity *config.AutomationIdentity, convID, senderID int64, prompt string, models []string) (string, string, error) {
	endpoint := strings.TrimRight(strings.TrimSpace(identity.Endpoint), "/")
	if endpoint == "" {
		return "", "", fmt.Errorf("missing API endpoint (CLI Proxy management URL is not an API endpoint)")
	}
	if strings.HasSuffix(endpoint, "/v1") {
		endpoint += "/chat/completions"
	} else if !strings.HasSuffix(endpoint, "/chat/completions") {
		endpoint += "/v1/chat/completions"
	}
	if identity.Mode == "api" {
		return a.callAPIModel(ctx, identity, convID, senderID, prompt, models)
	}
	history, _ := a.store.MessagesRecent(convID, 30)
	messages := make([]map[string]string, 0, len(history)+1)
	if identity.Mode == "agent" {
		members, err := a.store.ConvMemberIDs(convID)
		if err != nil {
			return "", "", fmt.Errorf("cannot read agent conversation members: %w", err)
		}
		meta, _ := json.Marshal(map[string]any{
			"identity": identity.ID, "user_id": senderID, "conversation_id": convID,
			"recipient_user_ids": members, "memory_enabled": identity.MemoryEnabled,
			"web_search_enabled": identity.WebSearchEnabled, "server_control_enabled": identity.ServerControlEnabled,
		})
		messages = append(messages, map[string]string{"role": "system", "content": "QuickConect agent context: " + string(meta)})
	}
	identityUser, _ := a.store.UserByName(identity.Name)
	for _, item := range history {
		var meta struct {
			Error bool `json:"error"`
		}
		if json.Unmarshal(item.Payload, &meta) == nil && meta.Error {
			continue
		}
		role := "user"
		if identityUser != nil && item.SenderID == identityUser.ID {
			role = "assistant"
		}
		content := string(item.Payload)
		var payload struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(item.Payload, &payload) == nil && payload.Text != "" {
			content = payload.Text
		}
		message := map[string]string{"role": role, "content": content}
		if identity.Mode == "agent" && role == "user" {
			message["name"] = fmt.Sprintf("user_%d", item.SenderID)
		}
		messages = append(messages, message)
	}
	// Mention-triggered requests are already persisted as the latest user
	// message. Avoid adding the same text twice to the model context. Direct
	// invocations still append their prompt because they are not persisted by
	// the invoke endpoint.
	if len(messages) == 0 || messages[len(messages)-1]["role"] != "user" || messages[len(messages)-1]["content"] != prompt {
		message := map[string]string{"role": "user", "content": prompt}
		if identity.Mode == "agent" {
			message["name"] = fmt.Sprintf("user_%d", senderID)
		}
		messages = append(messages, message)
	}
	client := &http.Client{Timeout: 45 * time.Second}
	var last error
	for _, model := range models {
		body, _ := json.Marshal(map[string]any{"model": model, "messages": messages})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
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
			last = fmt.Errorf("model %s request failed: %w", model, err)
			continue
		}
		raw, readErr := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
		resp.Body.Close()
		if readErr != nil {
			last = fmt.Errorf("model %s response read failed: %w", model, readErr)
			continue
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			last = fmt.Errorf("model %s returned %s: %s", model, resp.Status, compactAutomationError(raw))
			continue
		}
		var out struct {
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if json.Unmarshal(raw, &out) == nil && len(out.Choices) > 0 && strings.TrimSpace(out.Choices[0].Message.Content) != "" {
			return out.Choices[0].Message.Content, model, nil
		}
		last = fmt.Errorf("model %s returned no content: %s", model, compactAutomationError(raw))
	}
	return "", "", last
}

func (a *Server) availableModels(ctx context.Context, identity *config.AutomationIdentity) []string {
	endpoint := strings.TrimRight(strings.TrimSpace(identity.Endpoint), "/")
	if endpoint == "" {
		a.log.Warn("automation model discovery skipped: API endpoint is empty", "identity", identity.Name, "management_url_configured", strings.TrimSpace(identity.CLIProxyURL) != "")
		return nil
	}
	base := strings.TrimSuffix(strings.TrimSuffix(endpoint, "/chat/completions"), "/v1")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/v1/models", nil)
	if err != nil {
		return nil
	}
	if identity.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+identity.APIKey)
	}
	resp, err := (&http.Client{Timeout: 8 * time.Second}).Do(req)
	if err != nil {
		a.log.Warn("automation model discovery request failed", "identity", identity.Name, "url", req.URL.String(), "err", err)
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 32<<10))
		a.log.Warn("automation model discovery returned error", "identity", identity.Name, "status", resp.Status, "body", compactAutomationError(raw))
		return nil
	}
	var catalog struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&catalog); err != nil {
		a.log.Warn("automation model discovery returned invalid JSON", "identity", identity.Name, "err", err)
		return nil
	}
	models := make([]string, 0, len(catalog.Data))
	for _, model := range catalog.Data {
		if strings.TrimSpace(model.ID) != "" {
			models = append(models, model.ID)
		}
	}
	a.log.Info("automation models discovered", "identity", identity.Name, "count", len(models))
	return models
}

func compactAutomationError(raw []byte) string {
	s := strings.TrimSpace(string(raw))
	runes := []rune(s)
	if len(runes) > 512 {
		s = string(runes[:512]) + "..."
	}
	return s
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

func (a *Server) setAvatar(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	var req struct {
		MediaID string `json:"media_id"`
	}
	if err := readJSON(w, r, &req); err != nil {
		return
	}
	if req.MediaID != "" {
		media, err := a.store.MediaByID(req.MediaID)
		if err != nil || media == nil || media.OwnerID != dev.UserID || !strings.HasPrefix(media.Mime, "image/") {
			fail(w, http.StatusBadRequest, "invalid avatar media")
			return
		}
	}
	if err := a.store.SetUserAvatar(dev.UserID, req.MediaID); err != nil {
		fail(w, http.StatusInternalServerError, "server error")
		return
	}
	u, err := a.store.UserByID(dev.UserID)
	if err != nil || u == nil {
		fail(w, http.StatusInternalServerError, "server error")
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

// pushTest sends a test notification through the configured push transport.
func (a *Server) pushTest(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	if err := a.push.PublishTest(dev.UserID); err != nil {
		a.log.Warn("push test failed", "device_id", dev.ID, "err", err)
		fail(w, http.StatusBadGateway, "push failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *Server) users(w http.ResponseWriter, _ *http.Request) {
	us, err := a.store.ListUsers()
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	// Service identities are selected through the automation directory. Keep
	// them out of the ordinary contact picker while preserving their normal
	// user/message representation in conversations.
	filtered := make([]store.User, 0, len(us))
	for _, user := range us {
		isAutomation := false
		for _, identity := range a.cfg.Automation.Identities {
			if identity.Name == user.Name {
				isAutomation = true
				break
			}
		}
		if !isAutomation {
			filtered = append(filtered, user)
		}
	}
	writeJSON(w, http.StatusOK, filtered)
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
	for i := range a.cfg.Automation.Identities {
		identity := &a.cfg.Automation.Identities[i]
		if identity.Name != peer.Name || (identity.Mode != "api" && identity.Mode != "agent") {
			continue
		}
		if !identity.Enabled || !identity.PrivateDirectory {
			fail(w, http.StatusForbidden, "private conversations are disabled")
			return
		}
		if len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, dev.UserID) {
			fail(w, http.StatusForbidden, "user is not allowed")
			return
		}
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
	filtered := make([]store.ConvSummary, 0, len(convs))
	for _, conversation := range convs {
		if !a.automationConversationDisabled(conversation.ID, dev.UserID) {
			filtered = append(filtered, conversation)
		}
	}
	writeJSON(w, http.StatusOK, filtered)
}

func (a *Server) getMessages(w http.ResponseWriter, r *http.Request) {
	dev := auth.DeviceFrom(r.Context())
	convID, err := pathID(w, r)
	if err != nil {
		return
	}
	if ok, _ := a.store.CanChat(convID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "conversation unavailable; the other user may have been deleted")
		return
	}
	afterSeq, _ := strconv.ParseInt(r.URL.Query().Get("after_seq"), 10, 64)
	if a.automationConversationDisabled(convID, dev.UserID) {
		fail(w, 403, "automation conversations are disabled")
		return
	}
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

func (a *Server) automationConversationDisabled(convID, userID int64) bool {
	members, err := a.store.ConvMemberIDs(convID)
	if err != nil {
		return true
	}
	for i := range a.cfg.Automation.Identities {
		identity := &a.cfg.Automation.Identities[i]
		if identity.Mode == "push" {
			continue
		}
		if !identity.Enabled || !identity.PrivateDirectory || (len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, userID)) {
			user, lookupErr := a.store.UserByName(identity.Name)
			if lookupErr != nil || user == nil {
				continue
			}
			for _, member := range members {
				if member == user.ID {
					return true
				}
			}
		}
	}
	return false
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
	if ok, _ := a.store.CanChat(convID, dev.UserID); !ok {
		fail(w, http.StatusForbidden, "conversation unavailable; the other user may have been deleted")
		return
	}
	if a.automationConversationDisabled(convID, dev.UserID) {
		fail(w, http.StatusForbidden, "automation conversations are disabled")
		return
	}
	sender, _ := a.store.UserByID(dev.UserID)
	msg, err := a.store.InsertMessage(convID, dev.UserID, req.Type, req.Payload, req.ClientMsgID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "服务器错误")
		return
	}
	msg.SenderName = sender.DisplayName
	msg.SenderAvatarMediaID = sender.AvatarMediaID

	memberIDs, _ := a.store.ConvMemberIDs(convID)
	a.hub.BroadcastToUsers(memberIDs, map[string]any{"type": "message.new", "message": msg})
	a.push.Notify(dev.UserID, sender.DisplayName, memberIDs)
	// Mentions are handled asynchronously so a slow model never delays the
	// sender's message acknowledgement. Only identities explicitly configured
	// for mentions are considered.
	a.triggerMentionAutomations(convID, dev.UserID, req.Type, req.Payload, msg.Seq)
	writeJSON(w, http.StatusOK, msg)
}

func (a *Server) triggerMentionAutomations(convID, senderID int64, typ string, payload json.RawMessage, questionSeq int64) {
	if typ != "text" {
		return
	}
	var body struct {
		Text string `json:"text"`
	}
	if json.Unmarshal(payload, &body) != nil || strings.TrimSpace(body.Text) == "" {
		return
	}
	for i := range a.cfg.Automation.Identities {
		identity := a.cfg.Automation.Identities[i]
		if !identity.Enabled || (identity.Mode != "api" && identity.Mode != "agent") {
			continue
		}
		if len(identity.AllowedUsers) > 0 && !containsID(identity.AllowedUsers, senderID) {
			continue
		}
		thread, threadErr := a.store.AutomationThreadForUser(identity.Name, senderID, convID)
		directThread := threadErr == nil && thread != nil
		if directThread && !identity.PrivateDirectory {
			continue
		}
		if !directThread && (!identity.MentionEnabled || !mentionsIdentity(body.Text, identity.Name, identity.DisplayName)) {
			continue
		}
		if identity.Mode == "agent" && strings.TrimSpace(identity.Endpoint) == "" {
			a.log.Warn("agent mention failed: external runtime endpoint is not configured", "identity", identity.Name)
			a.publishAutomationError(identity, convID, "无法调用自动化身份：Agent 运行时尚未配置 API 地址。")
			continue
		}
		selectedModel := ""
		var selectedModels []string
		if directThread {
			selectedModel = thread.SelectedModel
			selectedModels = thread.SelectedModels
		}
		go a.invokeMention(identity, convID, senderID, body.Text, selectedModel, selectedModels, questionSeq)
	}
}

func mentionsIdentity(text string, names ...string) bool {
	lower := strings.ToLower(text)
	for _, name := range names {
		name = strings.ToLower(strings.TrimSpace(name))
		if name == "" {
			continue
		}
		needle := "@" + name
		for offset := 0; offset < len(lower); {
			index := strings.Index(lower[offset:], needle)
			if index < 0 {
				break
			}
			start := offset + index
			end := start + len(needle)
			beforeOK := start == 0
			if start > 0 {
				r, _ := utf8.DecodeLastRuneInString(lower[:start])
				beforeOK = unicode.IsSpace(r) || strings.ContainsRune("([{（【，。！？,:;!?", r)
			}
			afterOK := end == len(lower)
			if end < len(lower) {
				r, _ := utf8.DecodeRuneInString(lower[end:])
				afterOK = unicode.IsSpace(r) || strings.ContainsRune(")]},.，。！？:;!?：；、", r)
			}
			if beforeOK && afterOK {
				return true
			}
			offset = end
		}
	}
	return false
}

func (a *Server) invokeMention(identity config.AutomationIdentity, convID, senderID int64, prompt, selectedModel string, selectedModels []string, questionSeq int64) {
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	models := make([]string, 0, 1+len(identity.ModelFallbacks))
	if strings.TrimSpace(selectedModel) != "" {
		models = append(models, strings.TrimSpace(selectedModel))
	}
	if strings.TrimSpace(identity.DefaultModel) != "" {
		models = append(models, strings.TrimSpace(identity.DefaultModel))
	}
	for _, model := range identity.ModelFallbacks {
		if strings.TrimSpace(model) != "" {
			models = append(models, strings.TrimSpace(model))
		}
	}
	if len(models) == 0 && identity.Mode == "agent" {
		models = append(models, "default")
	}
	if identity.Mode == "api" {
		if len(selectedModels) > 0 {
			models = uniqueModels(selectedModels)
		} else {
			models = a.apiModelCandidates(ctx, &identity, selectedModel)
		}
	}
	if len(models) == 0 {
		err := fmt.Errorf("no model configured or model discovery failed")
		a.log.Warn("automation mention skipped", "identity", identity.Name, "err", err)
		a.publishAutomationError(identity, convID, "无法调用自动化身份：未找到可用模型。请在 Manager 中填写 API 地址，并确认 CLI Proxy API 正在运行且 API 密钥正确。")
		return
	}
	identityUser, err := a.store.EnsureAutomationUser(identity.Name, identity.DisplayName)
	if err != nil {
		a.log.Warn("automation identity initialization failed", "identity", identity.Name, "err", err)
		return
	}
	var answer, usedModel string
	question, _ := a.store.MessageBySeq(convID, questionSeq)
	if identity.Mode == "api" {
		answer, usedModel, err = a.callAPIModelThrough(ctx, &identity, convID, senderID, prompt, models, questionSeq)
	} else {
		answer, usedModel, err = a.callCompatibleModel(ctx, &identity, convID, senderID, prompt, models)
	}
	if err != nil {
		a.log.Warn("automation mention failed", "identity", identity.Name, "err", err)
		a.publishAutomationError(identity, convID, "无法调用自动化身份：模型服务暂时不可用，请检查 API 地址、密钥和模型配置。")
		return
	}
	replyTo := ""
	questionRevision := int64(0)
	if question != nil {
		replyTo, questionRevision = question.ID, question.Revision
	}
	payload, _ := json.Marshal(map[string]any{"text": answer, "format": "markdown", "format_version": 1, "model": usedModel, "reply_to": replyTo, "question_revision": questionRevision})
	clientMsgID := fmt.Sprintf("mention-%d-%d-%d", convID, senderID, time.Now().UnixNano())
	msg, err := a.store.InsertMessage(convID, identityUser.ID, "text", payload, clientMsgID)
	if err != nil {
		a.log.Warn("automation mention save failed", "identity", identity.Name, "err", err)
		return
	}
	msg.SenderName = identityUser.DisplayName
	msg.SenderAvatarMediaID = identityUser.AvatarMediaID
	members, _ := a.store.ConvMemberIDs(convID)
	a.hub.BroadcastToUsers(members, map[string]any{"type": "message.new", "message": msg})
	a.push.Notify(identityUser.ID, identityUser.DisplayName, members)
	if identity.Mode == "api" {
		titleCtx, titleCancel := context.WithTimeout(context.Background(), 50*time.Second)
		defer titleCancel()
		a.summarizeThread(titleCtx, &identity, convID, senderID, prompt, answer, models)
	}
}

// publishAutomationError keeps asynchronous mention failures visible to the
// user. The original request has already been acknowledged, so a server log
// alone would look like a silent failure in every client.
func (a *Server) publishAutomationError(identity config.AutomationIdentity, convID int64, detail string) {
	identityUser, err := a.store.EnsureAutomationUser(identity.Name, identity.DisplayName)
	if err != nil {
		a.log.Warn("automation error message initialization failed", "identity", identity.Name, "err", err)
		return
	}
	payload, _ := json.Marshal(map[string]any{"text": detail, "format": "plain", "format_version": 1, "error": true})
	clientMsgID := fmt.Sprintf("automation-error-%d-%d", convID, time.Now().UnixNano())
	msg, err := a.store.InsertMessage(convID, identityUser.ID, "text", payload, clientMsgID)
	if err != nil {
		a.log.Warn("automation error message save failed", "identity", identity.Name, "err", err)
		return
	}
	msg.SenderName = identityUser.DisplayName
	msg.SenderAvatarMediaID = identityUser.AvatarMediaID
	members, _ := a.store.ConvMemberIDs(convID)
	a.hub.BroadcastToUsers(members, map[string]any{"type": "message.new", "message": msg})
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

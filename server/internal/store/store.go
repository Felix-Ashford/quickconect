// Package store 封装 SQLite 存储层：用户、设备、会话、消息、媒体。
//
// 消息可靠性基石：每个会话内 seq 严格单调递增（UNIQUE(conv_id, seq)），
// 发送幂等由 UNIQUE(sender_id, client_msg_id) 保证。
package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/oklog/ulid/v2"
	_ "modernc.org/sqlite"
)

var ErrNotFound = errors.New("不存在")

type Store struct {
	db *sql.DB
}

// Open 打开（必要时创建）SQLite 数据库并执行迁移。
func Open(path string) (*Store, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库: %w", err)
	}
	// WAL 模式下多读一写；pool>1 保证嵌套查询（如 ListConversations 内再查最后消息）不死锁，
	// 写冲突由 busy_timeout 等待解决。
	db.SetMaxOpenConns(4)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	schema := `
CREATE TABLE IF NOT EXISTS users (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  name         TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  avatar_media_id TEXT NOT NULL DEFAULT '',
  password_hash TEXT NOT NULL,
  created_at   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id     INTEGER NOT NULL REFERENCES users(id),
  name        TEXT NOT NULL,
  platform    TEXT NOT NULL DEFAULT '',
  token_hash  TEXT NOT NULL UNIQUE,
  push_topic  TEXT NOT NULL UNIQUE,
  last_seen_at INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS conversations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  type       TEXT NOT NULL CHECK(type IN ('dm','group')),
  dm_key     TEXT UNIQUE,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS conv_members (
  conv_id       INTEGER NOT NULL REFERENCES conversations(id),
  user_id       INTEGER NOT NULL REFERENCES users(id),
  last_read_seq INTEGER NOT NULL DEFAULT 0,
  joined_at     INTEGER NOT NULL,
  PRIMARY KEY (conv_id, user_id)
);
CREATE TABLE IF NOT EXISTS messages (
  id            TEXT PRIMARY KEY,
  conv_id       INTEGER NOT NULL REFERENCES conversations(id),
  seq           INTEGER NOT NULL,
  sender_id     INTEGER NOT NULL REFERENCES users(id),
  type          TEXT NOT NULL,
  payload       TEXT NOT NULL,
  client_msg_id TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  UNIQUE (conv_id, seq),
  UNIQUE (sender_id, client_msg_id)
);
CREATE TABLE IF NOT EXISTS media (
  id         TEXT PRIMARY KEY,
  owner_id   INTEGER NOT NULL REFERENCES users(id),
  kind       TEXT NOT NULL DEFAULT 'file',
  mime       TEXT NOT NULL DEFAULT 'application/octet-stream',
  size       INTEGER NOT NULL DEFAULT 0,
  path       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_messages_conv_seq ON messages(conv_id, seq);
CREATE TABLE IF NOT EXISTS automation_threads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  identity_name TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id),
  conversation_id INTEGER NOT NULL REFERENCES conversations(id),
  title TEXT NOT NULL DEFAULT '',
  selected_model TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_automation_threads_user ON automation_threads(identity_name, user_id, created_at);
`
	if _, err := s.db.Exec(schema); err != nil {
		return fmt.Errorf("建表: %w", err)
	}
	// Upgrade databases created before avatar support.
	_, _ = s.db.Exec(`ALTER TABLE users ADD COLUMN avatar_media_id TEXT NOT NULL DEFAULT ''`)
	return s.migrateAPIMode()
}

// ---------- 类型 ----------

type User struct {
	ID            int64  `json:"id"`
	Name          string `json:"name"`
	DisplayName   string `json:"display_name"`
	AvatarMediaID string `json:"avatar_media_id,omitempty"`
	PasswordHash  string `json:"-"` // 不随 JSON 序列化
}

type Device struct {
	ID        int64
	UserID    int64
	Name      string
	Platform  string
	PushTopic string
}

type Message struct {
	Revision            int64           `json:"revision"`
	ID                  string          `json:"id"`
	ConvID              int64           `json:"conv_id"`
	Seq                 int64           `json:"seq"`
	SenderID            int64           `json:"sender_id"`
	SenderName          string          `json:"sender_name"`
	SenderAvatarMediaID string          `json:"sender_avatar_media_id,omitempty"`
	Type                string          `json:"type"`
	Format              string          `json:"format,omitempty"`
	FormatVersion       int             `json:"format_version,omitempty"`
	Payload             json.RawMessage `json:"payload"`
	CreatedAt           int64           `json:"created_at"`
}

type ConvSummary struct {
	ID          int64    `json:"id"`
	Type        string   `json:"type"`
	Members     []User   `json:"members"`
	LastMessage *Message `json:"last_message"`
	Unread      int64    `json:"unread"`
	LastSeq     int64    `json:"last_seq"`
}

type AutomationThread struct {
	SystemPrompt   *string  `json:"system_prompt"`
	TitleManual    bool     `json:"title_manual"`
	ID             int64    `json:"id"`
	Identity       string   `json:"identity"`
	UserID         int64    `json:"user_id"`
	ConversationID int64    `json:"conversation_id"`
	Title          string   `json:"title"`
	SelectedModel  string   `json:"selected_model"`
	SelectedModels []string `json:"selected_models"`
	CreatedAt      int64    `json:"created_at"`
}

type Media struct {
	ID      string `json:"media_id"`
	OwnerID int64  `json:"-"`
	Kind    string `json:"kind"`
	Mime    string `json:"mime"`
	Size    int64  `json:"size"`
	Path    string `json:"-"`
}

// ---------- 用户 ----------

func (s *Store) CreateUser(name, displayName, passwordHash string) (User, error) {
	now := time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT INTO users(name, display_name, password_hash, created_at) VALUES(?,?,?,?)`,
		name, displayName, passwordHash, now)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			return User{}, fmt.Errorf("用户名 %s 已存在", name)
		}
		return User{}, err
	}
	id, _ := res.LastInsertId()
	return User{ID: id, Name: name, DisplayName: displayName}, nil
}

// EnsureAutomationUser creates the non-login service identity used by an
// automation profile. An empty password hash makes interactive login impossible.
func (s *Store) EnsureAutomationUser(name, displayName string) (User, error) {
	u, err := s.UserByName(name)
	if err != nil {
		return User{}, err
	}
	if u != nil {
		if displayName != "" && u.DisplayName != displayName {
			if _, err := s.db.Exec(`UPDATE users SET display_name=? WHERE id=?`, displayName, u.ID); err != nil {
				return User{}, err
			}
			u.DisplayName = displayName
		}
		return *u, nil
	}
	now := time.Now().Unix()
	res, err := s.db.Exec(`INSERT INTO users(name, display_name, password_hash, created_at) VALUES(?,?,?,?)`, name, displayName, "!automation-disabled!", now)
	if err != nil {
		return User{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return User{}, err
	}
	return User{ID: id, Name: name, DisplayName: displayName}, nil
}

func (s *Store) UserByName(name string) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(`SELECT id, name, display_name, password_hash, avatar_media_id FROM users WHERE name=?`, name).
		Scan(&u.ID, &u.Name, &u.DisplayName, &u.PasswordHash, &u.AvatarMediaID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return u, nil
}

func (s *Store) UserByID(id int64) (*User, error) {
	u := &User{}
	err := s.db.QueryRow(`SELECT id, name, display_name, avatar_media_id FROM users WHERE id=? AND password_hash <> '!deleted!'`, id).
		Scan(&u.ID, &u.Name, &u.DisplayName, &u.AvatarMediaID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}

func (s *Store) ListUsers() ([]User, error) {
	rows, err := s.db.Query(`SELECT id, name, display_name, avatar_media_id FROM users WHERE password_hash <> '!deleted!' ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Name, &u.DisplayName, &u.AvatarMediaID); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

func (s *Store) SetUserAvatar(userID int64, mediaID string) error {
	_, err := s.db.Exec(`UPDATE users SET avatar_media_id=? WHERE id=?`, mediaID, userID)
	return err
}

// DeleteUser revokes an account while preserving messages, attachments and
// foreign keys used by the remaining conversation members.
func (s *Store) DeleteUser(userID int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRow("SELECT 1 FROM users WHERE id=?", userID).Scan(&exists); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	for _, query := range []string{"DELETE FROM devices WHERE user_id=?", "UPDATE users SET password_hash='!deleted!' WHERE id=?"} {
		if _, err := tx.Exec(query, userID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ---------- 设备与令牌 ----------

func (s *Store) CreateDevice(userID int64, name, platform, tokenHash, pushTopic string) (Device, error) {
	now := time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT INTO devices(user_id, name, platform, token_hash, push_topic, last_seen_at, created_at) VALUES(?,?,?,?,?,?,?)`,
		userID, name, platform, tokenHash, pushTopic, now, now)
	if err != nil {
		return Device{}, err
	}
	id, _ := res.LastInsertId()
	return Device{ID: id, UserID: userID, Name: name, Platform: platform}, nil
}

func (s *Store) DeviceByTokenHash(tokenHash string) (*Device, error) {
	d := &Device{}
	err := s.db.QueryRow(`SELECT id, user_id, name, platform, push_topic FROM devices WHERE token_hash=?`, tokenHash).
		Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.PushTopic)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return d, nil
}

func (s *Store) DeleteDevice(deviceID int64) error {
	_, err := s.db.Exec(`DELETE FROM devices WHERE id=?`, deviceID)
	return err
}

func (s *Store) TouchDevice(deviceID int64) {
	s.db.Exec(`UPDATE devices SET last_seen_at=? WHERE id=?`, time.Now().Unix(), deviceID)
}

func (s *Store) PushTopicsForUser(userID int64) ([]string, error) {
	rows, err := s.db.Query(`SELECT push_topic FROM devices WHERE user_id=?`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// ---------- 会话 ----------

func dmKey(a, b int64) string {
	if a > b {
		a, b = b, a
	}
	return fmt.Sprintf("dm:%d:%d", a, b)
}

// GetOrCreateDM 返回两人私聊会话 ID（幂等）。
func (s *Store) GetOrCreateDM(a, b int64) (int64, error) {
	key := dmKey(a, b)
	var id int64
	err := s.db.QueryRow(`SELECT id FROM conversations WHERE dm_key=?`, key).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	now := time.Now().Unix()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`INSERT INTO conversations(type, dm_key, created_at) VALUES('dm',?,?)`, key, now)
	if err != nil {
		return 0, err
	}
	id, _ = res.LastInsertId()
	for _, uid := range []int64{a, b} {
		if _, err := tx.Exec(`INSERT INTO conv_members(conv_id, user_id, joined_at) VALUES(?,?,?)`, id, uid, now); err != nil {
			return 0, err
		}
	}
	return id, tx.Commit()
}

// CreatePrivateConversation creates an additional two-member conversation.
// It intentionally leaves dm_key NULL so a user can maintain multiple
// independent automation threads with the same identity.
func (s *Store) CreatePrivateConversation(a, b int64) (int64, error) {
	now := time.Now().Unix()
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	res, err := tx.Exec(`INSERT INTO conversations(type, dm_key, created_at) VALUES('dm',NULL,?)`, now)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	for _, uid := range []int64{a, b} {
		if _, err := tx.Exec(`INSERT INTO conv_members(conv_id,user_id,joined_at) VALUES(?,?,?)`, id, uid, now); err != nil {
			return 0, err
		}
	}
	return id, tx.Commit()
}

func (s *Store) AddConversationMember(convID, userID int64) error {
	_, err := s.db.Exec(`INSERT OR IGNORE INTO conv_members(conv_id, user_id, joined_at) VALUES(?,?,?)`, convID, userID, time.Now().Unix())
	return err
}

func (s *Store) CreateAutomationThread(identity string, userID, conversationID int64, title, model string) (AutomationThread, error) {
	now := time.Now().Unix()
	res, err := s.db.Exec(`INSERT INTO automation_threads(identity_name,user_id,conversation_id,title,selected_model,created_at) VALUES(?,?,?,?,?,?)`, identity, userID, conversationID, title, model, now)
	if err != nil {
		return AutomationThread{}, err
	}
	id, err := res.LastInsertId()
	return AutomationThread{ID: id, Identity: identity, UserID: userID, ConversationID: conversationID, Title: title, SelectedModel: model, CreatedAt: now}, err
}

func (s *Store) AutomationThreads(identity string, userID int64) ([]AutomationThread, error) {
	rows, err := s.db.Query(`SELECT id,identity_name,user_id,conversation_id,title,selected_model,created_at FROM automation_threads WHERE identity_name=? AND user_id=? ORDER BY created_at DESC,id DESC`, identity, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AutomationThread{}
	for rows.Next() {
		var item AutomationThread
		if err := rows.Scan(&item.ID, &item.Identity, &item.UserID, &item.ConversationID, &item.Title, &item.SelectedModel, &item.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Store) AutomationThreadForUser(identity string, userID, conversationID int64) (*AutomationThread, error) {
	var item AutomationThread
	err := s.db.QueryRow(`SELECT id,identity_name,user_id,conversation_id,title,selected_model,created_at FROM automation_threads WHERE identity_name=? AND user_id=? AND conversation_id=?`, identity, userID, conversationID).Scan(&item.ID, &item.Identity, &item.UserID, &item.ConversationID, &item.Title, &item.SelectedModel, &item.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if err = s.EnrichThread(&item); err != nil {
		return nil, err
	}
	return &item, nil
}

func (s *Store) UpdateAutomationThread(identity string, userID, conversationID int64, title, model string) error {
	_, err := s.db.Exec(`UPDATE automation_threads SET title=?, selected_model=? WHERE identity_name=? AND user_id=? AND conversation_id=?`, title, model, identity, userID, conversationID)
	return err
}

// DeleteAutomationThread permanently removes an owned private automation conversation.
// Media rows/files are retained because an upload can be referenced elsewhere.
func (s *Store) DeleteAutomationThread(identity string, userID, conversationID int64) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var threadID int64
	err = tx.QueryRow(`SELECT id FROM automation_threads WHERE identity_name=? AND user_id=? AND conversation_id=?`, identity, userID, conversationID).Scan(&threadID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM message_changes WHERE conv_id=?`, conversationID); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM messages WHERE conv_id=?`, conversationID); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM conv_members WHERE conv_id=?`, conversationID); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM automation_threads WHERE id=?`, threadID); err != nil {
		return err
	}
	if _, err = tx.Exec(`DELETE FROM conversations WHERE id=?`, conversationID); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) IsMember(convID, userID int64) (bool, error) {
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM conv_members WHERE conv_id=? AND user_id=?`, convID, userID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// CanChat excludes revoked members while retaining historical memberships.
func (s *Store) CanChat(convID, userID int64) (bool, error) {
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM conv_members WHERE conv_id=? AND user_id=?
		AND NOT EXISTS (SELECT 1 FROM conv_members m JOIN users u ON u.id=m.user_id
			WHERE m.conv_id=? AND u.password_hash='!deleted!')`, convID, userID, convID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Store) ConvMemberIDs(convID int64) ([]int64, error) {
	rows, err := s.db.Query(`SELECT user_id FROM conv_members WHERE conv_id=?`, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func (s *Store) ConvMembers(convID int64) ([]User, error) {
	rows, err := s.db.Query(`
		SELECT u.id, u.name, u.display_name, u.avatar_media_id
		FROM conv_members m JOIN users u ON u.id = m.user_id
		WHERE m.conv_id=? ORDER BY u.id`, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Name, &u.DisplayName, &u.AvatarMediaID); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// ListConversations 汇总用户的所有会话：成员、最后一条消息、未读数、会话最大 seq。
func (s *Store) ListConversations(userID int64) ([]ConvSummary, error) {
	rows, err := s.db.Query(`
		SELECT c.id, c.type, COALESCE(m.last_read_seq,0)
		FROM conversations c
		JOIN conv_members m ON m.conv_id = c.id AND m.user_id = ?
		WHERE NOT EXISTS (SELECT 1 FROM conv_members revoked
			JOIN users u ON u.id=revoked.user_id
			WHERE revoked.conv_id=c.id AND u.password_hash='!deleted!')
		ORDER BY c.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ConvSummary
	var ids []int64
	var readSeqs []int64
	for rows.Next() {
		var c ConvSummary
		var read int64
		if err := rows.Scan(&c.ID, &c.Type, &read); err != nil {
			return nil, err
		}
		out = append(out, c)
		ids = append(ids, c.ID)
		readSeqs = append(readSeqs, read)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, c := range ids {
		sum := &out[i]
		members, err := s.ConvMembers(c)
		if err != nil {
			return nil, err
		}
		sum.Members = members
		last, err := s.lastMessage(c)
		if err != nil {
			return nil, err
		}
		sum.LastMessage = last
		maxSeq, unread := int64(0), int64(0)
		if last != nil {
			maxSeq = last.Seq
		}
		if maxSeq > readSeqs[i] {
			// 未读 = 比我已读游标新的、且不是我自己发的消息
			err := s.db.QueryRow(`SELECT COUNT(*) FROM messages WHERE conv_id=? AND seq>? AND sender_id<>?`, c, readSeqs[i], userID).Scan(&unread)
			if err != nil {
				return nil, err
			}
		}
		sum.LastSeq = maxSeq
		sum.Unread = unread
	}
	return out, nil
}

func (s *Store) lastMessage(convID int64) (*Message, error) {
	m, err := s.messageRow(`
		SELECT m.id, m.conv_id, m.seq, m.sender_id, u.display_name, u.avatar_media_id, m.type, m.payload, m.created_at, m.revision
		FROM messages m JOIN users u ON u.id = m.sender_id
		WHERE m.conv_id=? ORDER BY m.seq DESC LIMIT 1`, convID)
	if err != nil {
		return nil, err
	}
	return m, nil // 无消息时返回 nil
}

// ---------- 消息 ----------

// InsertMessage 写入一条消息；若 (sender, client_msg_id) 已存在则直接返回既有记录（幂等）。
func (s *Store) InsertMessage(convID, senderID int64, typ string, payload []byte, clientMsgID string) (Message, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return Message{}, err
	}
	defer tx.Rollback()

	var existSeq int64
	err = tx.QueryRow(`
		SELECT m.seq
		FROM messages m JOIN users u ON u.id = m.sender_id
		WHERE m.sender_id=? AND m.client_msg_id=?`, senderID, clientMsgID).Scan(&existSeq)
	if err == nil {
		m := &Message{}
		var payload string
		err = tx.QueryRow(`
			SELECT m.id, m.conv_id, m.seq, m.sender_id, u.display_name, u.avatar_media_id, m.type, m.payload, m.created_at, m.revision
			FROM messages m JOIN users u ON u.id = m.sender_id
			WHERE m.sender_id=? AND m.client_msg_id=?`, senderID, clientMsgID).
			Scan(&m.ID, &m.ConvID, &m.Seq, &m.SenderID, &m.SenderName, &m.SenderAvatarMediaID, &m.Type, &payload, &m.CreatedAt, &m.Revision)
		if err != nil {
			return Message{}, err
		}
		m.Payload = json.RawMessage(payload)
		m.Format, m.FormatVersion = payloadFormat(m.Payload)
		return *m, tx.Commit()
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return Message{}, err
	}

	var maxSeq int64
	if err := tx.QueryRow(`SELECT COALESCE(MAX(seq),0) FROM messages WHERE conv_id=?`, convID).Scan(&maxSeq); err != nil {
		return Message{}, err
	}
	id := ulid.Make().String()
	now := time.Now().Unix()
	if _, err := tx.Exec(
		`INSERT INTO messages(id, conv_id, seq, sender_id, type, payload, client_msg_id, created_at) VALUES(?,?,?,?,?,?,?,?)`,
		id, convID, maxSeq+1, senderID, typ, string(payload), clientMsgID, now); err != nil {
		return Message{}, err
	}
	if err := tx.Commit(); err != nil {
		return Message{}, err
	}
	return Message{
		ID: id, ConvID: convID, Seq: maxSeq + 1, SenderID: senderID,
		Type: typ, Format: func() string { f, _ := payloadFormat(json.RawMessage(payload)); return f }(), FormatVersion: func() int { _, v := payloadFormat(json.RawMessage(payload)); return v }(), Payload: json.RawMessage(payload), CreatedAt: now,
	}, nil
}

func (s *Store) messageRow(query string, args ...any) (*Message, error) {
	m := &Message{}
	var payload string
	err := s.db.QueryRow(query, args...).
		Scan(&m.ID, &m.ConvID, &m.Seq, &m.SenderID, &m.SenderName, &m.SenderAvatarMediaID, &m.Type, &payload, &m.CreatedAt, &m.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	m.Payload = json.RawMessage(payload)
	m.Format, m.FormatVersion = payloadFormat(m.Payload)
	return m, nil
}

func payloadFormat(payload json.RawMessage) (string, int) {
	var v struct {
		Format        string `json:"format"`
		FormatVersion int    `json:"format_version"`
	}
	if json.Unmarshal(payload, &v) != nil {
		return "plain", 1
	}
	if v.Format == "" {
		v.Format = "plain"
	}
	if v.FormatVersion == 0 {
		v.FormatVersion = 1
	}
	return v.Format, v.FormatVersion
}

// MessagesAfter 增量拉取：seq > afterSeq，按 seq 升序；返回 has_more 表示是否还有剩余。
func (s *Store) MessagesAfter(convID, afterSeq int64, limit int) ([]Message, bool, error) {
	rows, err := s.db.Query(`
		SELECT m.id, m.conv_id, m.seq, m.sender_id, u.display_name, u.avatar_media_id, m.type, m.payload, m.created_at, m.revision
		FROM messages m JOIN users u ON u.id = m.sender_id
		WHERE m.conv_id=? AND m.seq>? ORDER BY m.seq ASC LIMIT ?`, convID, afterSeq, limit+1)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var payload string
		m := Message{}
		if err := rows.Scan(&m.ID, &m.ConvID, &m.Seq, &m.SenderID, &m.SenderName, &m.SenderAvatarMediaID, &m.Type, &payload, &m.CreatedAt, &m.Revision); err != nil {
			return nil, false, err
		}
		m.Payload = json.RawMessage(payload)
		m.Format, m.FormatVersion = payloadFormat(m.Payload)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}
	hasMore := len(out) > limit
	if hasMore {
		out = out[:limit]
	}
	return out, hasMore, nil
}

func (s *Store) MessageBySeq(convID, seq int64) (*Message, error) {
	return s.messageRow(`SELECT `+messageColumns+` FROM messages m JOIN users u ON u.id=m.sender_id WHERE m.conv_id=? AND m.seq=?`, convID, seq)
}

// MessagesRecent returns the newest messages in chronological order. It is
// used for model context so long conversations do not keep sending their
// oldest messages forever.
func (s *Store) MessagesRecent(convID int64, limit int) ([]Message, error) {
	if limit <= 0 {
		limit = 30
	}
	rows, err := s.db.Query(`
		SELECT m.id, m.conv_id, m.seq, m.sender_id, u.display_name, u.avatar_media_id, m.type, m.payload, m.created_at, m.revision
		FROM messages m JOIN users u ON u.id = m.sender_id
		WHERE m.conv_id=? ORDER BY m.seq DESC LIMIT ?`, convID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var payload string
		m := Message{}
		if err := rows.Scan(&m.ID, &m.ConvID, &m.Seq, &m.SenderID, &m.SenderName, &m.SenderAvatarMediaID, &m.Type, &payload, &m.CreatedAt, &m.Revision); err != nil {
			return nil, err
		}
		m.Payload = json.RawMessage(payload)
		m.Format, m.FormatVersion = payloadFormat(m.Payload)
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}

// MarkRead 推进已读游标（只前进不后退）。
func (s *Store) MarkRead(convID, userID, seq int64) error {
	_, err := s.db.Exec(`UPDATE conv_members SET last_read_seq = MAX(last_read_seq, ?) WHERE conv_id=? AND user_id=?`, seq, convID, userID)
	return err
}

// ---------- 媒体 ----------

func (s *Store) InsertMedia(id string, ownerID int64, kind, mime string, size int64, path string) error {
	_, err := s.db.Exec(
		`INSERT INTO media(id, owner_id, kind, mime, size, path, created_at) VALUES(?,?,?,?,?,?,?)`,
		id, ownerID, kind, mime, size, path, time.Now().Unix())
	return err
}

func (s *Store) MediaByID(id string) (*Media, error) {
	m := &Media{}
	err := s.db.QueryRow(`SELECT id, owner_id, kind, mime, size, path FROM media WHERE id=?`, id).
		Scan(&m.ID, &m.OwnerID, &m.Kind, &m.Mime, &m.Size, &m.Path)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// MediaUsage 返回某用户已用存储字节数（配额用）。
func (s *Store) MediaUsage(ownerID int64) (int64, error) {
	var sum sql.NullInt64
	err := s.db.QueryRow(`SELECT SUM(size) FROM media WHERE owner_id=?`, ownerID).Scan(&sum)
	return sum.Int64, err
}

// NewMediaID 生成媒体 ID（ULID，时间有序，便于按内容分桶落盘）。
func NewMediaID() string { return ulid.Make().String() }

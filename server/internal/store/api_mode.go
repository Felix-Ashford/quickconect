package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

var ErrForbidden = errors.New("message belongs to another user")
var ErrInvalidMessage = errors.New("message cannot be changed")

func (s *Store) migrateAPIMode() error {
	for _, column := range []struct{ table, name, definition string }{
		{"messages", "revision", "INTEGER NOT NULL DEFAULT 0"},
		{"automation_threads", "system_prompt", "TEXT"},
		{"automation_threads", "title_manual", "INTEGER NOT NULL DEFAULT 0"},
		{"automation_threads", "selected_models", "TEXT NOT NULL DEFAULT '[]'"},
	} {
		rows, err := s.db.Query("PRAGMA table_info(" + column.table + ")")
		if err != nil {
			return err
		}
		found := false
		for rows.Next() {
			var cid, nn, pk int
			var name, typ string
			var def any
			if err = rows.Scan(&cid, &name, &typ, &nn, &def, &pk); err != nil {
				rows.Close()
				return err
			}
			if name == column.name {
				found = true
			}
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
		if !found {
			if _, err = s.db.Exec("ALTER TABLE " + column.table + " ADD COLUMN " + column.name + " " + column.definition); err != nil {
				return err
			}
		}
	}
	_, err := s.db.Exec(`CREATE TABLE IF NOT EXISTS message_changes (revision INTEGER PRIMARY KEY AUTOINCREMENT, conv_id INTEGER NOT NULL, message_id TEXT NOT NULL REFERENCES messages(id)); CREATE INDEX IF NOT EXISTS idx_changes_conv_revision ON message_changes(conv_id,revision);`)
	return err
}

const messageColumns = `m.id,m.conv_id,m.seq,m.sender_id,u.display_name,u.avatar_media_id,m.type,m.payload,m.created_at,m.revision`

func (s *Store) MessageByID(convID int64, id string) (*Message, error) {
	return s.messageRow(`SELECT `+messageColumns+` FROM messages m JOIN users u ON u.id=m.sender_id WHERE m.conv_id=? AND m.id=?`, convID, id)
}

// ReviseMessage performs ownership validation and the change log atomically.
func (s *Store) ReviseMessage(convID, userID int64, id string, text *string) (*Message, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var sender int64
	var typ, payload string
	err = tx.QueryRow(`SELECT sender_id,type,payload FROM messages WHERE id=? AND conv_id=?`, id, convID).Scan(&sender, &typ, &payload)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if sender != userID {
		return nil, ErrForbidden
	}
	data := map[string]any{}
	if err = json.Unmarshal([]byte(payload), &data); err != nil {
		return nil, err
	}
	if data["retracted"] == true || data["deleted"] == true {
		return nil, ErrInvalidMessage
	}
	if text != nil {
		if typ != "text" {
			return nil, ErrInvalidMessage
		}
		data["text"] = *text
		data["edited_at"] = time.Now().Unix()
	} else {
		data = map[string]any{"retracted": true, "retracted_at": time.Now().Unix()}
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return nil, err
	}
	res, err := tx.Exec(`INSERT INTO message_changes(conv_id,message_id) VALUES(?,?)`, convID, id)
	if err != nil {
		return nil, err
	}
	rev, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	if _, err = tx.Exec(`UPDATE messages SET payload=?,revision=? WHERE id=? AND conv_id=?`, string(raw), rev, id, convID); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return s.MessageByID(convID, id)
}

func (s *Store) MessageChanges(convID, after int64, limit int) ([]Message, int64, bool, error) {
	rows, err := s.db.Query(`SELECT revision,message_id FROM message_changes WHERE conv_id=? AND revision>? ORDER BY revision LIMIT ?`, convID, after, limit+1)
	if err != nil {
		return nil, after, false, err
	}
	type change struct {
		revision int64
		id       string
	}
	entries := []change{}
	for rows.Next() {
		var c change
		if err = rows.Scan(&c.revision, &c.id); err != nil {
			rows.Close()
			return nil, after, false, err
		}
		entries = append(entries, c)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, after, false, err
	}
	more := len(entries) > limit
	if more {
		entries = entries[:limit]
	}
	out := []Message{}
	seen := map[string]bool{}
	cursor := after
	for _, c := range entries {
		cursor = c.revision
		if seen[c.id] {
			continue
		}
		seen[c.id] = true
		m, err := s.MessageByID(convID, c.id)
		if err != nil {
			return nil, after, false, err
		}
		if m != nil {
			out = append(out, *m)
		}
	}
	return out, cursor, more, nil
}

func (s *Store) EnrichThread(thread *AutomationThread) error {
	if thread == nil {
		return nil
	}
	var raw string
	if err := s.db.QueryRow(`SELECT system_prompt,title_manual,selected_models FROM automation_threads WHERE id=?`, thread.ID).Scan(&thread.SystemPrompt, &thread.TitleManual, &raw); err != nil {
		return err
	}
	if err := json.Unmarshal([]byte(raw), &thread.SelectedModels); err != nil {
		return err
	}
	if len(thread.SelectedModels) == 0 && thread.SelectedModel != "" {
		thread.SelectedModels = []string{thread.SelectedModel}
	}
	return nil
}

func (s *Store) SaveThreadSettings(thread AutomationThread) error {
	models := thread.SelectedModels
	if models == nil {
		models = []string{}
	}
	raw, err := json.Marshal(models)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(`UPDATE automation_threads SET title=?,selected_model=?,selected_models=?,system_prompt=?,title_manual=? WHERE id=? AND identity_name=? AND user_id=?`, thread.Title, thread.SelectedModel, string(raw), thread.SystemPrompt, thread.TitleManual, thread.ID, thread.Identity, thread.UserID)
	return err
}

// 删除保留原问题关联和同步墓碑，但不再保留回复正文。
func (s *Store) DeletePrivateThreadMessage(convID, userID int64, messageID string) (*Message, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var owner int64
	if err = tx.QueryRow(`SELECT user_id FROM automation_threads WHERE conversation_id=? AND user_id=?`, convID, userID).Scan(&owner); err != nil {
		return nil, ErrForbidden
	}
	var raw string
	if err = tx.QueryRow(`SELECT m.payload FROM messages m JOIN users u ON u.id=m.sender_id JOIN automation_threads t ON t.conversation_id=m.conv_id AND t.identity_name=u.name WHERE m.id=? AND m.conv_id=? AND t.user_id=?`, messageID, convID, userID).Scan(&raw); err != nil {
		return nil, err
	}
	var data map[string]any
	if err = json.Unmarshal([]byte(raw), &data); err != nil {
		return nil, err
	}
	tombstone := map[string]any{"deleted": true, "deleted_at": time.Now().Unix()}
	for _, key := range []string{"reply_to", "question_revision", "context_standalone", "error"} {
		if value, ok := data[key]; ok {
			tombstone[key] = value
		}
	}
	updated, err := json.Marshal(tombstone)
	if err != nil {
		return nil, err
	}
	res, err := tx.Exec(`INSERT INTO message_changes(conv_id,message_id) VALUES(?,?)`, convID, messageID)
	if err != nil {
		return nil, err
	}
	rev, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	if _, err = tx.Exec(`UPDATE messages SET payload=?,revision=? WHERE id=? AND conv_id=?`, string(updated), rev, messageID, convID); err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return s.MessageByID(convID, messageID)
}

func (s *Store) SetAutomaticTitle(id int64, title string) error {
	_, err := s.db.Exec(`UPDATE automation_threads SET title=? WHERE id=? AND title_manual=0 AND title=''`, title, id)
	return err
}

// ContextHistory reads backward until enough content exists for a character
// budget. The caller adds metadata and performs precise Unicode truncation.
func (s *Store) ContextHistory(convID int64, maxChars int) ([]Message, error) {
	return s.ContextHistoryThrough(convID, maxChars, 0)
}

// A positive throughSeq prevents later questions and existing answers from
// becoming context when an earlier question is manually regenerated.
func (s *Store) ContextHistoryThrough(convID int64, maxChars int, throughSeq int64) ([]Message, error) {
	rows, err := s.db.Query(`SELECT `+messageColumns+` FROM messages m JOIN users u ON u.id=m.sender_id WHERE m.conv_id=? AND (?=0 OR m.seq<=?) ORDER BY m.seq DESC`, convID, throughSeq, throughSeq)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Message{}
	used := 0
	for rows.Next() {
		var m Message
		var raw string
		if err = rows.Scan(&m.ID, &m.ConvID, &m.Seq, &m.SenderID, &m.SenderName, &m.SenderAvatarMediaID, &m.Type, &raw, &m.CreatedAt, &m.Revision); err != nil {
			return nil, err
		}
		var p map[string]any
		if json.Unmarshal([]byte(raw), &p) != nil || p["retracted"] == true || p["deleted"] == true || p["error"] == true {
			continue
		}
		m.Payload = json.RawMessage(raw)
		m.Format, m.FormatVersion = payloadFormat(m.Payload)
		out = append(out, m)
		content, _ := p["text"].(string)
		if content == "" {
			content = fmt.Sprintf("[%s] %v", m.Type, p["name"])
		}
		used += len([]rune(content))
		if used >= maxChars {
			break
		}
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}

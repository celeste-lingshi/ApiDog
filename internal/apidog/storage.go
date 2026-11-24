package apidog

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type EnvironmentVariable struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Value       string `json:"value"`
	SessionOnly bool   `json:"sessionOnly"`
}
type Environment struct {
	ID        string                `json:"id"`
	Name      string                `json:"name"`
	Variables []EnvironmentVariable `json:"variables"`
}
type HistoryEntry struct {
	ID           string  `json:"id"`
	Date         float64 `json:"date"`
	Request      Draft   `json:"request"`
	Environment  string  `json:"environment,omitempty"`
	Status       *int    `json:"status,omitempty"`
	Milliseconds int64   `json:"milliseconds"`
}
type Category struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type SavedRequest struct {
	ID         string  `json:"id"`
	Name       string  `json:"name"`
	CategoryID *string `json:"categoryID,omitempty"`
	Draft      Draft   `json:"draft"`
}
type Directory struct {
	Categories []Category     `json:"categories"`
	Requests   []SavedRequest `json:"requests"`
}
type Workspace struct {
	Environments          []Environment  `json:"environments"`
	SelectedEnvironmentID string         `json:"selectedEnvironmentID,omitempty"`
	History               []HistoryEntry `json:"history"`
	Directory             *Directory     `json:"directory,omitempty"`
	EncryptedCredentials  []byte         `json:"encryptedCredentials,omitempty"`
}

func NewHistory(draft Draft, status *int, started time.Time) HistoryEntry {
	return HistoryEntry{ID: NewID(), Date: float64(started.UnixNano())/1e9 - 978307200, Request: draft, Status: status, Milliseconds: time.Since(started).Milliseconds()}
}

func (w *Workspace) Requests() *Directory {
	if w.Directory == nil {
		w.Directory = &Directory{}
	}
	return w.Directory
}

func (w Workspace) HistoryDraft(id string) (Draft, error) {
	for _, entry := range w.History {
		if entry.ID != id {
			continue
		}
		d := entry.Request
		d.Variables = map[string]string{}
		for k, v := range entry.Request.Variables {
			d.Variables[k] = v
		}
		for _, environment := range w.Environments {
			if environment.Name != entry.Environment {
				continue
			}
			for _, name := range d.VariableNames() {
				if _, ok := d.Variables[name]; ok {
					continue
				}
				for _, v := range environment.Variables {
					if v.Name == name && (!v.SessionOnly || v.Value != "") {
						d.Variables[name] = v.Value
					}
				}
			}
			break
		}
		return d, nil
	}
	return Draft{}, errors.New("请求历史已不存在。")
}

type Storage struct{ Folder string }

func LocalStorage() (Storage, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Storage{}, err
	}
	return Storage{filepath.Join(home, "Library", "Application Support", "ApiDog")}, nil
}
func (s Storage) path() string    { return filepath.Join(s.Folder, "workspace.json") }
func (s Storage) keyFile() string { return filepath.Join(s.Folder, "workspace.key") }

func (s Storage) Load() (Workspace, error) {
	w, err := s.read()
	if err != nil || len(w.EncryptedCredentials) == 0 {
		return w, err
	}
	key, err := s.key(false)
	if errors.Is(err, os.ErrNotExist) {
		return w, nil
	}
	if err != nil {
		return w, err
	}
	return w.unseal(key)
}

func (s Storage) Migrate(key []byte) (Workspace, error) {
	w, err := s.read()
	if err != nil {
		return w, err
	}
	if len(w.EncryptedCredentials) == 0 {
		return w, errors.New("没有可迁移的旧认证。")
	}
	unlocked, err := w.unseal(key)
	if err != nil {
		return w, err
	}
	if err = s.writeKey(key); err != nil {
		return w, err
	}
	return unlocked, nil
}

func (s Storage) read() (Workspace, error) {
	var w Workspace
	data, err := os.ReadFile(s.path())
	if errors.Is(err, os.ErrNotExist) {
		return w, nil
	}
	if err != nil {
		return w, err
	}
	err = json.Unmarshal(data, &w)
	return w, err
}

type credentials struct {
	Authentication Auth              `json:"authentication"`
	Variables      map[string]string `json:"variables"`
}

func (w Workspace) unseal(key []byte) (Workspace, error) {
	aead, err := makeAEAD(key)
	if err != nil {
		return w, err
	}
	size := aead.NonceSize()
	ciphertext := w.EncryptedCredentials
	if len(ciphertext) < size {
		return w, errors.New("加密认证数据格式不正确。")
	}
	raw, err := aead.Open(nil, ciphertext[:size], ciphertext[size:], nil)
	if err != nil {
		return w, errors.New("无法解密已保存的认证信息。")
	}
	// Swift 用交替排列的 ID 和认证对象编码以 UUID 为键的字典。
	var entries []json.RawMessage
	if err = json.Unmarshal(raw, &entries); err != nil || len(entries)%2 != 0 {
		return w, errors.New("加密认证数据格式不正确。")
	}
	saved := map[string]credentials{}
	for i := 0; i < len(entries); i += 2 {
		var id string
		var value credentials
		if err = json.Unmarshal(entries[i], &id); err != nil {
			return w, err
		}
		if err = json.Unmarshal(entries[i+1], &value); err != nil {
			return w, err
		}
		saved[strings.ToUpper(id)] = value
	}
	if w.Directory != nil {
		for i, r := range w.Directory.Requests {
			if v, ok := saved[strings.ToUpper(r.ID)]; ok {
				r.Draft.Auth = v.Authentication
				if r.Draft.Variables == nil {
					r.Draft.Variables = map[string]string{}
				}
				for k, v := range v.Variables {
					r.Draft.Variables[k] = v
				}
				w.Directory.Requests[i] = r
			}
		}
	}
	w.EncryptedCredentials = nil
	return w, nil
}

func makeAEAD(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errors.New("工作区的本地密钥文件格式不正确。")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func (s Storage) Save(w Workspace) error {
	if len(w.EncryptedCredentials) > 0 {
		return errors.New("旧版认证尚未迁移，无法写入工作区。")
	}
	w.Environments = append([]Environment{}, w.Environments...)
	for i, e := range w.Environments {
		e.Variables = append([]EnvironmentVariable{}, e.Variables...)
		for j := range e.Variables {
			if e.Variables[j].SessionOnly {
				e.Variables[j].Value = ""
			}
		}
		w.Environments[i] = e
	}
	w.History = append([]HistoryEntry{}, w.History...)
	for i, h := range w.History {
		w.History[i].Request = h.Request.redacted()
	}
	var saved []any
	if w.Directory != nil {
		dir := Directory{Categories: append([]Category{}, w.Directory.Categories...), Requests: append([]SavedRequest{}, w.Directory.Requests...)}
		for i, request := range dir.Requests {
			r := request.Draft.redacted()
			variables := map[string]string{}
			for k, v := range request.Draft.Variables {
				if _, ok := r.Variables[k]; !ok {
					variables[k] = v
				}
			}
			kept := request.Draft.Auth
			if kept.Secret != nil || r.Auth.Name != kept.Name || len(variables) > 0 || hasInputValues(kept.ScriptInputs) {
				saved = append(saved, strings.ToUpper(request.ID), credentials{kept, variables})
			}
			dir.Requests[i].Draft = r
		}
		w.Directory = &dir
	}
	if len(saved) > 0 {
		key, err := s.key(true)
		if err != nil {
			return err
		}
		aead, err := makeAEAD(key)
		if err != nil {
			return err
		}
		payload, err := marshalJSON(saved)
		if err != nil {
			return err
		}
		nonce := make([]byte, aead.NonceSize())
		if _, err = rand.Read(nonce); err != nil {
			return err
		}
		w.EncryptedCredentials = aead.Seal(nonce, nonce, payload, nil)
	}
	data, err := json.MarshalIndent(w, "", "  ")
	if err != nil {
		return err
	}
	return s.atomicWrite(s.path(), data, false)
}

func hasInputValues(fields []Field) bool {
	for _, f := range fields {
		if f.Value != nil {
			return true
		}
	}
	return false
}

func (s Storage) key(create bool) ([]byte, error) {
	data, err := os.ReadFile(s.keyFile())
	if !errors.Is(err, os.ErrNotExist) || !create {
		return data, err
	}
	data = make([]byte, 32)
	if _, err = rand.Read(data); err != nil {
		return nil, err
	}
	return data, s.writeKey(data)
}
func (s Storage) writeKey(data []byte) error {
	if len(data) != 32 {
		return errors.New("工作区的本地密钥文件格式不正确。")
	}
	return s.atomicWrite(s.keyFile(), data, true)
}

func (s Storage) atomicWrite(path string, data []byte, create bool) error {
	if err := os.MkdirAll(s.Folder, 0700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(s.Folder, ".apidog-")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	_, writeErr := temp.Write(data)
	closeErr := temp.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	if create {
		if err = os.Link(temp.Name(), path); err != nil {
			return fmt.Errorf("无法保存工作区的本地密钥文件：%w", err)
		}
		return nil
	}
	return os.Rename(temp.Name(), path)
}

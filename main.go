package main

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/celeste-lingshi/ApiDog/internal/apidog"
	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

//go:embed frontend
var files embed.FS

func main() {
	if len(os.Args) == 2 && os.Args[1] == apidog.AuthWorkerArgument {
		apidog.RunAuthWorker(os.Stdin, os.Stdout)
		return
	}
	app := &App{}
	app.storage, app.loadErr = apidog.LocalStorage()
	if app.loadErr == nil {
		app.workspace, app.loadErr = app.storage.Load()
	}
	assets, err := fs.Sub(files, "frontend")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return
	}
	err = wails.Run(&options.App{
		Title: "ApiDog", Width: 1200, Height: 740, MinWidth: 820, MinHeight: 610, Frameless: true,
		BackgroundColour: &options.RGBA{R: 17, G: 21, B: 29, A: 255},
		AssetServer:      &assetserver.Options{Assets: assets},
		OnStartup:        func(ctx context.Context) { app.ctx = ctx },
		Bind:             []any{app},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
}

type App struct {
	ctx       context.Context
	mu        sync.Mutex
	storage   apidog.Storage
	workspace apidog.Workspace
	loadErr   error
	cancel    context.CancelFunc
	migrating bool
}

type State struct {
	Directory apidog.Directory      `json:"directory"`
	History   []apidog.HistoryEntry `json:"history"`
	Locked    bool                  `json:"locked"`
	Issue     string                `json:"issue"`
}

func (a *App) state() State {
	dir := a.workspace.Requests()
	state := State{Directory: apidog.Directory{Categories: slices.Clone(dir.Categories), Requests: slices.Clone(dir.Requests)}, History: slices.Clone(a.workspace.History), Locked: len(a.workspace.EncryptedCredentials) > 0}
	if a.loadErr != nil {
		state.Issue = "工作区读取失败，本次改动只保留在窗口内。\n" + a.loadErr.Error()
	}
	if state.Locked && state.Issue == "" {
		state.Issue = "旧版认证尚未迁移。现在可以浏览，迁移后可以编辑和发送请求。"
	}
	return state
}

func (a *App) State() State {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.state()
}

func (a *App) writable() error {
	if len(a.workspace.EncryptedCredentials) > 0 {
		return errors.New("旧版认证尚未迁移，无法写入工作区。")
	}
	return nil
}

func (a *App) save() State {
	state := a.state()
	if a.loadErr == nil {
		if err := a.storage.Save(a.workspace); err != nil {
			state.Issue = "工作区写入失败。" + err.Error()
		}
	}
	return state
}

func (a *App) NewCategory(name string) (State, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.writable(); err != nil {
		return a.state(), err
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return a.state(), errors.New("请输入分类名称。")
	}
	dir := a.workspace.Requests()
	for _, category := range dir.Categories {
		if strings.EqualFold(category.Name, name) {
			return a.state(), errors.New("已有同名分类。")
		}
	}
	dir.Categories = append(dir.Categories, apidog.Category{ID: apidog.NewID(), Name: name})
	return a.save(), nil
}

func (a *App) SaveRequest(request apidog.SavedRequest) (State, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.writable(); err != nil {
		return a.state(), err
	}
	request.Name = strings.TrimSpace(request.Name)
	if request.ID == "" || request.Name == "" {
		return a.state(), errors.New("请输入请求名称。")
	}
	dir := a.workspace.Requests()
	if !validCategory(dir, request.CategoryID) {
		return a.state(), errors.New("目标分类已不存在。")
	}
	for i, saved := range dir.Requests {
		if saved.ID == request.ID {
			dir.Requests[i] = request
			return a.save(), nil
		}
	}
	dir.Requests = append(dir.Requests, request)
	return a.save(), nil
}

func validCategory(dir *apidog.Directory, id *string) bool {
	if id == nil {
		return true
	}
	for _, c := range dir.Categories {
		if c.ID == *id {
			return true
		}
	}
	return false
}

func (a *App) MoveRequest(id string, categoryID *string) (State, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.writable(); err != nil {
		return a.state(), err
	}
	dir := a.workspace.Requests()
	if !validCategory(dir, categoryID) {
		return a.state(), errors.New("目标分类已不存在。")
	}
	for i, request := range dir.Requests {
		if request.ID == id {
			dir.Requests[i].CategoryID = categoryID
			return a.save(), nil
		}
	}
	return a.state(), errors.New("请求已不存在。")
}

func (a *App) DeleteRequest(id string) (State, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.writable(); err != nil {
		return a.state(), err
	}
	dir := a.workspace.Requests()
	for i, r := range dir.Requests {
		if r.ID == id {
			dir.Requests = append(dir.Requests[:i], dir.Requests[i+1:]...)
			return a.save(), nil
		}
	}
	return a.state(), errors.New("请求已不存在。")
}

func (a *App) ClearHistory() (State, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if err := a.writable(); err != nil {
		return a.state(), err
	}
	a.workspace.History = nil
	return a.save(), nil
}

func (a *App) OpenHistory(id string) (apidog.Draft, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.workspace.HistoryDraft(id)
}

func (a *App) Migrate() (State, error) {
	a.mu.Lock()
	if len(a.workspace.EncryptedCredentials) == 0 || a.migrating {
		defer a.mu.Unlock()
		return a.state(), nil
	}
	a.migrating = true
	a.mu.Unlock()
	// 等待钥匙串授权期间，窗口仍然可以浏览。
	key, err := apidog.ReadLegacyKey()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.migrating = false
	if err != nil {
		return a.state(), err
	}
	w, err := a.storage.Migrate(key)
	if err != nil {
		return a.state(), err
	}
	a.workspace = w
	a.loadErr = nil
	return a.state(), nil
}

func (a *App) ImportCurl(source string) (apidog.Draft, error) { return apidog.ImportCurl(source) }
func (a *App) Preview(draft apidog.Draft) (string, error)     { return apidog.Preview(a.ctx, draft) }

type SendResult struct {
	Response     *apidog.Response `json:"response"`
	State        State            `json:"state"`
	HistoryID    string           `json:"historyID,omitempty"`
	Milliseconds int64            `json:"milliseconds"`
	Curl         string           `json:"curl,omitempty"`
	Error        string           `json:"error,omitempty"`
	Cancelled    bool             `json:"cancelled,omitempty"`
}

func (a *App) Send(draft apidog.Draft) (SendResult, error) {
	a.mu.Lock()
	if err := a.writable(); err != nil {
		a.mu.Unlock()
		return SendResult{}, err
	}
	if a.cancel != nil {
		a.mu.Unlock()
		return SendResult{}, errors.New("正在发送请求。")
	}
	ctx, cancel := context.WithTimeout(a.ctx, 30*time.Second)
	a.cancel = cancel
	a.mu.Unlock()
	defer func() {
		cancel()
		a.mu.Lock()
		a.cancel = nil
		a.mu.Unlock()
	}()
	started := time.Now()
	result := SendResult{}
	var status *int
	p, err := apidog.Prepare(ctx, draft, started)
	if err == nil {
		result.Curl = p.Command()
		var response apidog.Response
		response, err = p.Send(ctx)
		if err == nil {
			result.Response = &response
			status = &response.Status
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if errors.Is(ctx.Err(), context.Canceled) {
		result.Response = nil
		result.Cancelled = true
		result.State = a.state()
		return result, nil
	}
	if err != nil {
		result.Error = err.Error()
	}
	entry := apidog.NewHistory(draft, status, started)
	a.workspace.History = append([]apidog.HistoryEntry{entry}, a.workspace.History...)
	if len(a.workspace.History) > 100 {
		a.workspace.History = a.workspace.History[:100]
	}
	result.HistoryID = entry.ID
	result.Milliseconds = entry.Milliseconds
	result.State = a.save()
	return result, nil
}

func (a *App) Cancel() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.cancel != nil {
		a.cancel()
	}
}

func (a *App) Theme() string {
	out, err := exec.Command("/usr/bin/defaults", "read", "com.celeste-lingshi.apidog", "theme").Output()
	if err == nil {
		if theme := strings.TrimSpace(string(out)); theme == "light" || theme == "system" || theme == "dark" {
			return theme
		}
	}
	return "dark"
}

func (a *App) SetTheme(theme string) error {
	if theme != "light" && theme != "dark" && theme != "system" {
		return errors.New("未知的主题。")
	}
	return exec.Command("/usr/bin/defaults", "write", "com.celeste-lingshi.apidog", "theme", "-string", theme).Run()
}

func (a *App) ToggleFullscreen() {
	if runtime.WindowIsFullscreen(a.ctx) {
		runtime.WindowUnfullscreen(a.ctx)
	} else {
		runtime.WindowFullscreen(a.ctx)
	}
}

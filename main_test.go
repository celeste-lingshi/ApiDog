package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/celeste-lingshi/ApiDog/internal/apidog"
)

func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == apidog.AuthWorkerArgument {
		apidog.RunAuthWorker(os.Stdin, os.Stdout)
		return
	}
	os.Exit(m.Run())
}

func TestSaveFailure(t *testing.T) {
	storage := apidog.Storage{Folder: t.TempDir()}
	a := &App{ctx: t.Context(), storage: storage}
	draft := apidog.NewDraft()
	request := apidog.SavedRequest{ID: apidog.NewID(), Name: "原请求", Draft: draft}
	initial, err := a.SaveRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	unwritable := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(unwritable, nil, 0600); err != nil {
		t.Fatal(err)
	}
	a.storage = apidog.Storage{Folder: unwritable}

	request.Name = "改过的请求"
	if _, err := a.SaveRequest(request); err == nil {
		t.Fatal("保存失败却没有返回错误")
	}
	if _, err := a.DeleteRequest(request.ID); err == nil {
		t.Fatal("删除失败却没有返回错误")
	}
	after := a.State()
	if !reflect.DeepEqual(after.Directory, initial.Directory) || after.Issue == "" {
		t.Fatal("保存失败后目录被改动，或者错误提示消失")
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, "本机响应")
	}))
	defer server.Close()
	draft.URL = server.URL
	reply, err := a.Send(draft)
	if err != nil || reply.Response == nil || reply.Response.Status != http.StatusOK || reply.Response.Body != "本机响应" ||
		len(reply.State.History) != 0 || reply.HistoryID != "" || reply.State.Issue == "" {
		t.Fatalf("发送结果和历史写入错误没有分开呈现：%+v，%v", reply, err)
	}

	a.storage = storage
	saved, err := a.SaveRequest(request)
	if err != nil || saved.Issue != "" || saved.Directory.Requests[0].Name != request.Name {
		t.Fatalf("重新保存时没有落盘：%+v，%v", saved, err)
	}
}

func TestSaveDraft(t *testing.T) {
	storage := apidog.Storage{Folder: t.TempDir()}
	a := &App{ctx: t.Context(), storage: storage}
	initial, err := a.NewCategory("已移动的分类")
	if err != nil {
		t.Fatal(err)
	}
	id := apidog.NewID()
	request := apidog.SavedRequest{ID: id, Name: "原名称", Draft: apidog.NewDraft()}
	if _, err := a.SaveRequest(request); err != nil {
		t.Fatal(err)
	}
	request.Name = "改过的名称"
	request.CategoryID = &initial.Directory.Categories[0].ID
	moved, err := a.SaveRequest(request)
	if err != nil {
		t.Fatal(err)
	}

	draft := apidog.NewDraft()
	draft.URL = "https://example.test/updated"
	saved, err := a.SaveDraft(id, draft)
	if err != nil || saved.Revision <= moved.Revision {
		t.Fatal("自动保存没有更新工作区", err)
	}
	persisted, err := storage.Load()
	if err != nil || !reflect.DeepEqual(persisted.Directory.Requests[0],
		apidog.SavedRequest{ID: id, Name: request.Name, CategoryID: request.CategoryID, Draft: draft}) {
		t.Fatal("自动保存没有写入草稿，或改动了名称和目录", err)
	}

	if _, err := a.DeleteRequest(id); err != nil {
		t.Fatal(err)
	}
	if _, err := a.SaveDraft(id, draft); err == nil || len(a.State().Directory.Requests) != 0 {
		t.Fatal("待保存的草稿重新创建了已删除的请求")
	}
}

func TestHistoryResponses(t *testing.T) {
	storage := apidog.Storage{Folder: t.TempDir()}
	var old apidog.Workspace
	for i := 54; i >= 0; i-- {
		draft := apidog.NewDraft()
		draft.URL = fmt.Sprintf("https://example.test/%d", i)
		old.History = append(old.History, apidog.NewHistory(draft, nil, time.Now()))
	}
	file := filepath.Join(storage.Folder, "workspace.json")
	data, err := json.Marshal(old)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	workspace, err := storage.Load()
	if err != nil || len(workspace.History) != 50 || workspace.History[49].ID != old.History[49].ID {
		t.Fatal("旧工作区没有按最近 50 条加载", err)
	}
	a := &App{ctx: t.Context(), storage: storage, workspace: workspace}
	legacy, err := a.OpenHistory(old.History[0].ID)
	if err != nil || legacy.Response != nil || legacy.Request.URL != old.History[0].Request.URL {
		t.Fatal("旧记录应该仍可打开", err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-History-Example", "saved")
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, `{"reason":[{"port":80}]}`)
	}))
	defer server.Close()
	draft := apidog.NewDraft()
	draft.URL = server.URL
	draft.Projection = ".reason[]?.port"
	reply, err := a.Send(draft)
	if err != nil || reply.Response == nil || reply.HistoryID == "" || len(reply.State.History) != 50 ||
		reply.State.History[0].Response != nil || reply.State.History[49].ID != old.History[48].ID {
		t.Fatal("发送后历史列表的数据不正确", err)
	}
	data, err = os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	var disk apidog.Workspace
	if err := json.Unmarshal(data, &disk); err != nil || len(disk.History) != 50 {
		t.Fatal("工作区文件没有只保留 50 条历史", err)
	}
	reloaded, err := storage.Load()
	if err != nil {
		t.Fatal(err)
	}
	reopened := &App{ctx: t.Context(), storage: storage, workspace: reloaded}
	record, err := reopened.OpenHistory(reply.HistoryID)
	if err != nil || !reflect.DeepEqual(reply.Response, record.Response) ||
		record.Response.Status != http.StatusBadRequest || !strings.Contains(record.Response.Headers, "X-History-Example: saved") ||
		record.Response.Extracted == nil || *record.Response.Extracted != "80" {
		t.Fatalf("重开后响应结果没有读回：%+v，%v", record.Response, err)
	}
}

func TestPreviewCancellation(t *testing.T) {
	a := &App{ctx: t.Context()}
	draft := apidog.NewDraft()
	draft.URL = "https://example.test/"
	draft.Auth = apidog.Auth{Mode: "script", Script: apidog.Text("while (true) {}")}
	done := make(chan error, 1)
	go func() {
		_, err := a.Preview(draft)
		done <- err
	}()
	for deadline := time.Now().Add(time.Second); ; time.Sleep(time.Millisecond) {
		a.mu.Lock()
		registered := a.preview != nil
		a.mu.Unlock()
		if registered {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("预览任务未注册")
		}
	}
	a.CancelPreview()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("旧预览未及时取消")
	}
	draft.Auth = apidog.Auth{Mode: "none"}
	if p, err := a.Preview(draft); err != nil || p.Command == "" {
		t.Fatalf("新预览未正常生成：%+v，%v", p, err)
	}
}

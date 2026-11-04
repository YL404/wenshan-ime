package mobile

import (
	"os"
	"path/filepath"
	"testing"

	"wenshan/engine"
)

func openTestDict(t *testing.T) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "dict.bin")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := engine.WriteDict(f, []engine.Entry{
		{Code: "ni", Text: "你", Weight: 2500},
		{Code: "nihk", Text: "你好", Weight: 2400},
	}); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if !Open(path, "") {
		t.Fatalf("Open 失败: %s", LastError())
	}
	t.Cleanup(func() {
		mu.Lock()
		closeLocked()
		mu.Unlock()
	})
}

// 宿主正文末尾挂着预编辑串：补空格要看预编辑之前的字符，不能因为选词
// 消耗了缓冲就把预编辑里的字母当成正文。
func TestContextStripsPreedit(t *testing.T) {
	openTestDict(t)
	doc := "中文"
	for _, k := range "nihk" {
		SetContextBefore(doc + sess.Preedit())
		Type(string(k))
	}
	SetContextBefore(doc + sess.Preedit())
	if got := Space().Text; got != "你好" {
		t.Fatalf("中文后空格上屏 = %q, 期望不补空格", got)
	}
}

// Flush 要把不足攒够次数的词频也写盘，扩展被回收前不丢学习记录。
func TestFlushWritesPendingFreq(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dict.bin")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := engine.WriteDict(f, []engine.Entry{{Code: "ni", Text: "你", Weight: 2500}}); err != nil {
		t.Fatal(err)
	}
	f.Close()
	data := t.TempDir()
	if !Open(path, data) {
		t.Fatalf("Open 失败: %s", LastError())
	}
	t.Cleanup(func() {
		mu.Lock()
		closeLocked()
		mu.Unlock()
	})
	Type("n")
	Type("i")
	if got := Space().Text; got != "你" {
		t.Fatalf("空格上屏 = %q", got)
	}
	if msg := Flush(); msg != "" {
		t.Fatalf("Flush 失败: %s", msg)
	}
	if got := engine.LoadFreq(filepath.Join(data, "freq.tsv")).Count("你"); got != 1 {
		t.Fatalf("Flush 后词频 = %d, 期望 1", got)
	}
}

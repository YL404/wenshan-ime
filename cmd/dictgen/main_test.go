package main

import (
	"os"
	"path/filepath"
	"testing"

	"wenshan/engine"
)

// 辅码表给单字补 2+1 和 2+2 两档，多音字每个读音都补。
func TestAddAux(t *testing.T) {
	best := map[string]engine.Entry{
		"ni\x00你": {Code: "ni", Text: "你", Weight: 500},
		"hk\x00好": {Code: "hk", Text: "好", Weight: 400},
		"de\x00的": {Code: "de", Text: "的", Weight: 300},
		"di\x00的": {Code: "di", Text: "的", Weight: 200},
	}
	path := filepath.Join(t.TempDir(), "aux.txt")
	if err := os.WriteFile(path, []byte("# 注释\r\n\r\n你=rx\r\n好=nz\r\n的=bu\r\n缺=zz\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	n, err := addAux(path, best)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]engine.Entry{
		"nir\x00你":  {Code: "nir", Text: "你", Weight: 500},
		"nirx\x00你": {Code: "nirx", Text: "你", Weight: 500},
		"hkn\x00好":  {Code: "hkn", Text: "好", Weight: 400},
		"hknz\x00好": {Code: "hknz", Text: "好", Weight: 400},
		"deb\x00的":  {Code: "deb", Text: "的", Weight: 300},
		"debu\x00的": {Code: "debu", Text: "的", Weight: 300},
		"dib\x00的":  {Code: "dib", Text: "的", Weight: 300},
		"dibu\x00的": {Code: "dibu", Text: "的", Weight: 300},
	}
	if n != len(want) {
		t.Fatalf("辅码条数 = %d, 期望 %d", n, len(want))
	}
	for key, w := range want {
		if got, ok := best[key]; !ok || got != w {
			t.Errorf("%q = %+v, %v; 期望 %+v", key, got, ok, w)
		}
	}
	if _, ok := best["zz\x00缺"]; ok {
		t.Error("词库里没有「缺」，不该加辅码")
	}
}

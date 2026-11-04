package engine

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// userWeight 是自造词的排序权重。用户明确教过的词，层内直接排最前，
// 但要低于「整段匹配」那一层，所以只放在权重区。
const userWeight = 1_000_000_000

// UserDict 是用户自造词表：编码 + 词。数量少，线性查就够。
type UserDict struct {
	entries []userEntry
	dirty   int
	path    string
}

type userEntry struct {
	code string
	text string
}

// LoadUserDict 读取自造词或短语文件。文件不存在时返回空表。
// 每行是「编码<TAB>文本」，空行和 # 开头的行忽略。
func LoadUserDict(path string) *UserDict {
	u := &UserDict{path: path}
	file, err := os.Open(path)
	if err != nil {
		return u
	}
	defer file.Close()

	sc := bufio.NewScanner(file)
	for sc.Scan() {
		line := strings.TrimSuffix(sc.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		code, text, ok := strings.Cut(line, "\t")
		if !ok || code == "" || text == "" {
			continue
		}
		u.entries = append(u.entries, userEntry{code: code, text: text})
	}
	return u
}

// Add 记一个自造词。同一编码同一词条只留一份。
func (u *UserDict) Add(code, text string) bool {
	if u == nil || len(code) < 4 || text == "" {
		return false
	}
	for _, e := range u.entries {
		if e.code == code && e.text == text {
			return false
		}
	}
	u.entries = append(u.entries, userEntry{code: code, text: text})
	u.dirty++
	return true
}

// Len 返回自造词条数。
func (u *UserDict) Len() int { return len(u.entries) }

// Lookup 返回编码以 prefix 开头的自造词，用户词频 f 计入分数，可以为 nil。
func (u *UserDict) Lookup(prefix []byte, limit int, f *Freq) []Candidate {
	if u == nil || len(prefix) == 0 || limit <= 0 {
		return nil
	}
	p := string(prefix)
	var out []Candidate
	for _, e := range u.entries {
		if !strings.HasPrefix(e.code, p) {
			continue
		}
		out = insertCandidate(out, Candidate{
			Text:    e.text,
			CodeLen: len(e.code),
			score:   candidateScore(userWeight, len(e.code), len(prefix)) + f.boost(e.text),
		}, limit)
	}
	return out
}

// Save 把自造词写回磁盘。先写临时文件再改名。
func (u *UserDict) Save() error {
	if u == nil || u.dirty == 0 {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(u.path), 0o755); err != nil {
		return err
	}
	tmp := u.path + ".tmp"
	w, err := os.Create(tmp)
	if err != nil {
		return err
	}
	bw := bufio.NewWriter(w)
	for _, e := range u.entries {
		if _, err := bw.WriteString(e.code + "\t" + e.text + "\n"); err != nil {
			w.Close()
			return err
		}
	}
	if err := bw.Flush(); err != nil {
		w.Close()
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, u.path); err != nil {
		return err
	}
	u.dirty = 0
	return nil
}

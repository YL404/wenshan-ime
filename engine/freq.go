package engine

import (
	"bufio"
	"cmp"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// saveEvery 是攒够多少次选词才落盘。写在按键路径上，所以频率要低。
const saveEvery = 50

// maxFreqEntries 是词频表最多保留的词数。超出时写盘前淘汰选得最少的词，
// 文件和内存不会随使用时间无限增长。
const maxFreqEntries = 20000

// Freq 记录用户实际选过的词，用来把常用的词往前排。
// 只在主线程访问，不加锁。
type Freq struct {
	counts map[string]uint32
	dirty  int
	path   string
}

// LoadFreq 读取词频文件。文件不存在或读不动时返回空表，不影响输入。
func LoadFreq(path string) *Freq {
	f := &Freq{counts: make(map[string]uint32), path: path}
	file, err := os.Open(path)
	if err != nil {
		return f
	}
	defer file.Close()

	sc := bufio.NewScanner(file)
	for sc.Scan() {
		text, num, ok := strings.Cut(sc.Text(), "\t")
		if !ok || text == "" {
			continue
		}
		n, err := strconv.ParseUint(num, 10, 32)
		if err != nil {
			continue
		}
		f.counts[text] = uint32(n)
	}
	return f
}

// Count 返回某个词被选过多少次。
func (f *Freq) Count(text string) uint32 { return f.counts[text] }

// Bump 记一次选词。
func (f *Freq) Bump(text string) {
	if f == nil || text == "" {
		return
	}
	f.counts[text]++
	f.dirty++
}

// due 报告未落盘的选词是否攒够了 saveEvery 次。
func (f *Freq) due() bool { return f != nil && f.dirty >= saveEvery }

// Save 把词频写回磁盘，按次数从多到少排列，超过 maxFreqEntries 的部分
// 淘汰掉。先写临时文件再改名，避免写一半留下坏文件。
func (f *Freq) Save() error {
	if f == nil || f.dirty == 0 {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return err
	}
	texts := make([]string, 0, len(f.counts))
	for text := range f.counts {
		texts = append(texts, text)
	}
	slices.SortFunc(texts, func(a, b string) int {
		if c := cmp.Compare(f.counts[b], f.counts[a]); c != 0 {
			return c
		}
		return strings.Compare(a, b)
	})
	if len(texts) > maxFreqEntries {
		for _, text := range texts[maxFreqEntries:] {
			delete(f.counts, text)
		}
		texts = texts[:maxFreqEntries]
	}
	tmp := f.path + ".tmp"
	w, err := os.Create(tmp)
	if err != nil {
		return err
	}
	bw := bufio.NewWriter(w)
	for _, text := range texts {
		if _, err := fmt.Fprintf(bw, "%s\t%d\n", text, f.counts[text]); err != nil {
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
	if err := os.Rename(tmp, f.path); err != nil {
		return err
	}
	f.dirty = 0
	return nil
}

// freqBoost 把「选过 n 次」折算成排序加权。封顶是为了不让个别词永远霸榜，
// 同时也保证它只影响层内的顺序，翻不过「整段匹配」那一层。
func freqBoost(n uint32) int64 {
	return int64(min(n, maxBoostCount)) * boostPerPick
}

const (
	maxBoostCount = 50
	boostPerPick  = 1_000_000
)

// boost 返回 text 的词频加权。f 为 nil 时不加权。
func (f *Freq) boost(text string) int64 {
	if f == nil {
		return 0
	}
	return freqBoost(f.counts[text])
}

// boostBytes 同 boost，直接用字节切片查表，不分配字符串。
func (f *Freq) boostBytes(text []byte) int64 {
	if f == nil {
		return 0
	}
	return freqBoost(f.counts[string(text)])
}

// maxBoost 是任何词能拿到的最大加权，用来在查表前先排除进不了候选的词。
func (f *Freq) maxBoost() int64 {
	if f == nil {
		return 0
	}
	return maxBoostCount * boostPerPick
}

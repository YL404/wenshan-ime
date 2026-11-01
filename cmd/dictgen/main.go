// Command dictgen 把 Rime 的 dict.yaml 编译成运行时的紧凑词表。
//
//	go run ./cmd/dictgen -o dict.bin build/rime-ice/8105.dict.yaml ...
//
// 输入是 Rime 词库格式：表头以 ... 结束，之后每行「词条<TAB>拼音<TAB>权重」。
// 拼音按空格分成音节，用 engine 的自然码规则转成两键编码。
package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"wenshan/engine"
)

func main() {
	out := flag.String("o", "dict.bin", "输出的词表文件")
	flag.Parse()
	if flag.NArg() == 0 {
		log.Fatal("用法: dictgen -o dict.bin <dict.yaml>...")
	}

	best := make(map[string]engine.Entry)
	for _, path := range flag.Args() {
		n, err := load(path, best)
		if err != nil {
			log.Fatalf("%s: %v", path, err)
		}
		fmt.Printf("%s: %d 条\n", path, n)
	}

	entries := make([]engine.Entry, 0, len(best))
	for _, e := range best {
		entries = append(entries, e)
	}
	f, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	if err := engine.WriteDict(f, entries); err != nil {
		log.Fatal(err)
	}
	if err := f.Close(); err != nil {
		log.Fatal(err)
	}
	st, err := os.Stat(*out)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: %d 条, %.1f MB\n", *out, len(entries), float64(st.Size())/(1<<20))
}

// load 读一个词库文件，把条目合进 best（同一编码同一词条取较版权重）。
func load(path string, best map[string]engine.Entry) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	inBody, seenHeader, n := false, false, 0
	for sc.Scan() {
		line := sc.Text()
		if !inBody {
			switch {
			case line == "---":
				seenHeader = true
			case line == "...":
				inBody = true
			case !seenHeader && line != "" && !strings.HasPrefix(line, "#"):
				inBody = true // 没有表头的词库
				n += parseLine(line, best)
			}
			continue
		}
		n += parseLine(line, best)
	}
	return n, sc.Err()
}

func parseLine(line string, best map[string]engine.Entry) int {
	if line == "" || strings.HasPrefix(line, "#") {
		return 0
	}
	fields := strings.Split(line, "\t")
	if len(fields) < 2 {
		return 0
	}
	text, pinyin := fields[0], strings.Fields(fields[1])
	if text == "" || len(pinyin) == 0 {
		return 0
	}
	var weight uint32
	if len(fields) > 2 {
		if w, err := strconv.ParseUint(strings.TrimSpace(fields[2]), 10, 32); err == nil {
			weight = uint32(w)
		}
	}
	n := 0
	for _, code := range engine.Codes(pinyin) {
		key := code + "\x00" + text
		if old, ok := best[key]; ok {
			if weight > old.Weight {
				best[key] = engine.Entry{Code: code, Text: text, Weight: weight}
			}
			continue
		}
		best[key] = engine.Entry{Code: code, Text: text, Weight: weight}
		n++
	}
	return n
}

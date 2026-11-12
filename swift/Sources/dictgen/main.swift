// dictgen 把 Rime 的 dict.yaml 编译成运行时的紧凑词表。
//
//     swift run -c release --package-path swift dictgen -o dict.bin \
//         -aux build/aux/moqi_aux_code.txt build/rime-ice/8105.dict.yaml ...
//     swift run -c release --package-path swift dictgen -english -o english.bin \
//         build/rime-ice/en.dict.yaml build/rime-ice/en_ext.dict.yaml
import Foundation
import WenshanCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var output = "dict.bin"
var auxPath = ""
var englishOnly = false
var inputs: [String] = []
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "-o", "-aux":
        guard let value = args.popFirst() else { fail("\(arg) 后面缺参数") }
        if arg == "-o" { output = value } else { auxPath = value }
    case "-english":
        englishOnly = true
    default:
        if arg.hasPrefix("-") { fail("不认识的参数 \(arg)") }
        inputs.append(arg)
    }
}
if inputs.isEmpty {
    fail("用法: dictgen -o dict.bin [-aux 辅码表] <dict.yaml>... 或 -english -o english.bin <en.dict.yaml>...")
}

if englishOnly {
    var best: [String: EnglishEntry] = [:]
    for path in inputs {
        do {
            print("\(path): \(try loadEnglishRime(path, into: &best)) 条")
        } catch {
            fail("\(path): \(error)")
        }
    }
    let data = writeEnglishDict(Array(best.values))
    do {
        try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } catch {
        fail("\(output): \(error)")
    }
    print(String(format: "%@: %d 条, %.1f MB", output, best.count, Double(data.count) / 1_048_576))
    exit(0)
}

var best: EntryMap = [:]
for path in inputs {
    do {
        print("\(path): \(try loadRime(path, into: &best)) 条")
    } catch {
        fail("\(path): \(error)")
    }
}
if !auxPath.isEmpty {
    do {
        print("\(auxPath): \(try addAux(auxPath, into: &best)) 条辅码")
    } catch {
        fail("\(auxPath): \(error)")
    }
}

let data = writeDict(Array(best.values))
do {
    try data.write(to: URL(fileURLWithPath: output), options: .atomic)
} catch {
    fail("\(output): \(error)")
}
print(String(format: "%@: %d 条, %.1f MB", output, best.count, Double(data.count) / 1_048_576))

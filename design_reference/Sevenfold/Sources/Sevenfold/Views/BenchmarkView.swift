import SwiftUI

/// Tools ▸ Benchmark. Real hardware details; the figures are simulated in the design build.
struct BenchmarkView: View {
    @State private var dictionaryMB = 32
    @State private var threads = Hardware.cores
    @State private var run = 0
    @State private var elapsed = 0.0
    @State private var stopped = false
    @State private var jitter = 1.0

    private let passes = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: Command.benchmark.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Hardware.chip).font(.title3.weight(.semibold))
                    Text("\(Hardware.cores) cores · \(Fmt.human(Hardware.memory)) memory · arm64")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Picker("Dictionary size", selection: $dictionaryMB) {
                    ForEach([16, 32, 64, 128], id: \.self) { Text("\($0) MB").tag($0) }
                }
                .fixedSize()
                Picker("CPU threads", selection: $threads) {
                    ForEach(1...Hardware.cores, id: \.self) { Text("\($0) of \(Hardware.cores)").tag($0) }
                }
                .fixedSize()
            }

            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    header("Speed"); header("CPU usage"); header("Rating / usage"); header("Rating")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                row("Compressing", speed: compressSpeed, usage: compressUsage, rating: compressRating)
                row("Decompressing", speed: elapsed > 1.2 ? decompressSpeed : nil, usage: decompressUsage, rating: decompressRating)
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total rating").fontWeight(.semibold).gridColumnAlignment(.leading)
                    Text("")
                    Text(elapsed > 1.2 ? "\(Int((compressUsage + decompressUsage) / 2))%" : "—")
                    Text(elapsed > 1.2 ? "\(mips((compressRating / compressUsage + decompressRating / decompressUsage) * 50))" : "—")
                    Text(elapsed > 1.2 ? mips((compressRating + decompressRating) / 2) : "—").fontWeight(.semibold)
                }
            }
            .monospacedDigit()
            .padding(14)
            .background(.fill.quaternary, in: .rect(cornerRadius: 12))

            HStack {
                Label(Fmt.duration(elapsed), systemImage: "clock")
                Label("Pass \(min(passes, Int(elapsed / 1.6))) of \(passes)", systemImage: "repeat")
                Spacer()
                Button("Restart") { restart() }
                Button(stopped ? "Stopped" : "Stop") { stopped = true }
                    .disabled(stopped)
            }
            .foregroundStyle(.secondary)

            Text("Design build: figures are simulated. The shipping app runs 7-Zip’s own benchmark (7zz b).")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 640)
        .task(id: "\(run)-\(dictionaryMB)-\(threads)") { await tick() }
    }

    // Per-core figures in the range 7-Zip reports for recent Apple silicon.
    private var scale: Double { Double(threads) * pow(32.0 / Double(dictionaryMB), 0.07) * jitter * min(1, 0.55 + elapsed / 4) }
    private var compressSpeed: Double { 11_800 * scale }
    private var compressUsage: Double { min(Double(threads) * 100, Double(threads) * 87) }
    private var compressRating: Double { 9_950 * scale }
    private var decompressSpeed: Double { 150_000 * scale }
    private var decompressUsage: Double { min(Double(threads) * 100, Double(threads) * 96) }
    private var decompressRating: Double { 12_700 * scale }

    private func tick() async {
        elapsed = 0
        stopped = false
        while !Task.isCancelled && !stopped && elapsed < Double(passes) * 1.6 {
            try? await Task.sleep(for: .milliseconds(400))
            elapsed += 0.4
            jitter = Double.random(in: 0.985...1.015)
        }
    }

    private func restart() { run += 1 }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func row(_ title: String, speed: Double?, usage: Double, rating: Double) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.leading)
            Text(speed.map { "\(Fmt.bytes(Int64($0))) KB/s" } ?? "—")
            Text(speed == nil ? "—" : "\(Int(usage))%")
            Text(speed == nil ? "—" : mips(rating / usage * 100))
            Text(speed == nil ? "—" : mips(rating))
        }
    }

    private func mips(_ value: Double) -> String { "\(Fmt.bytes(Int64(value))) MIPS" }
}
